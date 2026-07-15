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
import Formurae.Common
  ( analyticDerivativeName
  , egisonIdentifiers
  , egisonIndexedIdentifiers
  , egisonOperators
  , isReservedNormalizationCapability
  , maskEgisonNonCode
  )
import Control.Monad (foldM)
import Formurae.Index
  ( derivativeOpParts
  , ixSuffix
  , parseIndexedIdent
  )
import Formurae.Pre.FormOperator
import Formurae.Syntax
import Formurae.TensorExpr

data FunctionEffect
  = PureFunction
  | DiscreteFunction [VersionedOpId]
  deriving (Eq, Ord, Show)

-- Variable-metric safety needs one small amount of meaning that the
-- Pure/Discrete distinction deliberately does not carry.  Paths are written
-- from the innermost value operation to the outermost operation, so the
-- unsafe weighted-adjoint expansion is the contiguous path Hodge, d, Hodge.
-- This summary is internal: the public effect result remains stable and only
-- reports manifest-backed discrete operations.
data MetricOperator
  = MetricHodge
  | MetricExteriorD
  deriving (Eq, Ord, Show)

newtype MetricSemantics = MetricSemantics
  { metricSemanticPaths :: [[MetricOperator]]
  } deriving (Eq, Ord, Show)

newtype EffectSummary = EffectSummary
  { effectSummaryDefinitions :: [(String, FunctionEffect)]
  } deriving (Eq, Ord, Show)

data EffectIssue
  = InvalidEffectExpression String
  | ForwardDefinitionUse String
  | MissingPrimitiveSignature String
  | AnalyticDerivativeOfDiscrete [VersionedOpId]
  | GridDerivativeOfDiscrete [VersionedOpId]
  | EffectfulHigherOrderArgument String [VersionedOpId]
  | CanonicalOperatorModeMismatch String
  | VariableMetricHodgeLaplacianUnsupported
  | VariableMetricHodgeCompositionUnsupported
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
  , environmentAvailableMetricDefinitions :: [(String, MetricSemantics)]
  , environmentFirstOrderBindings :: [String]
  , environmentBoundNames :: [String]
  }

inferModelEffects
    :: PrimitiveManifest -> Model -> Either EffectError EffectSummary
inferModelEffects manifest model = do
  (definitions, metricDefinitions) <- inferDefinitions [] [] (mDefs model)
  let summary = EffectSummary definitions
      environment = EffectEnvironment
        { environmentModel = model
        , environmentManifest = manifest
        , environmentAllDefinitions = allDefinitions
        , environmentAvailableDefinitions = definitions
        , environmentAvailableMetricDefinitions = metricDefinitions
        , environmentFirstOrderBindings = []
        , environmentBoundNames = []
        }
  mapM_ (checkInitializer environment)
    (zip [1 :: Int ..] (mInits model))
  checkSteps environment (zip [1 :: Int ..] (mSteps model))
  pure summary
  where
    allDefinitions = map defName (mDefs model)

    inferDefinitions accumulatedEffects accumulatedMetrics [] =
      pure (accumulatedEffects, accumulatedMetrics)
    inferDefinitions accumulatedEffects accumulatedMetrics
        (definition : rest) = do
      let context = "definition " ++ defName definition
          environment = EffectEnvironment
            { environmentModel = model
            , environmentManifest = manifest
            , environmentAllDefinitions = allDefinitions
            , environmentAvailableDefinitions = accumulatedEffects
            , environmentAvailableMetricDefinitions = accumulatedMetrics
            , environmentFirstOrderBindings = []
            , environmentBoundNames = map definitionParameterBase
                (defParams definition)
            }
      (effect, metricSemantics) <- mapErrorContext context $ do
        rejectReservedDefinitionConstruction environment
          (defBody definition)
        case parseTensorExprEither (defBody definition) of
          Right syntax -> do
            analyzed <- analyzeExpression environment syntax
            pure (analyzed, expressionMetricSemantics environment syntax)
          Left _ -> do
            analyzed <- analyzeRawEgisonDefinition environment
              (defBody definition)
            pure (analyzed, rawMetricSemantics environment
              (defBody definition))
      inferDefinitions
        (accumulatedEffects ++ [(defName definition, effect)])
        (accumulatedMetrics ++ [(defName definition, metricSemantics)]) rest

    checkInitializer environment (index, initializer) =
      mapM_ (checkSource environment ("initializer " ++ show index))
        (initializerExpressions initializer)

    checkSteps _ [] = pure ()
    checkSteps environment ((index, step) : rest) = do
      let context = "step action " ++ show index ++ " (" ++ sNm step ++ ")"
      syntax <- parseIn context (sEx step)
      effect <- mapErrorContext context
        (analyzeExpression environment syntax)
      let metricSemantics = expressionMetricSemantics environment syntax
          nextEnvironment = case sk step of
            KLet -> registerStepBinding step effect metricSemantics environment
            -- A local materializes its RHS.  The request effect is checked on
            -- this action, but reading the stored field later does not execute
            -- that request again and starts a fresh metric-operator path.
            KLocal -> registerStepBinding step PureFunction
              identityMetricSemantics environment
            KEq -> environment
      checkSteps nextEnvironment rest

    registerStepBinding step effect metricSemantics environment = environment
      { environmentAvailableDefinitions =
          (sNm step, effect) : environmentAvailableDefinitions environment
      , environmentAvailableMetricDefinitions =
          (sNm step, metricSemantics) :
            environmentAvailableMetricDefinitions environment
      , environmentFirstOrderBindings =
          sNm step : environmentFirstOrderBindings environment
      }

    checkSource environment context source = do
      syntax <- parseIn context source
      _ <- mapErrorContext context (analyzeExpression environment syntax)
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
      , environmentAvailableMetricDefinitions = []
      , environmentFirstOrderBindings = []
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
  -- The raw fallback has no application tree, so it cannot prove that a
  -- variable-metric hodge/d combination (including references through prior
  -- user helpers) is not the weighted adjoint pattern hidden behind a local
  -- binder.  Require that combination to stay in the structured surface (or,
  -- preferably, use canonical δ) instead of letting raw Egison silently
  -- product-rule-expand it.
  if hasVariableGeometry (environmentModel environment)
     && rawMetricSemanticsMayCompose (rawMetricSemantics environment source)
    then effectFailure VariableMetricHodgeCompositionUnsupported
    else pure ()
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
            _
              | null parts
              , Just operator <- canonicalOperator name ->
                  canonicalOperatorEffect environment operator
              | otherwise -> case rawPrimitiveOperation
                  (environmentModel environment) name of
                  Nothing -> pure PureFunction
                  Just operation -> primitiveEffect environment operation

    plural [_] = ""
    plural _ = "s"

