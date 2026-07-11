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

import Data.List (nubBy)

import Formurae.Common (reservedInternalPrefix)
import Formurae.Index (Placement, axisRange, componentPlacement, fieldBaseOf)
import Formurae.Syntax
import Formurae.TensorExpr

data BackendRequest = LbRequest
  { brSource :: String
  , brSpan   :: SourceSpan
  , brPath   :: FilePath
  , brLine   :: Int
  , brExprColumn :: Int
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

collectBackendRequests :: Model -> Either String [BackendRequest]
collectBackendRequests model = do
  rejectInitializerRequests model
  requests <- concat <$> mapM requestsInStep (mSteps model)
  return (nubBy sameSource requests)
  where
    requestsInStep step =
      if sSourceMapped step
        then requestsInText model (sLine step) (sExprColumn step)
               (sOriginalEx step)
        else requestsInText model 0 0 (sEx step)
    sameSource lhs rhs = brSource lhs == brSource rhs

planBackend :: Model -> [BackendRequest] -> Either String BackendPlan
planBackend model requests =
  case requests of
    [] -> Right (BackendPlan [] [])
    request:_
      | mMetric model == Nothing && mEmbed model == Nothing ->
          Left ("lb needs a 'metric scale [...]' or 'embedding [...]' declaration"
                ++ expandedSpanText request)
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

rejectInitializerRequests :: Model -> Either String ()
rejectInitializerRequests model =
  case [expr | initValue <- mInits model, expr <- initExpressions initValue,
               containsLbApplication expr] of
    [] -> Right ()
    expr:_ ->
      Left ("lb is not supported in an initializer because its auxiliary "
            ++ "flux fields are materialized during the step: " ++ expr)

requestsInText :: Model -> Int -> Int -> String -> Either String [BackendRequest]
requestsInText model line exprColumn source = do
  expr <- case parseTensorExprEither source of
            Right parsed -> Right parsed
            Left msg -> Left ("bad backend request expression: " ++ msg)
  requestsInExpr model line exprColumn expr

requestsInExpr :: Model -> Int -> Int -> TensorExpr -> Either String [BackendRequest]
requestsInExpr model line exprColumn expr =
  case lbApplication expr of
    Just operand -> do
      source <- withExpressionSpan model line exprColumn expr (simpleLbSource operand)
      case kindOf model source of
        Just Scalar
          | fieldPolicyOf model source == Collocated ->
              Right [LbRequest source (tensorExprSpan expr) (mSourcePath model)
                       line exprColumn]
          | otherwise ->
              Left ("lb currently requires a collocated scalar source: " ++ source
                    ++ sourceExprSpanText model line exprColumn expr)
        _ -> Left ("lb expects a scalar field argument: " ++ source
                   ++ sourceExprSpanText model line exprColumn expr)
    Nothing
      | invalidLbHead expr ->
          Left ("lb expects exactly one unindexed collocated scalar field"
                ++ sourceExprSpanText model line exprColumn expr)
      | otherwise -> concat <$> mapM (requestsInExpr model line exprColumn) (children expr)

withExpressionSpan
  :: Model -> Int -> Int -> TensorExpr -> Either String a -> Either String a
withExpressionSpan model line exprColumn expr result =
  case result of
    Left message -> Left (message ++ sourceExprSpanText model line exprColumn expr)
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

initExpressions :: Init -> [String]
initExpressions initValue =
  case initValue of
    IRaw _ rhs -> [rhs]
    IVec _ values -> values
    ISym _ values -> values
    IAnti _ values -> values
    ITensor2 _ values -> values
    ICas _ value -> [value]
    ICasIndex _ _ value -> [value]

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

expandedSpanText :: BackendRequest -> String
expandedSpanText request =
  sourceLocationText (brPath request) (brLine request) (brExprColumn request)
    (brSpan request)

sourceExprSpanText :: Model -> Int -> Int -> TensorExpr -> String
sourceExprSpanText model line exprColumn expr =
  sourceLocationText (mSourcePath model) line exprColumn (tensorExprSpan expr)

sourceLocationText :: FilePath -> Int -> Int -> SourceSpan -> String
sourceLocationText path line exprColumn spanValue
  | line <= 0 || sourceStart spanValue <= 0 = expandedSourceSpanText spanValue
  | otherwise =
      let startColumn = exprColumn + sourceStart spanValue - 1
          endColumn = exprColumn + sourceEnd spanValue - 1
          columnText = if startColumn == endColumn
                         then show startColumn
                         else show startColumn ++ "-" ++ show endColumn
      in " (" ++ path ++ ":" ++ show line ++ ":" ++ columnText ++ ")"

expandedSourceSpanText :: SourceSpan -> String
expandedSourceSpanText spanValue
  | sourceStart spanValue <= 0 = ""
  | otherwise =
      " (expanded-expression columns " ++ sourceSpanText spanValue ++ ")"

sourceSpanText :: SourceSpan -> String
sourceSpanText spanValue
  | sourceStart spanValue == sourceEnd spanValue = show (sourceStart spanValue)
  | otherwise = show (sourceStart spanValue) ++ "-" ++ show (sourceEnd spanValue)
