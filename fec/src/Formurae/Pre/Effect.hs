{-# LANGUAGE PatternSynonyms #-}

-- | Static effect analysis for the normalization unit.
--
-- Continuum operators are ordinary Egison functions. Discrete primitives
-- must survive normalization as versioned FEIR requests. This pass computes
-- that distinction without expanding user definitions and prevents an
-- analytic derivative (or an unsupported higher-order call) from hiding a
-- discrete request inside a value.
module Formurae.Pre.Effect
  ( FunctionEffect(..)
  , EffectSummary(..)
  , EffectIssue(..)
  , EffectError(..)
  , inferModelEffects
  , expressionEffect
  ) where

import Data.Char (isAlphaNum)
import Data.List (find, intercalate, nub, sort)

import qualified Formurae.FEIR.PrimitiveBindings as Primitives
import Formurae.FEIR.PrimitiveManifest
import Formurae.FEIR.Syntax (VersionedOpId(..))
import Formurae.Index
  ( derivativeOpParts
  , ixSuffix
  , parseIndexedIdent
  )
import Formurae.Syntax
import Formurae.TensorExpr

data FunctionEffect
  = PureFunction
  | DiscreteFunction [VersionedOpId]
  deriving (Eq, Ord, Show)

newtype EffectSummary = EffectSummary
  { effectSummaryDefinitions :: [(String, FunctionEffect)]
  } deriving (Eq, Ord, Show)

data EffectIssue
  = InvalidEffectExpression String
  | ForwardDefinitionUse String
  | MissingPrimitiveSignature String
  | AnalyticDerivativeOfDiscrete [VersionedOpId]
  | EffectfulHigherOrderArgument String [VersionedOpId]
  deriving (Eq, Ord, Show)

data EffectError = EffectError
  { effectErrorContext :: String
  , effectErrorIssue :: EffectIssue
  } deriving (Eq, Ord, Show)

data EffectEnvironment = EffectEnvironment
  { environmentModel :: Model
  , environmentManifest :: PrimitiveManifest
  , environmentAllDefinitions :: [String]
  , environmentAvailableDefinitions :: [(String, FunctionEffect)]
  , environmentBoundNames :: [String]
  }

inferModelEffects
    :: PrimitiveManifest -> Model -> Either EffectError EffectSummary
inferModelEffects manifest model = do
  definitions <- inferDefinitions [] (mDefs model)
  let summary = EffectSummary definitions
  mapM_ (checkInitializer summary) (zip [1 :: Int ..] (mInits model))
  mapM_ (checkStep summary) (zip [1 :: Int ..] (mSteps model))
  pure summary
  where
    allDefinitions = map defName (mDefs model)

    inferDefinitions accumulated [] = pure accumulated
    inferDefinitions accumulated (definition : rest) = do
      let context = "definition " ++ defName definition
          environment = EffectEnvironment
            { environmentModel = model
            , environmentManifest = manifest
            , environmentAllDefinitions = allDefinitions
            , environmentAvailableDefinitions = accumulated
            , environmentBoundNames = map definitionParameterBase
                (defParams definition)
            }
      effect <- mapErrorContext context $
        case parseTensorExprEither (defBody definition) of
          Right syntax -> analyzeExpression environment syntax
          Left _ -> analyzeRawEgisonDefinition environment
            (defBody definition)
      inferDefinitions
        (accumulated ++ [(defName definition, effect)]) rest

    checkInitializer summary (index, initializer) =
      mapM_ (checkSource summary ("initializer " ++ show index))
        (initializerExpressions initializer)

    checkStep summary (index, step) =
      checkSource summary
        ("step action " ++ show index ++ " (" ++ sNm step ++ ")")
        (sEx step)

    checkSource summary context source = do
      syntax <- parseIn context source
      _ <- expressionEffect manifest model summary context syntax
      pure ()

expressionEffect
    :: PrimitiveManifest
    -> Model
    -> EffectSummary
    -> String
    -> TensorExpr
    -> Either EffectError FunctionEffect
expressionEffect manifest model (EffectSummary definitions) context expression =
  mapErrorContext context
    (analyzeExpression EffectEnvironment
      { environmentModel = model
      , environmentManifest = manifest
      , environmentAllDefinitions = map fst definitions
      , environmentAvailableDefinitions = definitions
      , environmentBoundNames = []
      } expression)

definitionParameterBase :: String -> String
definitionParameterBase = takeWhile isAlphaNum

parseIn :: String -> String -> Either EffectError TensorExpr
parseIn context source =
  case parseTensorExprEither source of
    Left message -> Left (EffectError context (InvalidEffectExpression message))
    Right expression -> Right expression

-- A definition that uses Egison constructs outside TensorExpr is passed
-- through to Egison instead of being partially reimplemented here.  The
-- initial direct-Egison boundary is intentionally continuum-pure: a shallow
-- identifier scan admits prior pure definitions, but rejects direct or
-- transitive opaque operations.  Current/future definition names remain
-- forward references just as in the structured TensorExpr path.
--
-- The scan only treats formal parameters as known shadowing binders.  Local
-- Egison binders are therefore conservative: shadowing an opaque or future
-- definition name in a raw body is rejected instead of risking an opaque
-- request escaping static effect analysis.
analyzeRawEgisonDefinition
    :: EffectEnvironment -> String -> Either EffectError FunctionEffect
analyzeRawEgisonDefinition environment source = do
  case firstForwardReference of
    Just name -> effectFailure (ForwardDefinitionUse name)
    Nothing -> pure ()
  referencedEffects <- mapM rawIdentifierEffect visibleIdentifiers
  let rawEffect = mergeMany referencedEffects
  case rawEffect of
    PureFunction -> pure PureFunction
    DiscreteFunction operations -> effectFailure (InvalidEffectExpression
      ("direct Egison definition must be continuum-pure; it references "
       ++ "discrete operation" ++ plural operations ++ ": "
       ++ intercalate ", " (map operationText operations)))
  where
    identifiers = rawEgisonIdentifiers environment source
    visibleIdentifiers =
      [identifier | identifier@(name, _) <- identifiers
                  , name `notElem` environmentBoundNames environment]
    availableNames = map fst (environmentAvailableDefinitions environment)
    firstForwardReference = fst <$> find isForward visibleIdentifiers
    isForward (name, _) =
      name `elem` environmentAllDefinitions environment
      && name `notElem` availableNames

    rawIdentifierEffect (name, parts) =
      case lookup name (environmentAvailableDefinitions environment) of
        Just effect -> pure effect
        Nothing ->
          case derivativeOpParts (name ++ concatMap ixSuffix parts) of
            Just (_, radius, _)
              | radius > 1 -> primitiveEffect environment
                  Primitives.derivativeCoordinateWideV1OpId
            _ -> case rawPrimitiveOperation
                    (environmentModel environment) name of
              Nothing -> pure PureFunction
              Just operation -> primitiveEffect environment operation

    plural [_] = ""
    plural _ = "s"

-- Extract identifier bases and their Egison tensor indices without trying
-- to parse the surrounding raw expression.  Quoted strings are masked so a
-- diagnostic message such as "materialize failed" does not acquire a
-- discrete effect.  The optional dot token preserves the existing ability
-- to define (.) as a user function.
rawEgisonIdentifiers :: EffectEnvironment -> String -> [(String, [IxPart])]
rawEgisonIdentifiers environment source = nub (identifiers ++ dotIdentifier)
  where
    tokens = tokenize (maskStrings source)
    identifiers =
      [parseIndexedIdent name | TId name _ <- tokens]
    dotIdentifier
      | "." `elem` environmentAllDefinitions environment
      , any isDot tokens = [(".", [])]
      | otherwise = []
    isDot (TC '.') = True
    isDot _ = False

maskStrings :: String -> String
maskStrings = normal
  where
    normal [] = []
    normal ('"' : rest) = ' ' : quoted rest
    normal (char : rest) = char : normal rest

    quoted [] = []
    quoted ('\\' : _ : rest) = ' ' : ' ' : quoted rest
    quoted ('"' : rest) = ' ' : normal rest
    quoted (_ : rest) = ' ' : quoted rest

-- Raw Egison can spell a bridge call with its qualified library name.  The
-- shallow scanner sees the final component after `Formurae.`, so include the
-- bridge implementation names as well as the ordinary surface aliases.
rawPrimitiveOperation :: Model -> String -> Maybe VersionedOpId
rawPrimitiveOperation model name =
  if hasVariableGeometry model
     && name `elem`
          ["FormuraeInternalCodiff", "FormuraeInternalFormLaplacian"]
    then Just Primitives.codiffMetricV1OpId
    else case lookup name directBridgeOperations of
      Just operation -> Just operation
      Nothing -> surfacePrimitiveOperation model name
  where
    directBridgeOperations =
      [ ("lbOrthogonal", Primitives.lbOrthogonalV1OpId)
      , ("FormuraeInternalLb", Primitives.lbOrthogonalV1OpId)
      , ("coordinateWideDerivative",
          Primitives.derivativeCoordinateWideV1OpId)
      , ("FormuraeInternalCoordinateWideDerivative",
          Primitives.derivativeCoordinateWideV1OpId)
      , ("gridWholeDerivative", Primitives.derivativeGridWholeV1OpId)
      , ("FormuraeInternalGridWholeDerivative",
          Primitives.derivativeGridWholeV1OpId)
      , ("orderedDerivative", Primitives.derivativeOrderedV1OpId)
      , ("FormuraeInternalOrderedDerivative",
          Primitives.derivativeOrderedV1OpId)
      , ("resampleExplicit", Primitives.resampleExplicitV1OpId)
      , ("FormuraeInternalResampleExplicit",
          Primitives.resampleExplicitV1OpId)
      , ("fluxConservativeDivergence",
          Primitives.fluxConservativeDivergenceV1OpId)
      , ("FormuraeInternalFluxConservativeDivergence",
          Primitives.fluxConservativeDivergenceV1OpId)
      , ("materialized", Primitives.operatorMaterializedV1OpId)
      , ("FormuraeInternalMaterialized",
          Primitives.operatorMaterializedV1OpId)
      , ("metricCodiff", Primitives.codiffMetricV1OpId)
      , ("metricDelta", Primitives.codiffMetricV1OpId)
      , ("metricFormLaplacian", Primitives.codiffMetricV1OpId)
      ]

mapErrorContext :: String -> Either EffectError a -> Either EffectError a
mapErrorContext context result =
  case result of
    Left problem -> Left problem { effectErrorContext = context }
    Right value -> Right value

initializerExpressions :: Init -> [String]
initializerExpressions initializer =
  case initializer of
    IRaw _ _ -> []
    IVec _ components -> components
    ISym _ components -> components
    IAnti _ components -> components
    ITensor2 _ components -> components
    ICas _ expression -> [expression]
    ICasIndex _ _ expression -> [expression]

analyzeExpression
    :: EffectEnvironment -> TensorExpr -> Either EffectError FunctionEffect
analyzeExpression environment expression =
  case expression of
    TENumber _ -> pure PureFunction
    -- A bare identifier may be a first-class reference to a user function or
    -- primitive.  Treat it exactly like an application head with no operand
    -- effects so aliases and conditional function values cannot erase a
    -- discrete effect before they are eventually applied.
    TEIdent _ _ -> applicationHeadEffect environment expression PureFunction
    TEUnary _ body -> analyzeExpression environment body
    TECall function arguments -> analyzeApplication environment function arguments
    TEApply function arguments -> analyzeApplication environment function arguments
    TEIf condition yes no ->
      mergeMany <$> mapM (analyzeExpression environment) [condition, yes, no]
    TEAppendIndexed body _ -> analyzeExpression environment body
    TEWithSymbols _ body -> analyzeExpression environment body
    TEContractWith _ body -> analyzeExpression environment body
    TETensorMap function body -> do
      rejectHigherOrder environment "tensorMap" function
      mergeMany <$> mapM (analyzeExpression environment) [function, body]
    TESubrefs body _ -> analyzeExpression environment body
    TETranspose _ body -> analyzeExpression environment body
    TEDisjoint parts -> do
      mapM_ (rejectHigherOrder environment "disjoint product") parts
      mergeMany <$> mapM (analyzeExpression environment) parts
    TEDerivative _ body -> do
      bodyEffect <- analyzeExpression environment body
      requireAnalytic bodyEffect
    TEDot parts -> do
      mapM_ (rejectHigherOrder environment "composition/product") parts
      mergeMany <$> mapM (analyzeExpression environment) parts
    TEBinary _ lhs rhs ->
      mergeMany <$> mapM (analyzeExpression environment) [lhs, rhs]
    TEGroup body -> analyzeExpression environment body
  where
    requireAnalytic PureFunction = pure PureFunction
    requireAnalytic (DiscreteFunction operations) =
      effectFailure (AnalyticDerivativeOfDiscrete operations)

analyzeApplication
    :: EffectEnvironment
    -> TensorExpr
    -> [TensorExpr]
    -> Either EffectError FunctionEffect
analyzeApplication environment function arguments = do
  mapM_ (rejectHigherOrder environment (applicationLabel function)) arguments
  argumentEffect <- mergeMany <$> mapM (analyzeExpression environment) arguments
  functionBodyEffect <- analyzeExpression environment function
  headEffect <- applicationHeadEffect environment function argumentEffect
  pure (mergeMany [functionBodyEffect, argumentEffect, headEffect])

applicationHeadEffect
    :: EffectEnvironment
    -> TensorExpr
    -> FunctionEffect
    -> Either EffectError FunctionEffect
applicationHeadEffect environment function argumentEffect =
  case directHead function of
    Nothing -> pure PureFunction
    Just (name, parts) ->
      case derivativeOpParts (name ++ concatMap ixSuffix parts) of
        Just (_, radius, _)
          | radius == 1 ->
              case argumentEffect of
                PureFunction -> pure PureFunction
                DiscreteFunction operations ->
                  effectFailure (AnalyticDerivativeOfDiscrete operations)
          | otherwise -> primitiveEffect environment
              Primitives.derivativeCoordinateWideV1OpId
        Nothing -> namedHeadEffect environment name

namedHeadEffect
    :: EffectEnvironment -> String -> Either EffectError FunctionEffect
namedHeadEffect environment name =
  if name `elem` environmentBoundNames environment
    then pure PureFunction
    else case lookup name (environmentAvailableDefinitions environment) of
      Just effect -> pure effect
      Nothing
        | elem name (environmentAllDefinitions environment) ->
            effectFailure (ForwardDefinitionUse name)
        | otherwise ->
            case surfacePrimitiveOperation (environmentModel environment) name of
              Nothing -> pure PureFunction
              Just operation -> primitiveEffect environment operation

surfacePrimitiveOperation :: Model -> String -> Maybe VersionedOpId
surfacePrimitiveOperation model name
  | elem name ["gridD", "gridDerivative"] =
      Just Primitives.derivativeGridWholeV1OpId
  | elem name ["orderedDerivative", "orderedD"] =
      Just Primitives.derivativeOrderedV1OpId
  | elem name ["resample", "interpolate"] =
      Just Primitives.resampleExplicitV1OpId
  | elem name ["fluxDiv", "conservativeDiv"] =
      Just Primitives.fluxConservativeDivergenceV1OpId
  | name == "materialize" = Just Primitives.operatorMaterializedV1OpId
  | name == "lb" = Just Primitives.lbOrthogonalV1OpId
  | elem name ["codiff", "delta", "\948"] && hasVariableGeometry model =
      Just Primitives.codiffMetricV1OpId
  | name == "formLaplacian" && hasVariableGeometry model =
      Just Primitives.codiffMetricV1OpId
  | otherwise = Nothing

hasVariableGeometry :: Model -> Bool
hasVariableGeometry model =
  case (mMetric model, mEmbed model) of
    (Nothing, Nothing) -> False
    _ -> True

primitiveEffect
    :: EffectEnvironment -> VersionedOpId -> Either EffectError FunctionEffect
primitiveEffect environment operation =
  case [ primitiveSignatureOpId signature
       | signature <- primitiveManifestSignatures (environmentManifest environment)
       , primitiveSignatureOpId signature == operation
       ] of
    [knownOperation] -> pure (DiscreteFunction [knownOperation])
    _ -> effectFailure (MissingPrimitiveSignature (operationText operation))

operationText :: VersionedOpId -> String
operationText (VersionedOpId value) = value

rejectHigherOrder
    :: EffectEnvironment -> String -> TensorExpr -> Either EffectError ()
rejectHigherOrder environment consumer argument = do
  effect <- latentFunctionEffect environment argument
  case effect of
    PureFunction -> pure ()
    DiscreteFunction operations ->
      effectFailure (EffectfulHigherOrderArgument consumer operations)

-- Recognize the function-value forms that the surface AST can construct
-- without applying them.  A conditional must retain the latent effects of
-- both branches; otherwise wrapping an effectful name in `if` would bypass
-- the higher-order guard.  Applied expressions are deliberately left to the
-- ordinary expression analysis because they may be first-order discrete
-- values (for example materialize(fluxDiv(F))).
latentFunctionEffect
    :: EffectEnvironment -> TensorExpr -> Either EffectError FunctionEffect
latentFunctionEffect environment expression =
  case expression of
    TEIdent _ _ -> applicationHeadEffect environment expression PureFunction
    TEGroup body -> latentFunctionEffect environment body
    TEIf _ yes no -> mergeMany <$> mapM (latentFunctionEffect environment) [yes, no]
    _ -> pure PureFunction

directHead :: TensorExpr -> Maybe (String, [IxPart])
directHead expression =
  case expression of
    TEIdent name parts -> Just (name, parts)
    TEGroup body -> directHead body
    _ -> Nothing

applicationLabel :: TensorExpr -> String
applicationLabel function =
  case directHead function of
    Just (name, _) -> name
    Nothing -> "higher-order application"

mergeMany :: [FunctionEffect] -> FunctionEffect
mergeMany effects =
  case sort . nub $ concatMap operations effects of
    [] -> PureFunction
    discreteOperations -> DiscreteFunction discreteOperations
  where
    operations PureFunction = []
    operations (DiscreteFunction values) = values

effectFailure :: EffectIssue -> Either EffectError a
effectFailure = Left . EffectError "expression"