-- The FEIR opaque boundary is intentionally constructible inside the trusted
-- normalization libraries, but it must not be forgeable from a user
-- definition.  This check runs before choosing structured TensorExpr versus
-- the direct-Egison fallback: otherwise spelling an internal bridge as an
-- ordinary application would bypass a fallback-only gate.  `functionSymbol`
-- can build an arbitrary FunctionData head from a computed string, so checking
-- only the currently known bridge function names is not sound.  Quoted strings
-- are masked by rawEgisonIdentifiers, which keeps diagnostic text containing
-- these names as ordinary continuum-pure data.
rejectReservedDefinitionConstruction
    :: EffectEnvironment -> String -> Either EffectError ()
rejectReservedDefinitionConstruction _environment source =
  case find isReservedConstructor identifiers of
    Just name -> effectFailure (InvalidEffectExpression
      ("user definition cannot access reserved normalization capability "
       ++ name))
    Nothing -> pure ()
  where
    identifiers = egisonIdentifiers (maskEgisonNonCode source)
    isReservedConstructor name =
      name /= "FormuraeInternalKroneckerDelta"
      && isReservedNormalizationCapability name

-- Extract identifier bases and their Egison tensor indices without trying
-- to parse the surrounding raw expression.  Quoted strings are masked so a
-- diagnostic message such as "materialize failed" does not acquire a
-- discrete effect.  The optional dot token preserves the existing ability
-- to define (.) as a user function.
rawEgisonIdentifiers :: EffectEnvironment -> String -> [(String, [IxPart])]
rawEgisonIdentifiers environment source = nub (identifiers ++ dotIdentifier)
  where
    masked = maskEgisonNonCode source
    identifiers = map parseIndexedIdent (egisonIndexedIdentifiers masked)
    dotIdentifier
      | "." `elem` environmentAllDefinitions environment
      , "." `elem` egisonOperators masked = [(".", [])]
      | otherwise = []

