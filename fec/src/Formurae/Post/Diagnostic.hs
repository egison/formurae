-- | Source-aware diagnostics for FEIR validation and post-fec lowering.
--
-- FEIR semantic nodes carry stable IDs rather than source spans.  This module
-- is the single place where those IDs are joined back to the OriginTable.  It
-- is deliberately separate from the post-fec executable so callers can use
-- the same rendering in tests, editors, and future library APIs.
module Formurae.Post.Diagnostic
  ( Diagnostic(..)
  , renderDiagnostic
  , renderValidationError
  , renderPostError
  ) where

import Data.List (find, isPrefixOf)

import Formurae.FEIR.Syntax
import Formurae.FEIR.Validate
import qualified Formurae.Post.BackendPlan as Backend
import Formurae.Post.Compile
  ( DerivativeMetadataError(..)
  , GridWholeDerivativeError(..)
  , PostError(..)
  , SbpDerivativeError(..)
  , WideDerivativeError(..)
  )
import Formurae.Post.FMR (FMRError(..))
import Formurae.Post.Location (LocationError(..))
import Formurae.Post.Profile (ProfileError(..))
import Formurae.Post.Stencil (StencilError)

data Diagnostic = Diagnostic
  { diagnosticFallbackPath :: FilePath
  , diagnosticOrigin :: Maybe SourceOrigin
  , diagnosticMessage :: String
  } deriving (Eq, Ord, Show)

diagnoseValidationError :: FEProgram -> ValidationError -> Diagnostic
diagnoseValidationError program validation = Diagnostic
  { diagnosticFallbackPath = programSourcePath program
  , diagnosticOrigin = resolveValidationOrigin program validation
      `orElse` fallbackProgramOrigin program
  , diagnosticMessage = validationIssueMessage
      (validationErrorIssue validation)
  }

diagnosePostError :: FEProgram -> PostError -> Diagnostic
diagnosePostError program postError = Diagnostic
  { diagnosticFallbackPath = programSourcePath program
  , diagnosticOrigin = resolvePostOrigin program postError
      `orElse` fallbackProgramOrigin program
  , diagnosticMessage = postErrorMessage postError
  }

renderValidationError :: FEProgram -> ValidationError -> String
renderValidationError program =
  renderDiagnostic . diagnoseValidationError program

renderPostError :: FEProgram -> PostError -> String
renderPostError program = renderDiagnostic . diagnosePostError program

renderDiagnostic :: Diagnostic -> String
renderDiagnostic diagnostic = firstLine ++ concatMap renderFrame frames
  where
    (locationPrefix, frames) =
      case diagnosticOrigin diagnostic of
        Just origin ->
          (renderSourceLocation (sourceOriginLocation origin),
           sourceOriginTrace origin)
        Nothing ->
          (fallbackPath ++ ":?:?", [])
    fallbackPath
      | null (diagnosticFallbackPath diagnostic) = "<feir>"
      | otherwise = diagnosticFallbackPath diagnostic
    firstLine = locationPrefix ++ ": " ++ diagnosticMessage diagnostic
    renderFrame frame =
      "\n  expanded from " ++ expansionFrameName frame
      ++ " at " ++ renderSourceLocation (expansionFrameCall frame)
      ++ " (defined at "
      ++ renderSourceLocation (expansionFrameDefinition frame) ++ ")"

renderSourceLocation :: SourceLocation -> String
renderSourceLocation location =
  path ++ ":" ++ show (sourceLocationLine location)
  ++ ":" ++ show (sourceLocationStartColumn location)
  where
    path
      | null (sourceLocationPath location) = "<feir>"
      | otherwise = sourceLocationPath location

resolveValidationOrigin
    :: FEProgram -> ValidationError -> Maybe SourceOrigin
resolveValidationOrigin program validation =
  firstResolvedOrigin program (reverse originIds)
  where
    originIds = concatMap (pathOriginIds program)
      (validationErrorPath validation)

resolvePostOrigin :: FEProgram -> PostError -> Maybe SourceOrigin
resolvePostOrigin program postError =
  case postErrorOriginIds program postError of
    [] -> Nothing
    origins -> firstResolvedOrigin program origins

