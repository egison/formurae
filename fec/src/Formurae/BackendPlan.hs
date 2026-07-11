{-# LANGUAGE PatternSynonyms #-}

module Formurae.BackendPlan
  ( BackendRequest(..)
  , AuxLifetime(..)
  , AuxRole(..)
  , AuxFieldPlan(..)
  , LbPlan(..)
  , BackendPlan(..)
  , collectBackendRequests
  , planBackend
  , lowerBackendRequests
  , hasLbRequest
  ) where

import Data.Char (isAlpha, isAlphaNum, isDigit, isSpace)
import Data.List (nubBy)

import Formurae.Common (reservedInternalPrefix)
import Formurae.Index (Placement, axisRange, componentPlacement, fieldBaseOf)
import Formurae.Syntax
import Formurae.TensorExpr

data BackendRequest = LbRequest
  { brSource :: String
  , brOrigin :: Maybe SourceOrigin
  } deriving (Eq, Show)

data AuxLifetime = PersistentState | StepLocal
  deriving (Eq, Show)

data AuxRole
  = LbCoefficient Int
  | LbVolume
  | LbFlux Int Int
  deriving (Eq, Show)

data AuxFieldPlan = AuxFieldPlan
  { afName      :: String
  , afLifetime  :: AuxLifetime
  , afRole      :: AuxRole
  , afPlacement :: Placement
  }

data LbPlan = LbPlan
  { lpRequestId  :: Int
  , lpSource     :: String
  , lpResultName :: String
  , lpAuxFields  :: [AuxFieldPlan]
  }

data BackendPlan = BackendPlan
  { bpMetricAuxFields :: [AuxFieldPlan]
  , bpLbPlans         :: [LbPlan]
  }

collectBackendRequests :: Model -> IO (Either String [BackendRequest])
collectBackendRequests model = do
  initializerError <- rejectInitializerRequests model
  case initializerError of
    Just message -> return (Left message)
    Nothing -> do
      expanded <- mapM (expandDefsWithSource (mDefs model) . sSourceText)
                       (mSteps model)
      let requestResults = map (requestsInExpr model) expanded
      return (nubBy sameSource . concat <$> sequence requestResults)
  where
    sameSource lhs rhs = brSource lhs == brSource rhs

planBackend :: Model -> [BackendRequest] -> Either String BackendPlan
planBackend model requests =
  case requests of
    [] -> Right (BackendPlan [] [])
    request:_
      | mMetric model == Nothing && mEmbed model == Nothing ->
          Left ("lb needs a 'metric scale [...]' or 'embedding [...]' declaration"
                ++ requestOriginText request)
      | otherwise ->
          Right (BackendPlan (makeMetricAuxFields model)
                  (zipWith (makeLbPlan model) [1 ..] requests))

lowerBackendRequests :: BackendPlan -> TensorExpr -> Either String TensorExpr
lowerBackendRequests plan = transformTensorExprM lower
  where
    lower expr =
      case lbApplication expr of
        Just operand ->
          do source <- simpleLbSource operand
             case [lbPlan | lbPlan <- bpLbPlans plan,
                            lpSource lbPlan == source] of
               lbPlan:_ -> Right (Just (TEIdent (lpResultName lbPlan) []))
               [] -> Left ("internal error: lb request for " ++ source
                           ++ " has no backend plan")
        Nothing
          | invalidLbHead expr ->
              Left "lb expects exactly one unindexed collocated scalar field"
          | otherwise -> Right Nothing

hasLbRequest :: TensorExpr -> Bool
hasLbRequest expr =
  case expr of
    TEApply (TEIdent "lb" []) _ -> True
    TECall (TEIdent "lb" []) _ -> True
    _ -> any hasLbRequest (children expr)

makeMetricAuxFields :: Model -> [AuxFieldPlan]
makeMetricAuxFields model =
  let axes = axisRange model
      coefficientNames = take (length axes) ["ca", "cb", "cc"]
      coefficient axis name =
        AuxFieldPlan name PersistentState (LbCoefficient axis)
          (componentPlacement model Primal [axis])
      volume = AuxFieldPlan "sg" PersistentState LbVolume
                 (componentPlacement model Collocated [])
  in [coefficient axis name | (axis, name) <- zip axes coefficientNames]
     ++ [volume]

makeLbPlan :: Model -> Int -> BackendRequest -> LbPlan
makeLbPlan model requestId request =
  let axes = axisRange model
      fluxName axis
        | requestId == 1 = "f" ++ show axis
        | otherwise = reservedInternalPrefix ++ "Lb" ++ show requestId
                      ++ "Flux" ++ show axis
      flux axis =
        AuxFieldPlan (fluxName axis) StepLocal (LbFlux requestId axis)
          (componentPlacement model Primal [axis])
      resultName
        | requestId == 1 = lbResultBindingName
        | otherwise = lbResultBindingName ++ show requestId
  in LbPlan
       { lpRequestId = requestId
       , lpSource = brSource request
       , lpResultName = resultName
       , lpAuxFields = map flux axes
       }

rejectInitializerRequests :: Model -> IO (Maybe String)
rejectInitializerRequests model = do
  errors <- mapM inspect (zip (mInits model) (mInitSourceTexts model))
  return $ case [message | Just message <- errors] of
    message : _ -> Just message
    [] -> Nothing
  where
    inspect (initValue, source)
      | isCasInitializer initValue = do
          expression <- expandDefsWithSource (mDefs model) source
          return (initializerError expression)
      | containsLbApplication (sourceTranslated source) =
          return (Just (initializerMessage (directInitializerOrigin source)))
      | otherwise = return Nothing

    initializerError expression =
      case firstLbApplication expression of
        Just request -> Just (initializerMessage (tensorExprOrigin request))
        Nothing -> Nothing

    initializerMessage origin =
      "lb is not supported in an initializer because its auxiliary "
      ++ "flux fields are materialized during the step"
      ++ maybe "" sourceOriginText origin

    isCasInitializer (ICas _ _) = True
    isCasInitializer (ICasIndex _ _ _) = True
    isCasInitializer _ = False

firstLbApplication :: TensorExpr -> Maybe TensorExpr
firstLbApplication expression
  | lbApplication expression /= Nothing = Just expression
  | invalidLbHead expression = Just expression
  | otherwise = firstJust (map firstLbApplication (children expression))
  where
    firstJust [] = Nothing
    firstJust (Just value : _) = Just value
    firstJust (Nothing : rest) = firstJust rest

directInitializerOrigin :: SourceText -> Maybe SourceOrigin
directInitializerOrigin source =
  case parseSourceTensorExpr source of
    Right expression -> tensorExprOrigin =<< firstLbApplication expression
    Left _ -> do
      spanValue <- rawLbApplicationSpan (sourceTranslated source)
      let location = sourceLocationForSpan source spanValue
      return (SourceOrigin location [])

-- Raw Formura initializer syntax can contain constructs outside TensorExpr.
-- Locate only a standalone `lb` token that is actually applied; a substring
-- such as the `lb` in `blb[i]` must never steal the diagnostic location from
-- a later `lb(v[i])` request.
rawLbApplicationSpan :: String -> Maybe SourceSpan
rawLbApplicationSpan = go 1 Nothing
  where
    go _ _ [] = Nothing
    go offset previous source@('l':'b':rest)
      | boundaryBefore previous
      , boundaryAfter rest
      , applicationFollows rest = Just (SourceSpan offset (offset + 1))
      | otherwise = advance offset previous source
    go offset previous source = advance offset previous source

    advance offset _ (char : rest) = go (offset + 1) (Just char) rest
    advance _ _ [] = Nothing

    boundaryBefore Nothing = True
    boundaryBefore (Just char) = not (wordChar char)
    boundaryAfter [] = True
    boundaryAfter (char : _) = not (wordChar char)
    wordChar char = isAlphaNum char || char == '_'

    applicationFollows rest =
      let (spaces, following) = span isSpace rest
          separated = not (null spaces)
      in case following of
           '(' : _ -> True
           char : _ | isAlpha char -> True
           char : _ | isDigit char -> True
           '[' : _ | separated -> True
           '.' : char : _ | separated && isDigit char -> True
           char : _ | char `elem` "\"`{" -> True
           _ -> False

requestsInExpr :: Model -> TensorExpr -> Either String [BackendRequest]
requestsInExpr model expr =
  case lbApplication expr of
    Just operand -> do
      source <- withExpressionOrigin expr (simpleLbSource operand)
      case kindOf model source of
        Just Scalar
          | fieldPolicyOf model source == Collocated ->
              Right [LbRequest source (tensorExprOrigin expr)]
          | otherwise ->
              Left ("lb currently requires a collocated scalar source: " ++ source
                    ++ expressionOriginText expr)
        _ -> Left ("lb expects a scalar field argument: " ++ source
                   ++ expressionOriginText expr)
    Nothing
      | invalidLbHead expr ->
          Left ("lb expects exactly one unindexed collocated scalar field"
                ++ expressionOriginText expr)
      | otherwise -> concat <$> mapM (requestsInExpr model) (children expr)

withExpressionOrigin :: TensorExpr -> Either String a -> Either String a
withExpressionOrigin expr result =
  case result of
    Left message -> Left (message ++ expressionOriginText expr)
    Right value -> Right value

lbApplication :: TensorExpr -> Maybe TensorExpr
lbApplication expr =
  case expr of
    TEApply (TEIdent "lb" []) [operand] -> Just operand
    TECall (TEIdent "lb" []) [operand] -> Just operand
    _ -> Nothing

invalidLbHead :: TensorExpr -> Bool
invalidLbHead expr =
  case expr of
    TEApply (TEIdent "lb" []) _ -> True
    TECall (TEIdent "lb" []) _ -> True
    _ -> False

simpleLbSource :: TensorExpr -> Either String String
simpleLbSource expr =
  case stripGroups expr of
    TEIdent source0 [] ->
      let (source, primes) = fieldBaseOf source0
      in if primes == 0
           then Right source
           else Left "lb does not accept a primed source field"
    _ -> Left ("lb expects an unindexed scalar field argument, not: "
               ++ renderTensorExpr expr)

stripGroups :: TensorExpr -> TensorExpr
stripGroups (TEGroup expr) = stripGroups expr
stripGroups expr = expr

children :: TensorExpr -> [TensorExpr]
children expr =
  case expr of
    TENumber _ -> []
    TEIdent _ _ -> []
    TEUnary _ body -> [body]
    TECall fn args -> fn : args
    TEApply fn args -> fn : args
    TEIf cond yes no -> [cond, yes, no]
    TEAppendIndexed body _ -> [body]
    TEWithSymbols _ body -> [body]
    TEContractWith _ body -> [body]
    TETensorMap fn body -> [fn, body]
    TESubrefs body _ -> [body]
    TETranspose _ body -> [body]
    TEDisjoint parts -> parts
    TEDerivative _ body -> [body]
    TEDot parts -> parts
    TEBinary _ lhs rhs -> [lhs, rhs]
    TEGroup body -> [body]

containsLbApplication :: String -> Bool
containsLbApplication source =
  case parseTensorExprEither source of
    Right expr -> hasLbRequest expr
    Left _ -> rawApplication (tokenize source)
  where
    rawApplication [] = False
    rawApplication (TId "lb" False : rest) =
      let (spaces, following) = span isSpTok rest
          separated = not (null spaces)
      in case following of
        TC '(' : _ -> True
        TId _ _ : _ -> True
        TC '[' : _ | separated -> True
        TC c : _ | c >= '0' && c <= '9' -> True
        TC '.' : TC c : _ | separated && c >= '0' && c <= '9' -> True
        TC c : _ | c `elem` "\"`{" -> True
        _ -> rawApplication rest
    rawApplication (_ : rest) = rawApplication rest

requestOriginText :: BackendRequest -> String
requestOriginText = maybe "" sourceOriginText . brOrigin

expressionOriginText :: TensorExpr -> String
expressionOriginText = maybe "" sourceOriginText . tensorExprOrigin

sourceOriginText :: SourceOrigin -> String
sourceOriginText origin =
  " (" ++ locationText (originLocation origin) ++ ")"
  ++ concatMap expansionText (originTrace origin)
  where
    expansionText frame =
      "\n  in expansion of " ++ expansionName frame
      ++ " (defined at " ++ locationText (expansionDefinition frame)
      ++ ", called at " ++ locationText (expansionCall frame) ++ ")"

locationText :: SourceLocation -> String
locationText location =
  locationPath location ++ ":" ++ show (locationLine location) ++ ":"
  ++ if locationLine location /= locationEndLine location
       then show (locationStartColumn location) ++ "-"
            ++ show (locationEndLine location) ++ ":"
            ++ show (locationEndColumn location)
       else if locationStartColumn location == locationEndColumn location
         then show (locationStartColumn location)
         else show (locationStartColumn location) ++ "-"
              ++ show (locationEndColumn location)