-- Raw Egison can spell a bridge call with its qualified library name.  The
-- shallow scanner sees the final component after `Formurae.`, so include the
-- bridge implementation names as well as the ordinary surface aliases.
rawPrimitiveOperation :: Model -> String -> Maybe VersionedOpId
rawPrimitiveOperation model name
  | hasVariableGeometry model
  , name == "FormuraeInternalCodiff" =
      Just Primitives.codiffMetricV1OpId
  | hasVariableGeometry model
  , name == "FormuraeInternalScalarDelta" =
      Just Primitives.lbOrthogonalV1OpId
  | otherwise = case lookup name directBridgeOperations of
      Just operation -> Just operation
      Nothing -> surfacePrimitiveOperation name
  where
    directBridgeOperations =
      [ ("lbOrthogonal", Primitives.lbOrthogonalV1OpId)
      , ("coordinateWideDerivative",
          Primitives.derivativeCoordinateWideV1OpId)
      , ("FormuraeInternalCoordinateWideDerivative",
          Primitives.derivativeCoordinateWideV1OpId)
      , ("gridWholeDerivative", Primitives.derivativeGridWholeV1OpId)
      , ("FormuraeInternalGridWholeDerivative",
          Primitives.derivativeGridWholeV1OpId)
      , ("gridDerivativeChain", Primitives.derivativeOrderedV1OpId)
      , ("FormuraeInternalOrderedDerivative",
          Primitives.derivativeOrderedV1OpId)
      , ("resampleExplicit", Primitives.resampleExplicitV1OpId)
      , ("FormuraeInternalResampleExplicit",
          Primitives.resampleExplicitV1OpId)
      , ("metricCodiff", Primitives.codiffMetricV1OpId)
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
analyzeExpression environment expression
  | hasVariableGeometry (environmentModel environment)
  , Just _ <- matchHodgeExteriorHodge
      (effectOperatorScope environment) expression =
      effectFailure VariableMetricHodgeCompositionUnsupported
  | hasVariableGeometry (environmentModel environment)
  , metricSemanticsContainUnsafeComposition
      (expressionMetricSemantics environment expression) =
      effectFailure VariableMetricHodgeCompositionUnsupported
  | selectedMode (environmentModel environment) == CollocatedMode
  , Just operand <- matchScalarDeltaExpression
      (effectOperatorScope environment) expression = do
      operandEffect <- analyzeExpression environment operand
      operatorEffect <- canonicalOperatorEffect environment
        CanonicalScalarLaplacian
      pure (mergeMany [operandEffect, operatorEffect])
  | otherwise = case expression of
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
    TEContractWith reducer body -> do
      rejectHigherOrder environment "contractWith" (TEIdent reducer [])
      analyzeExpression environment body
    TETensorMap function body -> do
      rejectHigherOrder environment "tensorMap" function
      mergeMany <$> mapM (analyzeExpression environment) [function, body]
    TESubrefs body _ -> analyzeExpression environment body
    TETranspose _ body -> analyzeExpression environment body
    TEDisjoint parts -> do
      mapM_ (rejectHigherOrder environment "disjoint product") parts
      mergeMany <$> mapM (analyzeExpression environment) parts
    -- Layers apply innermost-last, matching the emit-side lowering.
    -- Every subscript layer here is a first derivative, so it is the
    -- lattice's placement-directed radius-one request (a symbolic index
    -- enumerates the axes); orders and primes arrive as pd applications.
    TEDerivative parts body -> do
      bodyEffect <- analyzeExpression environment body
      foldM applyDerivativeLayer bodyEffect (reverse parts)
    TEGridDerivativeChain axes body -> do
      bodyEffect <- analyzeExpression environment body
      case bodyEffect of
        PureFunction ->
          case axes of
            [] -> effectFailure (InvalidEffectExpression
              "quoted derivative chain needs one or more axes")
            [_] -> effectFailure (InvalidEffectExpression
              "a single quoted derivative is redundant; write the coordinate derivative unquoted and reserve backquotes for ordered chains")
            _ -> primitiveEffect environment
              Primitives.derivativeOrderedV1OpId
        DiscreteFunction operations ->
          effectFailure (GridDerivativeOfDiscrete operations)
    TETensorLiteral elements _ ->
      mergeMany <$> mapM (analyzeExpression environment) elements
    TEDot parts
      -- A user definition of (.) replaces the standard contraction/product
      -- operator.  Analyze that definition as the application head so its
      -- latent discrete effect cannot disappear inside derivative syntax.
      | userDefinedDotIsVisible environment ->
          analyzeApplication environment (TEIdent "." []) parts
      | otherwise -> do
          mapM_ (rejectHigherOrder environment "composition/product") parts
          mergeMany <$> mapM (analyzeExpression environment) parts
    TEBinary _ lhs rhs ->
      mergeMany <$> mapM (analyzeExpression environment) [lhs, rhs]
    TEGroup body -> analyzeExpression environment body
  where
    applyDerivativeLayer effect _part =
      case effect of
        PureFunction -> primitiveEffect environment
          Primitives.derivativeGridWholeV1OpId
        DiscreteFunction operations ->
          effectFailure (GridDerivativeOfDiscrete operations)

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
        Just (order, radius, _) ->
          case argumentEffect of
            PureFunction -> primitiveEffect environment
              (if order == 1 && radius == 1
                 then Primitives.derivativeGridWholeV1OpId
                 else Primitives.derivativeCoordinateWideV1OpId)
            DiscreteFunction operations ->
              effectFailure (GridDerivativeOfDiscrete operations)
        Nothing
          | name == analyticDerivativeName ->
              case argumentEffect of
                PureFunction -> pure PureFunction
                DiscreteFunction operations ->
                  effectFailure (AnalyticDerivativeOfDiscrete operations)
          | otherwise -> namedHeadEffect environment name parts