pathOriginIds :: FEProgram -> ValidationPath -> [OriginId]
pathOriginIds program path =
  case path of
    ProgramPath -> []
    ModelPath -> []
    AxisPath axisId -> maybeToList
      (axisDeclOrigin <$> findBy axisDeclId axisId (feProgramAxes program))
    ParameterPath parameterId -> maybeToList
      (parameterDeclOrigin <$>
        findBy parameterDeclId parameterId (feProgramParameters program))
    FunctionPath functionId -> maybeToList
      (functionDeclOrigin =<<
        findBy functionDeclId functionId (feProgramFunctions program))
    FieldPath fieldId -> maybeToList
      (logicalFieldOrigin <$>
        findBy logicalFieldId fieldId (feProgramFields program))
    GeometryPath geometryId
      | geometryDeclId (feProgramGeometry program) == geometryId ->
          maybeToList (geometryDeclOrigin (feProgramGeometry program))
      | otherwise -> []
    ProfilePath ->
      map derivativeRuleOrigin
        (discretizationDerivativeRules (feProgramDiscretization program))
    DerivativeRulePath index -> maybeToList
      (derivativeRuleOrigin <$> atIndex index
        (discretizationDerivativeRules (feProgramDiscretization program)))
    InitializerPath index -> maybeToList
      (initializerOrigin =<< atIndex index (feProgramInitializers program))
    ActionPath index -> maybeToList
      (actionOrigin <$> atIndex index (feProgramStepActions program))
    EquationPath equationId -> maybeToList
      (feEquationOrigin <$> findEquation program equationId)
    NodePath nodeId -> maybeToList (nodeOrigin program nodeId)
    TensorComponentPath _ -> []
    ScalarChildPath _ -> []
    PredicateChildPath _ -> []
    OpaquePath semanticKey -> maybeToList
      (locatedOpaqueOrigin <$> findLocatedOpaqueByKey program semanticKey)
    AttributePath _ -> []
    RawHelperPath helperId -> maybeToList
      (rawHelperOrigin <$>
        findBy rawHelperId helperId (feProgramRawHelpers program))
    OriginPath originId -> [originId]
    ProvenancePath nodeId -> provenanceOrigins program nodeId

postErrorOriginIds :: FEProgram -> PostError -> [OriginId]
postErrorOriginIds program postError =
  case postError of
    PostAtOrigin origin _ -> [origin]
    PostBackendPlanError backendError ->
      backendErrorOriginIds program backendError
    PostFMRError fmrError -> fmrErrorOriginIds program fmrError
    PostLocationError locationError ->
      locationErrorOriginIds program locationError
    PostUnknownField fieldId -> fieldOriginIds program fieldId
    PostUnknownParameter parameterId -> parameterOriginIds program parameterId
    PostUnknownFunction functionId -> functionOriginIds program functionId
    PostUnknownAxis axisId -> axisOriginIds program axisId
    PostUnknownBinding nodeId -> nodeOriginIds program nodeId
    PostTensorBindingUsedAsScalar nodeId -> nodeOriginIds program nodeId
    PostMissingTensorComponent _ -> []
    PostNonScalarComponent _ _ -> []
    PostUnsupportedDerivative jet -> fieldOriginIds program (fieldJetFieldId jet)
    PostUnsupportedOpaque opId -> maybeToList
      (locatedOpaqueOrigin <$> findLocatedOpaqueByOp program opId)
    PostWideDerivativeError semanticKey _ -> maybeToList
      (locatedOpaqueOrigin <$> findLocatedOpaqueByKey program semanticKey)
    PostGridWholeDerivativeError semanticKey _ -> maybeToList
      (locatedOpaqueOrigin <$> findLocatedOpaqueByKey program semanticKey)
    PostSbpDerivativeError semanticKey _ -> maybeToList
      (locatedOpaqueOrigin <$> findLocatedOpaqueByKey program semanticKey)
    PostPrimitiveContractError semanticKey _ -> maybeToList
      (locatedOpaqueOrigin <$> findLocatedOpaqueByKey program semanticKey)
    PostExplicitStencilError semanticKey _ -> maybeToList
      (locatedOpaqueOrigin <$> findLocatedOpaqueByKey program semanticKey)
    PostDerivativeLatticeMismatch semanticKey _ _ -> maybeToList
      (locatedOpaqueOrigin <$> findLocatedOpaqueByKey program semanticKey)
    PostProfileError profileError -> profileErrorOriginIds program profileError
    PostInvalidReferencePlacement _ _ -> []
    PostInvalidTarget target -> fieldOriginIds program (targetFieldId target)
    PostInvalidAuxiliaryPlan _ -> maybeToList
      (locatedOpaqueOrigin <$> firstLocatedOpaque program)
    PostDuplicateAssignment name -> storageNameOriginIds program name

backendErrorOriginIds
    :: FEProgram -> Backend.BackendPlanError -> [OriginId]
backendErrorOriginIds program backendError =
  case backendError of
    Backend.EffectfulRequestInInitializer _ _ origin -> [origin]
    Backend.ConflictingOpaqueSemanticKey key -> maybeToList
      (locatedOpaqueOrigin <$> findLocatedOpaqueByKey program key)
    Backend.ConflictingOpaqueRequestGroup group -> maybeToList
      (locatedOpaqueOrigin <$> findLocatedOpaqueByGroup program group)
    Backend.UnsupportedEffectfulOperation _ _ origin -> [origin]

fmrErrorOriginIds :: FEProgram -> FMRError -> [OriginId]
fmrErrorOriginIds program fmrError =
  case fmrError of
    InvalidFMRDimension _ -> []
    InvalidFMRShape fieldId _ -> fieldOriginIds program fieldId
    InvalidFMRBasis fieldId _ -> fieldOriginIds program fieldId
    InvalidFMRLayout fieldId _ _ -> fieldOriginIds program fieldId
    InvalidDeclaredVarianceCount fieldId _ _ -> fieldOriginIds program fieldId
    InvalidExactDenominator _ -> []
    EmptyFMRExpression _ -> []

