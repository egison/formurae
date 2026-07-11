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

import Data.List (intercalate, nubBy)

import Formurae.Index (Placement, axisRange, componentPlacement, fieldBaseOf)
import Formurae.Syntax
import Formurae.TensorExpr

data BackendRequest = LbRequest
  { brSource :: String
  , brSpan   :: SourceSpan
  } deriving (Eq, Show)

data AuxLifetime = PersistentState | StepLocal
  deriving (Eq, Show)

data AuxRole
  = LbCoefficient Int
  | LbVolume
  | LbFlux Int
  deriving (Eq, Show)

data AuxFieldPlan = AuxFieldPlan
  { afName      :: String
  , afLifetime  :: AuxLifetime
  , afRole      :: AuxRole
  , afPlacement :: Placement
  }

data LbPlan = LbPlan
  { lpSource     :: String
  , lpResultName :: String
  , lpAuxFields  :: [AuxFieldPlan]
  }

data BackendPlan = BackendPlan
  { bpLbPlan :: Maybe LbPlan
  }

collectBackendRequests :: Model -> Either String [BackendRequest]
collectBackendRequests model = do
  rejectInitializerRequests model
  requests <- concat <$> mapM (requestsInText model . sEx) (mSteps model)
  return (nubBy sameSource requests)
  where
    sameSource lhs rhs = brSource lhs == brSource rhs

planBackend :: Model -> [BackendRequest] -> Either String BackendPlan
planBackend model requests =
  case requests of
    [] -> Right (BackendPlan Nothing)
    [request]
      | mMetric model == Nothing && mEmbed model == Nothing ->
          Left ("lb needs a 'metric scale [...]' or 'embedding [...]' declaration"
                ++ expandedSpanText request)
      | otherwise -> Right (BackendPlan (Just (makeLbPlan model request)))
    _ ->
      Left ("lb currently supports one scalar field per model; found: "
            ++ intercalate ", " (map brSource requests)
            ++ "; expanded-expression spans: "
            ++ intercalate ", " (map requestSpanText requests))

lowerBackendRequests :: BackendPlan -> TensorExpr -> Either String TensorExpr
lowerBackendRequests plan = transformTensorExprM lower
  where
    lower expr =
      case lbApplication expr of
        Just operand ->
          case bpLbPlan plan of
            Nothing -> Left "internal error: lb request has no backend plan"
            Just lbPlan -> do
              source <- simpleLbSource operand
              if source == lpSource lbPlan
                then Right (Just (TEIdent (lpResultName lbPlan) []))
                else Left ("internal error: lb request for " ++ source
                           ++ " does not match its backend plan")
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

makeLbPlan :: Model -> BackendRequest -> LbPlan
makeLbPlan model request =
  let axes = axisRange model
      coefficientNames = take (length axes) ["ca", "cb", "cc"]
      coefficient axis name =
        AuxFieldPlan name PersistentState (LbCoefficient axis)
          (componentPlacement model Primal [axis])
      volume = AuxFieldPlan "sg" PersistentState LbVolume
                 (componentPlacement model Collocated [])
      flux axis = AuxFieldPlan ("f" ++ show axis) StepLocal (LbFlux axis)
                    (componentPlacement model Primal [axis])
  in LbPlan
       { lpSource = brSource request
       , lpResultName = lbResultBindingName
       , lpAuxFields =
           [coefficient axis name | (axis, name) <- zip axes coefficientNames]
           ++ [volume]
           ++ map flux axes
       }

rejectInitializerRequests :: Model -> Either String ()
rejectInitializerRequests model =
  case [expr | initValue <- mInits model, expr <- initExpressions initValue,
               containsLbApplication expr] of
    [] -> Right ()
    expr:_ ->
      Left ("lb is not supported in an initializer because its auxiliary "
            ++ "flux fields are materialized during the step: " ++ expr)

requestsInText :: Model -> String -> Either String [BackendRequest]
requestsInText model source = do
  expr <- case parseTensorExprEither source of
            Right parsed -> Right parsed
            Left msg -> Left ("bad backend request expression: " ++ msg)
  requestsInExpr model expr

requestsInExpr :: Model -> TensorExpr -> Either String [BackendRequest]
requestsInExpr model expr =
  case lbApplication expr of
    Just operand -> do
      source <- simpleLbSource operand
      case kindOf model source of
        Just Scalar
          | fieldPolicyOf model source == Collocated ->
              Right [LbRequest source (tensorExprSpan expr)]
          | otherwise ->
              Left ("lb currently requires a collocated scalar source: " ++ source)
        _ -> Left ("lb expects a scalar field argument: " ++ source)
    Nothing
      | invalidLbHead expr ->
          Left "lb expects exactly one unindexed collocated scalar field"
      | otherwise -> concat <$> mapM (requestsInExpr model) (children expr)

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
  " (expanded-expression columns " ++ requestSpanText request ++ ")"

requestSpanText :: BackendRequest -> String
requestSpanText request =
  show (sourceStart (brSpan request)) ++ "-" ++ show (sourceEnd (brSpan request))