namedHeadEffect
    :: EffectEnvironment
    -> String
    -> [IxPart]
    -> Either EffectError FunctionEffect
namedHeadEffect environment name parts =
  if name `elem` environmentBoundNames environment
    then pure PureFunction
    else case lookup name (environmentAvailableDefinitions environment) of
      Just effect -> pure effect
      Nothing
        | elem name (environmentAllDefinitions environment) ->
            effectFailure (ForwardDefinitionUse name)
        | null parts
        , Just operator <- canonicalOperator name ->
            canonicalOperatorEffect environment operator
        | otherwise ->
            case surfacePrimitiveOperation name of
              Nothing -> pure PureFunction
              Just operation -> primitiveEffect environment operation

surfacePrimitiveOperation :: String -> Maybe VersionedOpId
surfacePrimitiveOperation name
  | name == "resample" =
      Just Primitives.resampleExplicitV1OpId
  | otherwise = Nothing

-- Summarize only the canonical metric operators whose analytic composition
-- can change meaning on a variable metric.  Ordinary algebra keeps paths
-- separate; function application composes an operand path with the semantic
-- path of its head.  Consequently helpers such as
--
--   hs A = hodge A; ex A = d A; hs (ex (hs A))
--
-- retain Hodge,d,Hodge even though no canonical spelling remains in the
-- outer definition.  The combined-argument paths are a conservative guard
-- for higher-order helpers whose parameter-to-result relation is unavailable
-- in TensorExpr.
expressionMetricSemantics :: EffectEnvironment -> TensorExpr -> MetricSemantics
expressionMetricSemantics environment =
  MetricSemantics . normalizeMetricPaths . paths
  where
    paths expression = case expression of
      TENumber _ -> []
      TEIdent name parts -> namedMetricPaths environment name parts
      TEUnary _ body -> paths body
      TECall function arguments -> applicationPaths function arguments
      TEApply function arguments -> applicationPaths function arguments
      TEIf condition yes no -> concatMap paths [condition, yes, no]
      TEAppendIndexed body _ -> paths body
      TEWithSymbols _ body -> paths body
      -- contractWith applies its reducer to tensor components.  Preserve the
      -- reducer's metric semantics just like an ordinary function
      -- application; otherwise a helper reducer containing hodge could hide
      -- the inner leg of hodge . d . hodge on a variable metric.
      TEContractWith reducer body ->
        applicationPaths (TEIdent reducer []) [body]
      TETensorMap function body -> applicationPaths function [body]
      TESubrefs body _ -> paths body
      TETranspose _ body -> paths body
      TEDisjoint parts -> concatMap paths parts
      TEDerivative _ body -> paths body
      TEGridDerivativeChain _ body -> paths body
      TETensorLiteral elements _ -> concatMap paths elements
      TEDot parts
        | userDefinedDotIsVisible environment ->
            applicationPaths (TEIdent "." []) parts
        | otherwise ->
            let partPaths = map paths parts
            in concat partPaths ++ combinedMetricPaths partPaths
      TEBinary _ lhs rhs -> paths lhs ++ paths rhs
      TEGroup body -> paths body

    applicationPaths function arguments = normalizeMetricPaths
      (functionPaths ++ operandPaths ++ individuallyComposed
        ++ combined ++ combinedComposed)
      where
        functionPaths = case directHead function of
          Just (name, parts) -> namedMetricPaths environment name parts
          Nothing -> paths function
        argumentPaths = map paths arguments
        operandPaths = concat argumentPaths
        individuallyComposed = composeMetricPaths operandPaths functionPaths
        combined = combinedMetricPaths argumentPaths
        combinedComposed = composeMetricPaths combined functionPaths

rawMetricSemantics :: EffectEnvironment -> String -> MetricSemantics
rawMetricSemantics environment source = MetricSemantics
  (normalizeMetricPaths (concatMap identifierPaths visibleIdentifiers))
  where
    visibleIdentifiers =
      [ identifier
      | identifier@(name, _) <- rawEgisonIdentifiers environment source
      , name `notElem` environmentBoundNames environment
      ]
    identifierPaths (name, parts) = namedMetricPaths environment name parts