locationErrorOriginIds :: FEProgram -> LocationError -> [OriginId]
locationErrorOriginIds program locationError =
  case locationError of
    InvalidLocationDimension _ -> []
    InvalidBasisAxis _ _ -> []
    InvalidDerivativeAxis axisId _ -> axisOriginIds program axisId
    ZeroDerivativeMultiplicity axisId -> axisOriginIds program axisId
    PlacementDimensionMismatch _ _ -> []
    UnknownLocationField fieldId -> fieldOriginIds program fieldId
    FieldJetBasisMismatch fieldId _ -> fieldOriginIds program fieldId
    LocatedPlacementMismatch _ _ -> []
    AmbiguousSampleableDemand -> []

profileErrorOriginIds :: FEProgram -> ProfileError -> [OriginId]
profileErrorOriginIds program profileError =
  case profileError of
    InvalidProfileDerivativeOrder order -> ruleOrigins
      (\rule -> ruleOrder rule == Just order)
    InvalidProfileFormalAccuracy accuracy -> ruleOrigins
      (\rule -> ruleAccuracy rule == accuracy)
    InvalidProfileLatticeFamily lattice family -> ruleOrigins
      (\rule -> derivativeRuleLatticeClass rule == lattice
        && derivativeRuleFamily rule == family)
    DuplicateProfileRule lattice order -> dropFirst (ruleOrigins
      (\rule -> derivativeRuleLatticeClass rule == lattice
        && ruleOrder rule == order))
    NonCanonicalProfileRuleOrder -> allRuleOrigins
    ZeroFieldJetDerivative axisId -> axisOriginIds program axisId
    DuplicateFieldJetDerivativeAxis axisId -> axisOriginIds program axisId
    NonCanonicalFieldJetDerivativeOrder -> allRuleOrigins
    FieldJetDerivativeOrderTooLarge axisId _ -> axisOriginIds program axisId
    ProfileStencilError _ -> allRuleOrigins
  where
    rules = discretizationDerivativeRules (feProgramDiscretization program)
    allRuleOrigins = map derivativeRuleOrigin rules
    ruleOrigins predicate = map derivativeRuleOrigin (filter predicate rules)
    ruleOrder rule =
      case derivativeRuleOrder rule of
        Nothing -> Nothing
        Just (Positive order) -> Just order
    ruleAccuracy rule =
      let PositiveEven accuracy = derivativeRuleAccuracy rule in accuracy
    dropFirst (_ : second : rest) = second : rest
    dropFirst origins = origins

fieldOriginIds :: FEProgram -> FieldId -> [OriginId]
fieldOriginIds program fieldId = maybeToList
  (logicalFieldOrigin <$>
    findBy logicalFieldId fieldId (feProgramFields program))

parameterOriginIds :: FEProgram -> ParamId -> [OriginId]
parameterOriginIds program parameterId = maybeToList
  (parameterDeclOrigin <$>
    findBy parameterDeclId parameterId (feProgramParameters program))

functionOriginIds :: FEProgram -> FunctionId -> [OriginId]
functionOriginIds program functionId = maybeToList
  (functionDeclOrigin =<<
    findBy functionDeclId functionId (feProgramFunctions program))

axisOriginIds :: FEProgram -> AxisId -> [OriginId]
axisOriginIds program axisId = maybeToList
  (axisDeclOrigin <$> findBy axisDeclId axisId (feProgramAxes program))

nodeOriginIds :: FEProgram -> NodeId -> [OriginId]
nodeOriginIds program nodeId =
  maybeToList (nodeOrigin program nodeId) ++ provenanceOrigins program nodeId

storageNameOriginIds :: FEProgram -> String -> [OriginId]
storageNameOriginIds program name =
  [ logicalFieldOrigin field
  | field <- feProgramFields program
  , let sourceName = logicalFieldSourceName field
  , name == sourceName || (sourceName ++ "_") `isPrefixOf` name
  ]

firstResolvedOrigin :: FEProgram -> [OriginId] -> Maybe SourceOrigin
firstResolvedOrigin program originIds = firstJust
  [lookupOrigin program originId | originId <- originIds]

lookupOrigin :: FEProgram -> OriginId -> Maybe SourceOrigin
lookupOrigin program originId = lookup originId entries
  where
    OriginTable entries = feProgramOrigins program

programSourcePath :: FEProgram -> FilePath
programSourcePath =
  sourceIdentityPath . modelIdentitySource . feProgramModel

initializerOrigin :: FEInitializer -> Maybe OriginId
initializerOrigin initializer =
  case initializer of
    AnalyticInitializer equation -> Just (feEquationOrigin equation)
    RawInitializer _ _ origin -> Just origin

actionOrigin :: FEAction -> OriginId
actionOrigin action =
  case action of
    BindValue _ _ origin -> origin
    Materialize _ _ origin -> origin
    UpdateField equation -> feEquationOrigin equation

nodeOrigin :: FEProgram -> NodeId -> Maybe OriginId
nodeOrigin program nodeId = firstJust
  [ case action of
      BindValue candidate _ origin
        | candidate == nodeId -> Just origin
      _ -> Nothing
  | action <- feProgramStepActions program
  ]

provenanceOrigins :: FEProgram -> NodeId -> [OriginId]
provenanceOrigins program nodeId =
  case lookup nodeId entries of
    Just origins -> origins
    Nothing -> []
  where
    ProvenanceTable entries = feProgramProvenance program

findEquation :: FEProgram -> EquationId -> Maybe FEEquation
findEquation program equationId = find
  ((== equationId) . feEquationId) equations
  where
    equations =
      [equation | AnalyticInitializer equation <- feProgramInitializers program]
      ++ [equation | UpdateField equation <- feProgramStepActions program]

targetFieldId :: FieldTarget -> FieldId
targetFieldId target =
  case target of
    WholeFieldTarget fieldId _ -> fieldId
    FieldComponentTarget fieldId _ _ -> fieldId

data LocatedOpaque = LocatedOpaque
  { locatedOpaqueValue :: OpaqueDiscrete
  , locatedOpaqueOrigin :: OriginId
  } deriving (Eq, Ord, Show)

firstLocatedOpaque :: FEProgram -> Maybe LocatedOpaque
firstLocatedOpaque program =
  case collectLocatedOpaque program of
    value : _ -> Just value
    [] -> Nothing

findLocatedOpaqueByKey :: FEProgram -> SemanticKey -> Maybe LocatedOpaque
findLocatedOpaqueByKey program key = find
  ((== key) . opaqueDiscreteSemanticKey . locatedOpaqueValue)
  (collectLocatedOpaque program)

findLocatedOpaqueByGroup
    :: FEProgram -> RequestGroupId -> Maybe LocatedOpaque
findLocatedOpaqueByGroup program group = find
  ((== group) . opaqueDiscreteRequestGroup . locatedOpaqueValue)
  (collectLocatedOpaque program)

findLocatedOpaqueByOp :: FEProgram -> OpId -> Maybe LocatedOpaque
findLocatedOpaqueByOp program opId = find
  ((== opId) . opaqueDiscreteOpId . locatedOpaqueValue)
  (collectLocatedOpaque program)

collectLocatedOpaque :: FEProgram -> [LocatedOpaque]
collectLocatedOpaque program =
  geometryOpaque ++ initializerOpaque ++ actionOpaque
  where
    geometryOpaque =
      case geometryDeclOrigin (feProgramGeometry program) of
        Just origin -> collectGeometryOpaque origin
          (geometryDeclKind (feProgramGeometry program))
        Nothing -> []
    initializerOpaque = concatMap collectInitializer
      (feProgramInitializers program)
    actionOpaque = concatMap collectAction (feProgramStepActions program)

    collectInitializer initializer =
      case initializer of
        AnalyticInitializer equation -> collectTensorOpaque
          (feEquationOrigin equation) (feEquationRhs equation)
        RawInitializer _ _ _ -> []
    collectAction action =
      case action of
        BindValue _ value origin -> collectValueOpaque origin value
        Materialize _ value origin -> collectValueOpaque origin value
        UpdateField equation -> collectTensorOpaque
          (feEquationOrigin equation) (feEquationRhs equation)

collectGeometryOpaque :: OriginId -> GeometryKind -> [LocatedOpaque]
collectGeometryOpaque origin geometry =
  case geometry of
    EuclideanGeometry -> []
    OrthogonalScaleGeometry scales normalForm ->
      concatMap (collectScalarOpaque origin . snd) scales
      ++ collectGeometryNFOpaque origin normalForm
    EmbeddedOrthogonalGeometry embedding normalForm ->
      concatMap (collectScalarOpaque origin) embedding
      ++ collectGeometryNFOpaque origin normalForm

collectGeometryNFOpaque :: OriginId -> GeometryNF -> [LocatedOpaque]
collectGeometryNFOpaque origin normalForm = concat
  [ collectTensorOpaque origin (geometryMetricComponents normalForm)
  , collectTensorOpaque origin (geometryInverseMetric normalForm)
  , concatMap (collectScalarOpaque origin . snd)
      (geometryScaleFactors normalForm)
  , collectScalarOpaque origin (geometryVolumeElement normalForm)
  ]

collectValueOpaque :: OriginId -> FEValue -> [LocatedOpaque]
collectValueOpaque origin value =
  case value of
    ScalarValue scalar -> collectScalarOpaque origin scalar
    TensorValue tensor -> collectTensorOpaque origin tensor

collectTensorOpaque :: OriginId -> TensorNF -> [LocatedOpaque]
collectTensorOpaque origin tensor = concatMap
  (collectScalarOpaque origin . snd) (tensorNFComponents tensor)