-- Raw Egison has no trustworthy application tree.  Seeing both semantic
-- ingredients, directly or through helpers, is therefore conservatively
-- rejected.  Structured TensorExpr uses the more precise ordered-path test.
rawMetricSemanticsMayCompose :: MetricSemantics -> Bool
rawMetricSemanticsMayCompose semantics =
  metricSemanticsContainUnsafeComposition semantics
  || (MetricHodge `elem` operators && MetricExteriorD `elem` operators)
  where
    operators = concat (metricSemanticPaths semantics)

metricSemanticsContainUnsafeComposition :: MetricSemantics -> Bool
metricSemanticsContainUnsafeComposition =
  any hasUnsafePath . metricSemanticPaths
  where
    hasUnsafePath (MetricHodge : MetricExteriorD : MetricHodge : _) = True
    hasUnsafePath (_ : rest) = hasUnsafePath rest
    hasUnsafePath [] = False

namedMetricPaths
    :: EffectEnvironment -> String -> [IxPart] -> [[MetricOperator]]
namedMetricPaths environment name parts
  | name `elem` environmentBoundNames environment = [[]]
  | Just semantics <- lookup name
      (environmentAvailableMetricDefinitions environment) =
      metricSemanticPaths semantics
  | null parts
  , Just operator <- canonicalOperator name
  , canonicalOperatorIsVisible (effectOperatorScope environment) operator =
      case operator of
        CanonicalHodge -> [[MetricHodge]]
        CanonicalExteriorD -> [[MetricExteriorD]]
        _ -> [[]]
  | otherwise = [[]]

composeMetricPaths
    :: [[MetricOperator]] -> [[MetricOperator]] -> [[MetricOperator]]
composeMetricPaths operands functions =
  [operand ++ function
  | operand <- identityWhenEmpty operands
  , function <- identityWhenEmpty functions]

-- Preserve both source and reverse order.  A general higher-order helper may
-- apply its function-valued arguments in either order, and rejecting the
-- possible weighted-adjoint path is safer than silently expanding it.
combinedMetricPaths :: [[[MetricOperator]]] -> [[MetricOperator]]
combinedMetricPaths groups = normalizeMetricPaths
  (map concat (sequence choices) ++ map concat (sequence (reverse choices)))
  where
    choices = map identityWhenEmpty groups

identityWhenEmpty :: [[MetricOperator]] -> [[MetricOperator]]
identityWhenEmpty [] = [[]]
identityWhenEmpty values = values

normalizeMetricPaths :: [[MetricOperator]] -> [[MetricOperator]]
normalizeMetricPaths = nub

identityMetricSemantics :: MetricSemantics
identityMetricSemantics = MetricSemantics [[]]

effectOperatorScope :: EffectEnvironment -> OperatorScope
effectOperatorScope environment = OperatorScope
  (environmentBoundNames environment ++ environmentAllDefinitions environment)

userDefinedDotIsVisible :: EffectEnvironment -> Bool
userDefinedDotIsVisible environment =
  "." `elem` environmentAllDefinitions environment
  && "." `notElem` environmentBoundNames environment

canonicalOperatorEffect
    :: EffectEnvironment
    -> CanonicalOperator
    -> Either EffectError FunctionEffect
canonicalOperatorEffect environment operator =
  case canonicalOperatorModeError
      (selectedMode (environmentModel environment)) operator of
    Just message -> effectFailure (CanonicalOperatorModeMismatch message)
    Nothing
      | operator == CanonicalHodgeLaplacian
      , hasVariableGeometry (environmentModel environment) ->
          effectFailure VariableMetricHodgeLaplacianUnsupported
      | operator == CanonicalScalarLaplacian
      , hasVariableGeometry (environmentModel environment) ->
          primitiveEffect environment Primitives.lbOrthogonalV1OpId
      | operator == CanonicalCodifferential
      , hasVariableGeometry (environmentModel environment) ->
          primitiveEffect environment Primitives.codiffMetricV1OpId
      | otherwise -> pure PureFunction

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
-- values with nested discrete subexpressions.
latentFunctionEffect
    :: EffectEnvironment -> TensorExpr -> Either EffectError FunctionEffect
latentFunctionEffect environment expression =
  case expression of
    TEIdent name _
      | name `elem` environmentFirstOrderBindings environment ->
          pure PureFunction
      | otherwise -> applicationHeadEffect environment expression PureFunction
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