collectScalarOpaque :: OriginId -> ScalarNF -> [LocatedOpaque]
collectScalarOpaque origin scalar =
  case scalar of
    Exact _ _ -> []
    NamedConstant _ -> []
    Parameter _ -> []
    Coordinate _ -> []
    Add values -> concatMap recurse values
    Mul values -> concatMap recurse values
    Div numerator denominator -> recurse numerator ++ recurse denominator
    Pow base power -> recurse base ++ recurse power
    Intrinsic _ arguments -> concatMap recurse arguments
    AnalyticCall _ arguments -> concatMap recurse arguments
    Select predicate yes no ->
      collectPredicateOpaque origin predicate ++ recurse yes ++ recurse no
    FieldJet _ -> []
    OpaqueDiscrete opaque ->
      LocatedOpaque opaque origin
      : concatMap (collectValueOpaque origin) (opaqueDiscreteOperands opaque)
    Ref _ -> []
  where
    recurse = collectScalarOpaque origin

collectPredicateOpaque :: OriginId -> PredicateNF -> [LocatedOpaque]
collectPredicateOpaque origin predicate =
  case predicate of
    BoolExact _ -> []
    Compare _ lhs rhs -> recurse lhs ++ recurse rhs
    Not body -> collectPredicateOpaque origin body
    And values -> concatMap (collectPredicateOpaque origin) values
    Or values -> concatMap (collectPredicateOpaque origin) values
  where
    recurse = collectScalarOpaque origin

findBy :: Eq key => (value -> key) -> key -> [value] -> Maybe value
findBy project key = find ((== key) . project)

atIndex :: Int -> [a] -> Maybe a
atIndex index values
  | index < 0 = Nothing
  | otherwise =
      case drop index values of
        value : _ -> Just value
        [] -> Nothing

maybeToList :: Maybe a -> [a]
maybeToList (Just value) = [value]
maybeToList Nothing = []

firstJust :: [Maybe a] -> Maybe a
firstJust [] = Nothing
firstJust (Just value : _) = Just value
firstJust (Nothing : rest) = firstJust rest

orElse :: Maybe a -> Maybe a -> Maybe a
orElse (Just value) _ = Just value
orElse Nothing fallback = fallback

-- Header-level or deliberately malformed-reference errors may have no
-- semantic node to name.  A valid FEIR program still has an OriginTable, so
-- use its earliest source entry instead of degrading to an unknown location.
fallbackProgramOrigin :: FEProgram -> Maybe SourceOrigin
fallbackProgramOrigin program =
  case entries of
    (_, origin) : _ -> Just origin
    [] -> Nothing
  where
    OriginTable entries = feProgramOrigins program

validationIssueMessage :: ValidationIssue -> String
validationIssueMessage issue =
  case issue of
    EmptyIdentifier namespace ->
      identifierNamespaceName namespace ++ " must not be empty"
    NonPositiveIdentifier namespace value ->
      identifierNamespaceName namespace ++ " must be positive, got "
      ++ show value
    DuplicateIdentifier namespace value ->
      "duplicate " ++ identifierNamespaceName namespace ++ " " ++ value
    UnknownReference namespace value ->
      "unknown " ++ identifierNamespaceName namespace ++ " " ++ value
    RegistryIdMismatch expected actual ->
      "registry ID mismatch: expected " ++ show expected
      ++ ", got " ++ show actual
    PrimitiveManifestIdMismatch expected actual ->
      "primitive manifest ID mismatch: expected " ++ show expected
      ++ ", got " ++ show actual
    PrimitiveSignatureTableManifestMismatch expected actual ->
      "primitive signature table mismatch: expected manifest "
      ++ show expected ++ ", got " ++ show actual
    InvalidPrimitiveSignatureTable reason ->
      "invalid primitive signature table: " ++ reason
    InvalidDimension dimension ->
      "dimension must be positive, got " ++ show dimension
    AxisCountMismatch dimension count ->
      "dimension " ++ show dimension ++ " has " ++ show count
      ++ " axis declarations"
    AxisIdSequenceMismatch expected actual ->
      "axis ID sequence mismatch: expected " ++ show expected
      ++ ", got " ++ show actual
    DuplicateName label name ->
      "duplicate " ++ label ++ " " ++ show name
    NonCanonicalOrder label ->
      label ++ " is not in canonical order"
    InvalidSourceLocation location ->
      "invalid source location " ++ show location
    InvalidShape shape -> "invalid tensor shape " ++ show shape
    TensorAxisDimensionMismatch dimension shape ->
      "tensor shape " ++ show shape ++ " does not use dimension "
      ++ show dimension
    VarianceCountMismatch rank count ->
      "tensor rank " ++ show rank ++ " has " ++ show count
      ++ " variance markers"
    InvalidDifferentialFormOrder rank degree ->
      "invalid differential-form degree " ++ show degree
      ++ " for tensor rank " ++ show rank
    ComponentBasisMismatch expected actual ->
      "component basis mismatch: expected " ++ show expected
      ++ ", got " ++ show actual
    InvalidBasis basis shape ->
      "basis " ++ show basis ++ " is invalid for shape " ++ show shape
    InvalidLayout layout tensorType ->
      "layout " ++ show layout ++ " is invalid for " ++ show tensorType
    DeclaredVarianceCountMismatch expected actual ->
      "declared variance count mismatch: expected " ++ show expected
      ++ ", got " ++ show actual
    DeclaredVarianceMismatch axis expected actual ->
      "declared variance mismatch on tensor axis " ++ show axis
      ++ ": expected " ++ show expected ++ ", got " ++ show actual
    NonCanonicalExact numerator denominator ->
      "non-canonical exact rational " ++ show numerator ++ "/"
      ++ show denominator
    NonCanonicalScalarForm reason ->
      "non-canonical scalar normal form: " ++ reason
    NonCanonicalPredicateForm reason ->
      "non-canonical predicate normal form: " ++ reason
    DivisionByZero -> "division by zero"
    InvalidFunctionArity arity ->
      "function arity must be nonnegative, got " ++ show arity
    FunctionClassMismatch functionId expected actual ->
      "function " ++ show functionId ++ " class mismatch: expected "
      ++ show expected ++ ", got " ++ show actual
    FunctionArityMismatch functionId expected actual ->
      "function " ++ show functionId ++ " arity mismatch: expected "
      ++ show expected ++ ", got " ++ show actual
    NonCanonicalFieldArguments expected actual ->
      "field arguments are not canonical: expected " ++ show expected
      ++ ", got " ++ show actual
    NonCanonicalMultiIndex multiIndex ->
      "non-canonical derivative multi-index " ++ show multiIndex
    RefOutsideActionStream nodeId ->
      "reference " ++ show nodeId ++ " occurs outside the action stream"
    RefNotPreceding nodeId ->
      "reference " ++ show nodeId ++ " does not name a preceding binding"
    FieldValueNotAvailable fieldId timeSlot ->
      "field " ++ show fieldId ++ " at " ++ show timeSlot
      ++ " is not available here"
    InvalidTargetTime expected actual ->
      "invalid target time: expected " ++ show expected
      ++ ", got " ++ show actual
    ComponentUpdateTargetNotAllowed fieldId basis ->
      "field update " ++ show fieldId
      ++ " must use a whole-field target, got component " ++ show basis
    InvalidFieldLifetime fieldId expected actual ->
      "field " ++ show fieldId ++ " lifetime mismatch: expected "
      ++ show expected ++ ", got " ++ show actual
    TensorTypeMismatch expected actual ->
      "tensor type mismatch: expected " ++ show expected
      ++ ", got " ++ show actual
    InvalidDerivativeRuleOrder order ->
      "derivative rule order must be positive, got " ++ show order
    InvalidFormalAccuracy accuracy ->
      "formal accuracy must be positive and even, got " ++ show accuracy
    InvalidLatticeFamily lattice family ->
      "stencil family " ++ show family ++ " is invalid for " ++ show lattice
    DuplicateDerivativeRule lattice order ->
      "duplicate derivative rule for " ++ show lattice
      ++ " order " ++ maybe "default" show order
    ProfileFingerprintMismatch expected actual ->
      "profile fingerprint mismatch: expected " ++ show expected
      ++ ", got " ++ show actual
    EmptyOpaqueSemanticKey -> "opaque semantic key must not be empty"
    EmptyOpaqueRequestGroup -> "opaque request group must not be empty"
    UnknownOpaqueOperation opId ->
      "unknown opaque operation " ++ show opId
    OpaqueOperandCountMismatch opId expected actual ->
      "opaque operation " ++ show opId ++ " operand count mismatch: expected "
      ++ show expected ++ ", got " ++ show actual
    OpaqueOperandCategoryMismatch opId index category ->
      "opaque operation " ++ show opId ++ " operand " ++ show index
      ++ " does not match manifest category " ++ show category
    OpaqueOutputCategoryMismatch opId category basis ->
      "opaque operation " ++ show opId ++ " result basis " ++ show basis
      ++ " does not match manifest category " ++ show category
    OpaqueEffectContextMismatch opId effect ->
      "opaque operation " ++ show opId ++ " with effect " ++ show effect
      ++ " is not allowed outside the step action stream"
    OpaquePlacementContractMismatch opId placement basis ->
      "opaque operation " ++ show opId ++ " result basis " ++ show basis
      ++ " violates manifest placement " ++ show placement
    ConflictingOpaqueSemanticKey key ->
      "conflicting payloads for opaque semantic key " ++ show key
    UnverifiedOrthogonalGeometry ->
      "orthogonal geometry has not been symbolically verified"
    InvalidEmbeddedGeometry -> "embedded geometry must not be empty"
    EmptyProvenance -> "provenance origin set must not be empty"

identifierNamespaceName :: IdNamespace -> String
identifierNamespaceName namespace =
  case namespace of
    ModelIds -> "model ID"
    SourceIds -> "source ID"
    RegistryIds -> "registry ID"
    PrimitiveManifestIds -> "primitive manifest ID"
    ProfileIds -> "profile ID"
    AxisIds -> "axis ID"
    ParameterIds -> "parameter ID"
    FunctionIds -> "function ID"
    FieldIds -> "field ID"
    GeometryIds -> "geometry ID"
    RawHelperIds -> "raw-helper ID"
    OriginIds -> "origin ID"
    NodeIds -> "node ID"
    EquationIds -> "equation ID"
    OpaqueOperationIds -> "opaque operation ID"
    SemanticKeys -> "semantic key"
    RequestGroupIds -> "request-group ID"
    AttributeIds -> "attribute ID"

postErrorMessage :: PostError -> String
postErrorMessage postError =
  case postError of
    PostAtOrigin _ nested -> postErrorMessage nested
    PostBackendPlanError backendError -> backendErrorMessage backendError
    PostFMRError fmrError -> fmrErrorMessage fmrError
    PostLocationError locationError -> locationErrorMessage locationError
    PostUnknownField fieldId -> "unknown field " ++ show fieldId
    PostUnknownParameter parameterId ->
      "unknown parameter " ++ show parameterId
    PostUnknownFunction functionId ->
      "unknown function " ++ show functionId
    PostUnknownAxis axisId -> "unknown axis " ++ show axisId
    PostUnknownBinding nodeId -> "unknown binding " ++ show nodeId
    PostTensorBindingUsedAsScalar nodeId ->
      "tensor binding " ++ show nodeId ++ " was used as a scalar"
    PostMissingTensorComponent basis ->
      "missing tensor component " ++ show basis
    PostNonScalarComponent basis shape ->
      "scalar value cannot provide component " ++ show basis
      ++ " of shape " ++ show shape
    PostUnsupportedDerivative jet ->
      "unsupported analytic derivative " ++ show jet
    PostUnsupportedOpaque opId ->
      "unsupported opaque operation " ++ show opId
    PostWideDerivativeError _ wideError -> wideDerivativeErrorMessage wideError
    PostSbpDerivativeError _ sbpError -> sbpDerivativeErrorMessage sbpError
    PostGridWholeDerivativeError _ gridError ->
      gridWholeDerivativeErrorMessage gridError
    PostPrimitiveContractError _ contractError ->
      "explicit primitive contract error: " ++ show contractError
    PostExplicitStencilError _ stencilError ->
      "explicit primitive stencil error: " ++ show stencilError
    PostDerivativeLatticeMismatch _ lhs rhs ->
      "discrete derivative operand mixes lattice classes " ++ show lhs
      ++ " and " ++ show rhs
    PostProfileError profileError -> profileErrorMessage profileError
    PostInvalidReferencePlacement expected actual ->
      "grid placement mismatch: target " ++ show expected
      ++ ", expression " ++ show actual
    PostInvalidTarget target -> "invalid field target " ++ show target
    PostInvalidAuxiliaryPlan reason ->
      "invalid backend auxiliary plan: " ++ reason
    PostDuplicateAssignment name ->
      "duplicate generated assignment to " ++ name

wideDerivativeErrorMessage :: WideDerivativeError -> String
wideDerivativeErrorMessage wideError =
  case wideError of
    WideMetadataError metadata ->
      derivativeMetadataErrorMessage "wide derivative" metadata
    WideOrderExceedsDiameter order radius ->
      "wide derivative order " ++ show order
      ++ " exceeds the diameter of radius " ++ show radius
    WideStencilFailure stencilError ->
      "wide derivative stencil error: " ++ show stencilError

sbpDerivativeErrorMessage :: SbpDerivativeError -> String
sbpDerivativeErrorMessage sbpError =
  case sbpError of
    SbpMetadataError metadata ->
      derivativeMetadataErrorMessage "SBP staggered derivative" metadata
    SbpOrderUnsupported order ->
      "SBP staggered derivative order must be 1 or 2, got " ++ show order
    SbpRadiusMustBeOne radius ->
      "SBP staggered derivative radius must be 1, got " ++ show radius
    SbpRequiresStaggeredLattice ->
      "SBP staggered derivative needs a staggered-lattice operand"
    SbpSecondOrderNeedsIntegerPlacement placement ->
      "SBP second derivative needs an integer-placed operand, got "
      ++ show placement
    SbpClosureFailure stencilError ->
      "SBP closure error: " ++ stencilErrorMessage stencilError

gridWholeDerivativeErrorMessage :: GridWholeDerivativeError -> String
gridWholeDerivativeErrorMessage gridError =
  case gridError of
    GridWholeMetadataError metadata ->
      derivativeMetadataErrorMessage "grid-whole derivative" metadata
    GridWholeOrderMustBeOne order ->
      "grid-whole derivative order must be 1, got " ++ show order
    GridWholeRadiusMustBeOne radius ->
      "grid-whole derivative radius must be 1, got " ++ show radius
    GridWholeStencilFailure stencilError ->
      "grid-whole derivative stencil error: " ++ show stencilError

derivativeMetadataErrorMessage
    :: String -> DerivativeMetadataError -> String
derivativeMetadataErrorMessage operation metadata =
  case metadata of
    DerivativeMissingAttribute attributeIdentifier ->
      operation ++ " is missing attribute " ++ show attributeIdentifier
    DerivativeDuplicateAttribute attributeIdentifier ->
      operation ++ " has duplicate attribute " ++ show attributeIdentifier
    DerivativeUnknownAttribute attributeIdentifier ->
      operation ++ " has unknown attribute " ++ show attributeIdentifier
    DerivativeInvalidAttribute attributeIdentifier value ->
      operation ++ " has invalid attribute " ++ show attributeIdentifier
      ++ " = " ++ show value
    DerivativeInvalidResultBasis basis ->
      operation ++ " result must be scalar, got basis " ++ show basis
    DerivativeInvalidOperand ->
      operation ++ " expects exactly one scalar operand"
    DerivativeOrderOutOfRange order ->
      operation ++ " order is out of range: " ++ show order
    DerivativeRadiusOutOfRange radius ->
      operation ++ " radius is out of range: " ++ show radius

backendErrorMessage :: Backend.BackendPlanError -> String
backendErrorMessage backendError =
  case backendError of
    Backend.EffectfulRequestInInitializer opId key _ ->
      "effectful operation " ++ show opId ++ " (" ++ show key
      ++ ") is not allowed in an initializer"
    Backend.ConflictingOpaqueSemanticKey key ->
      "conflicting opaque semantic key " ++ show key
    Backend.ConflictingOpaqueRequestGroup group ->
      "conflicting opaque request group " ++ show group
    Backend.UnsupportedEffectfulOperation opId key _ ->
      "effectful operation " ++ show opId ++ " (" ++ show key
      ++ ") is not supported by this post-fec"

fmrErrorMessage :: FMRError -> String
fmrErrorMessage fmrError =
  case fmrError of
    InvalidFMRDimension dimension ->
      "invalid FMR dimension " ++ show dimension
    InvalidFMRShape fieldId shape ->
      "field " ++ show fieldId ++ " has invalid FMR shape " ++ show shape
    InvalidFMRBasis fieldId basis ->
      "field " ++ show fieldId ++ " has invalid storage basis " ++ show basis
    InvalidFMRLayout fieldId layout shape ->
      "field " ++ show fieldId ++ " layout " ++ show layout
      ++ " is invalid for shape " ++ show shape
    InvalidDeclaredVarianceCount fieldId expected actual ->
      "field " ++ show fieldId ++ " expected " ++ show expected
      ++ " declared variances, got " ++ show actual
    InvalidExactDenominator denominator ->
      "invalid exact denominator " ++ show denominator
    EmptyFMRExpression constructorName ->
      "empty FMR " ++ constructorName ++ " expression"

locationErrorMessage :: LocationError -> String
locationErrorMessage locationError =
  case locationError of
    InvalidLocationDimension dimension ->
      "invalid placement dimension " ++ show dimension
    InvalidBasisAxis axis dimension ->
      "basis axis " ++ show axis ++ " is outside dimension " ++ show dimension
    InvalidDerivativeAxis axisId dimension ->
      "derivative axis " ++ show axisId
      ++ " is outside placement dimension " ++ show dimension
    ZeroDerivativeMultiplicity axisId ->
      "derivative multiplicity for " ++ show axisId ++ " is zero"
    PlacementDimensionMismatch expected actual ->
      "placement dimension mismatch: " ++ show expected
      ++ " versus " ++ show actual
    UnknownLocationField fieldId ->
      "placement analysis refers to unknown field " ++ show fieldId
    FieldJetBasisMismatch fieldId basis ->
      "field jet basis " ++ show basis ++ " does not fit field " ++ show fieldId
    LocatedPlacementMismatch expected actual ->
      "located placement mismatch: " ++ show expected
      ++ " versus " ++ show actual
    AmbiguousSampleableDemand ->
      "sampleable expression has no demanded placement"

profileErrorMessage :: ProfileError -> String
profileErrorMessage profileError =
  case profileError of
    InvalidProfileDerivativeOrder order ->
      "profile derivative order must be positive, got " ++ show order
    InvalidProfileFormalAccuracy accuracy ->
      "profile formal accuracy must be positive and even, got "
      ++ show accuracy
    InvalidProfileLatticeFamily lattice family ->
      "profile family " ++ show family ++ " is invalid for " ++ show lattice
    DuplicateProfileRule lattice order ->
      "duplicate profile rule for " ++ show lattice ++ " order "
      ++ maybe "default" show order
    NonCanonicalProfileRuleOrder ->
      "profile rules are not in canonical order"
    ZeroFieldJetDerivative axisId ->
      "field jet has zero derivative multiplicity for " ++ show axisId
    DuplicateFieldJetDerivativeAxis axisId ->
      "field jet repeats derivative axis " ++ show axisId
    NonCanonicalFieldJetDerivativeOrder ->
      "field jet derivative axes are not in canonical order"
    FieldJetDerivativeOrderTooLarge axisId order ->
      "field jet derivative order for " ++ show axisId
      ++ " is too large: " ++ show order
    ProfileStencilError stencilError ->
      "profile stencil error: " ++ stencilErrorMessage stencilError

stencilErrorMessage :: StencilError -> String
stencilErrorMessage = show
