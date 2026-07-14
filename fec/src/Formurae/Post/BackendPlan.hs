-- | Effect planning for FEIR opaque storage requests.
--
-- Pure operators have disappeared by the time this module runs.  In
-- particular, ordinary @d@, Hodge star, and constant-metric codifferential
-- are represented only by algebraic ScalarNF/FieldJet nodes.  This planner is
-- intentionally limited to operations whose boundary carries a discrete
-- storage effect.  FEIR v1's first fully specified operation is the
-- orthogonal-metric Laplace--Beltrami request.
module Formurae.Post.BackendPlan
  ( AuxiliaryLifetime(..)
  , AuxiliaryRole(..)
  , AuxiliaryComputation(..)
  , AuxiliaryFieldPlan(..)
  , LbRequestPlan(..)
  , MetricCodifferentialComponentPlan(..)
  , MetricCodifferentialRequestPlan(..)
  , BackendPlan(..)
  , BackendPlanError(..)
  , lbOperationId
  , metricCodifferentialOperationId
  , planBackendEffects
  , lookupOpaqueResult
  ) where

import Data.List (find, intercalate, nub, sort, sortOn)

import qualified Formurae.FEIR.PrimitiveBindings as Primitives
import qualified Formurae.FEIR.PrimitiveManifest as Manifest
import Formurae.FEIR.Syntax
import Formurae.Post.Location

data AuxiliaryLifetime
  = PersistentAuxiliary
  | StepAuxiliary
  deriving (Eq, Ord, Show)

data AuxiliaryRole
  = OrthogonalCoefficientRole AxisId
  | OrthogonalVolumeRole
  | OrthogonalHodgeCoefficientRole Basis
  | LbFluxRole RequestGroupId AxisId
  | LbResultRole RequestGroupId
  | MetricCodifferentialFluxRole RequestGroupId Basis AxisId
  | MetricCodifferentialResultRole RequestGroupId Basis
  deriving (Eq, Ord, Show)

-- | A backend-neutral description of how an auxiliary is populated.  The
-- final FMR lowering may choose concrete syntax, but it may not reorder the
-- flux/result dependency encoded here.
data AuxiliaryComputation
  = SampleGeometry ScalarNF
  | ComputeLbFlux
      { auxiliaryLbSource :: FieldJet
      , auxiliaryLbAxis :: AxisId
      , auxiliaryLbCoefficientName :: String
      }
  | ComputeLbResult
      { auxiliaryLbFluxNames :: [(AxisId, String)]
      , auxiliaryLbVolumeName :: String
      }
  | ComputeMetricCodifferentialFlux
      { auxiliaryMetricCodifferentialOperand :: ScalarNF
      , auxiliaryMetricCodifferentialAxis :: AxisId
      , auxiliaryMetricCodifferentialSourcePlacement :: Placement
      , auxiliaryMetricCodifferentialPolicy :: GridPolicy
      , auxiliaryMetricCodifferentialCoefficientName :: String
      , auxiliaryMetricCodifferentialTermSign :: Integer
      }
  | ComputeMetricCodifferentialResult
      { auxiliaryMetricCodifferentialFluxNames :: [String]
      , auxiliaryMetricCodifferentialOuterCoefficientName :: String
      , auxiliaryMetricCodifferentialResultSign :: Integer
      }
  deriving (Eq, Ord, Show)

data AuxiliaryFieldPlan = AuxiliaryFieldPlan
  { auxiliaryFieldName :: String
  , auxiliaryFieldLifetime :: AuxiliaryLifetime
  , auxiliaryFieldRole :: AuxiliaryRole
  , auxiliaryFieldPlacement :: Placement
  , auxiliaryFieldComputation :: AuxiliaryComputation
  } deriving (Eq, Ord, Show)

data LbRequestPlan = LbRequestPlan
  { lbRequestSemanticKey :: SemanticKey
  , lbRequestGroup :: RequestGroupId
  , lbRequestOrigin :: OriginId
  , lbRequestSource :: FieldJet
  , lbRequestFluxFields :: [AuxiliaryFieldPlan]
  , lbRequestResultField :: AuxiliaryFieldPlan
  } deriving (Eq, Ord, Show)

data MetricCodifferentialComponentPlan = MetricCodifferentialComponentPlan
  { metricCodifferentialComponentSemanticKey :: SemanticKey
  , metricCodifferentialComponentBasis :: Basis
  , metricCodifferentialComponentFluxFields :: [AuxiliaryFieldPlan]
  , metricCodifferentialComponentResultField :: AuxiliaryFieldPlan
  } deriving (Eq, Ord, Show)

data MetricCodifferentialRequestPlan = MetricCodifferentialRequestPlan
  { metricCodifferentialRequestGroup :: RequestGroupId
  , metricCodifferentialRequestOrigin :: OriginId
  , metricCodifferentialRequestPolicy :: GridPolicy
  , metricCodifferentialCoefficientFields :: [AuxiliaryFieldPlan]
  , metricCodifferentialComponents :: [MetricCodifferentialComponentPlan]
  } deriving (Eq, Ord, Show)

data BackendPlan = BackendPlan
  { backendGeometryInitializers :: [AuxiliaryFieldPlan]
  , backendLbRequests :: [LbRequestPlan]
  , backendMetricCodifferentialRequests :: [MetricCodifferentialRequestPlan]
  -- | Topological step order.  Every request's axis fluxes precede its
  -- result, and all planned effects precede user field updates.
  , backendStepSchedule :: [AuxiliaryFieldPlan]
  -- | Replacement table used by post-fec expression lowering.
  , backendOpaqueResults :: [(SemanticKey, String)]
  -- | Every source occurrence retained separately from semantic request
  -- deduplication.  Planning chooses one materialization bundle, while
  -- diagnostics can still account for all equivalent call sites.
  , backendOpaqueOrigins :: [(SemanticKey, [OriginId])]
  } deriving (Eq, Ord, Show)

data BackendPlanError
  = EffectfulRequestInInitializer VersionedOpId SemanticKey OriginId
  | ConflictingOpaqueSemanticKey SemanticKey
  | ConflictingOpaqueRequestGroup RequestGroupId
  | UnsupportedEffectfulOperation VersionedOpId SemanticKey OriginId
  | LbNeedsOrthogonalMetric GeometryId OriginId
  | LbUnverifiedOrthogonalMetric GeometryId OriginId
  | LbMissingScaleFactor AxisId OriginId
  | LbNonSampleableGeometry AxisId OriginId
  | LbInvalidResultBasis Basis OriginId
  | LbInvalidOperands OriginId
  | LbUnknownSourceField FieldId OriginId
  | LbSourceMustBeScalar FieldId OriginId
  | LbSourceMustBeCollocated FieldId GridPolicy OriginId
  | LbSourceMustUseCanonicalCoordinates FieldId OriginId
  | MissingOpaqueAttribute SemanticKey AttributeId OriginId
  | DuplicateOpaqueAttribute SemanticKey AttributeId OriginId
  | InvalidOpaqueAttribute SemanticKey AttributeId AttributeValue OriginId
  | OpaqueGeometryMismatch GeometryId GeometryId OriginId
  | BackendPlanningLocationError LocationError OriginId
  | MetricCodifferentialPlanError String OriginId
  | ExplicitPrimitivePlanError VersionedOpId SemanticKey String OriginId
  deriving (Eq, Ord, Show)

lbOperationId :: VersionedOpId
lbOperationId = Primitives.lbOrthogonalV1OpId

metricCodifferentialOperationId :: VersionedOpId
metricCodifferentialOperationId = Primitives.codiffMetricV1OpId

data RequestOccurrence = RequestOccurrence
  { occurrenceOpaque :: OpaqueDiscrete
  , occurrenceOrigin :: OriginId
  , occurrenceOrigins :: [OriginId]
  } deriving (Eq, Ord, Show)

data GeometryContextError
  = NoVariableMetric GeometryId
  | UnverifiedVariableMetric GeometryId
  deriving (Eq, Ord, Show)

-- | Build all storage effects represented by a validated FEIR program.
--
-- The function repeats operation-specific checks rather than trusting a
-- producer.  General FEIR validation establishes wire well-formedness;
-- these checks establish the stronger semantic contract needed to generate
-- a conservative Laplace--Beltrami stencil.
planBackendEffects :: FEProgram -> Either BackendPlanError BackendPlan
planBackendEffects program = do
  rejectInitializerEffects program
  uniqueOccurrences <- deduplicateSemanticKeys
    (concatMap collectActionOccurrences (feProgramStepActions program))
  rejectGroupConflicts uniqueOccurrences
  rejectUnsupportedMaterializingEffects uniqueOccurrences
  let lbOccurrences = filter
        ((== lbOperationId) . opaqueDiscreteOpId . occurrenceOpaque)
        uniqueOccurrences
      metricCodifferentialOccurrences = filter
        ((== metricCodifferentialOperationId) .
          opaqueDiscreteOpId . occurrenceOpaque)
        uniqueOccurrences
  requests <- mapM (uncurry (planLbRequest program geometryContext))
    (zip [1 ..] lbOccurrences)
  metricRequests <- planMetricCodifferentialRequests program geometryContext
    metricCodifferentialOccurrences
  lbGeometryInitializers <-
    case requests of
      [] -> Right []
      firstRequest : _ -> do
        let origin = lbRequestOrigin firstRequest
        geometryNF <- mapGeometryError origin geometryContext
        makeGeometryInitializers program origin geometryNF
  let metricGeometryInitializers = concatMap
        metricCodifferentialCoefficientFields metricRequests
      volumeForMetric = case metricRequests of
        [] -> []
        firstRequest : _ ->
          case geometryContext of
            Left _ -> []
            Right normalForm ->
              [metricVolumeInitializer program
                (metricCodifferentialRequestOrigin firstRequest) normalForm]
      geometryInitializers = deduplicateAuxiliaryFields
        (lbGeometryInitializers ++ volumeForMetric ++ metricGeometryInitializers)
      requestBundles =
        [ ([lbRequestSemanticKey request],
           lbRequestFluxFields request ++ [lbRequestResultField request])
        | request <- requests
        ]
        ++ [ (map metricCodifferentialComponentSemanticKey
                (metricCodifferentialComponents request),
              metricRequestSchedule request)
           | request <- metricRequests
           ]
      stepSchedule = scheduleRequestBundles requestBundles
        (concatMap actionOpaqueKeysPostorder (feProgramStepActions program))
      lbResults =
        [ (lbRequestSemanticKey request,
           auxiliaryFieldName (lbRequestResultField request))
        | request <- requests
        ]
      metricResults =
        [ (metricCodifferentialComponentSemanticKey component,
           auxiliaryFieldName
             (metricCodifferentialComponentResultField component))
        | request <- metricRequests
        , component <- metricCodifferentialComponents request
        ]
  pure BackendPlan
    { backendGeometryInitializers = geometryInitializers
    , backendLbRequests = requests
    , backendMetricCodifferentialRequests = metricRequests
    , backendStepSchedule = stepSchedule
    , backendOpaqueResults = lbResults ++ metricResults
    , backendOpaqueOrigins =
        [ (opaqueDiscreteSemanticKey (occurrenceOpaque occurrence),
           occurrenceOrigins occurrence)
        | occurrence <- uniqueOccurrences
        ]
    }
  where
    geometryContext = geometryNormalForm (feProgramGeometry program)

    metricRequestSchedule request = concatMap
      (\component -> metricCodifferentialComponentFluxFields component
        ++ [metricCodifferentialComponentResultField component])
      (metricCodifferentialComponents request)

-- | Resolve an opaque scalar node to the planned step-local result storage.
lookupOpaqueResult :: BackendPlan -> SemanticKey -> Maybe String
lookupOpaqueResult plan key = lookup key (backendOpaqueResults plan)

rejectUnsupportedMaterializingEffects
    :: [RequestOccurrence]
    -> Either BackendPlanError ()
rejectUnsupportedMaterializingEffects occurrences =
  case
    [ occurrence
    | occurrence <- occurrences
    , let opId = opaqueDiscreteOpId (occurrenceOpaque occurrence)
    , isMaterializingOperation opId
    , opId /= lbOperationId
    , opId /= metricCodifferentialOperationId
    ] of
    occurrence : _ ->
      let opaque = occurrenceOpaque occurrence
      in Left (UnsupportedEffectfulOperation
          (opaqueDiscreteOpId opaque)
          (opaqueDiscreteSemanticKey opaque)
          (occurrenceOrigin occurrence))
    [] -> Right ()

rejectInitializerEffects :: FEProgram -> Either BackendPlanError ()
rejectInitializerEffects program =
  case
    [ occurrence
    | initializer <- feProgramInitializers program
    , occurrence <- collectInitializerOccurrences initializer
    , isMaterializingOperation
        (opaqueDiscreteOpId (occurrenceOpaque occurrence))
    ] of
    occurrence : _ ->
      let opaque = occurrenceOpaque occurrence
      in Left (EffectfulRequestInInitializer
          (opaqueDiscreteOpId opaque)
          (opaqueDiscreteSemanticKey opaque)
          (occurrenceOrigin occurrence))
    [] -> Right ()

deduplicateSemanticKeys
    :: [RequestOccurrence]
    -> Either BackendPlanError [RequestOccurrence]
deduplicateSemanticKeys = go [] []
  where
    go _seen kept [] = Right (reverse kept)
    go seen kept (occurrence : rest) =
      let opaque = occurrenceOpaque occurrence
          key = opaqueDiscreteSemanticKey opaque
      in case lookup key seen of
          Nothing -> go ((key, opaque) : seen) (occurrence : kept) rest
          Just first
            | sameSemanticPayload first opaque ->
                go seen (mergeOrigins key occurrence kept) rest
            | otherwise -> Left (ConflictingOpaqueSemanticKey key)

    mergeOrigins key occurrence = map merge
      where
        merge keptOccurrence
          | opaqueDiscreteSemanticKey (occurrenceOpaque keptOccurrence) == key =
              keptOccurrence
                { occurrenceOrigins = nub
                    (occurrenceOrigins keptOccurrence
                      ++ occurrenceOrigins occurrence)
                }
          | otherwise = keptOccurrence

rejectGroupConflicts
    :: [RequestOccurrence]
    -> Either BackendPlanError ()
rejectGroupConflicts occurrences = mapM_ checkGroup groups
  where
    groups = unique (map
      (opaqueDiscreteRequestGroup . occurrenceOpaque) occurrences)
    checkGroup group =
      case
        [ occurrenceOpaque occurrence
        | occurrence <- occurrences
        , opaqueDiscreteRequestGroup (occurrenceOpaque occurrence) == group
        ] of
        [] -> Right ()
        first : rest
          | all (sameRequestGroupPayload first) rest -> Right ()
          | otherwise -> Left (ConflictingOpaqueRequestGroup group)

planLbRequest
    :: FEProgram
    -> Either GeometryContextError GeometryNF
    -> Int
    -> RequestOccurrence
    -> Either BackendPlanError LbRequestPlan
planLbRequest program geometryContext requestNumber occurrence = do
  let opaque = occurrenceOpaque occurrence
      origin = occurrenceOrigin occurrence
      key = opaqueDiscreteSemanticKey opaque
      group = opaqueDiscreteRequestGroup opaque
  if opaqueDiscreteOpId opaque /= lbOperationId
    then Left (UnsupportedEffectfulOperation
      (opaqueDiscreteOpId opaque) key origin)
    else Right ()
  validateManifestEffectRoles occurrence
    [ Manifest.CoefficientRole
    , Manifest.FluxRole
    , Manifest.ResultRole
    , Manifest.VolumeRole
    ]
  geometryNF <- mapGeometryError origin geometryContext
  validateGeometrySampleability program origin geometryNF
  if opaqueDiscreteResultBasis opaque == Basis []
    then Right ()
    else Left (LbInvalidResultBasis (opaqueDiscreteResultBasis opaque) origin)
  source <-
    case opaqueDiscreteOperands opaque of
      [ScalarValue (FieldJet jet)] -> Right jet
      _ -> Left (LbInvalidOperands origin)
  field <-
    case find ((== fieldJetFieldId source) . logicalFieldId)
         (feProgramFields program) of
      Just value -> Right value
      Nothing -> Left (LbUnknownSourceField (fieldJetFieldId source) origin)
  validateLbSource program origin field source
  validateLbAttributes program origin opaque
  coefficientNames <- mapM (coefficientNameForAxis origin geometryNF)
    (map axisDeclId (feProgramAxes program))
  fluxFields <- mapM
    (makeFluxField program requestNumber group source coefficientNames origin)
    (feProgramAxes program)
  resultPlacement <- mapLocation origin
    (componentPlacement (feProgramDimension program) CollocatedPolicy (Basis []))
  let resultName = internalPrefix ++ "Lb" ++ show requestNumber ++ "Result"
      resultField = AuxiliaryFieldPlan
        { auxiliaryFieldName = resultName
        , auxiliaryFieldLifetime = StepAuxiliary
        , auxiliaryFieldRole = LbResultRole group
        , auxiliaryFieldPlacement = resultPlacement
        , auxiliaryFieldComputation = ComputeLbResult
            { auxiliaryLbFluxNames =
                [ (axis, auxiliaryFieldName flux)
                | (axis, flux) <- zip
                    (map axisDeclId (feProgramAxes program)) fluxFields
                ]
            , auxiliaryLbVolumeName = internalPrefix ++ "MetricVolume"
            }
        }
  pure LbRequestPlan
    { lbRequestSemanticKey = key
    , lbRequestGroup = group
    , lbRequestOrigin = origin
    , lbRequestSource = source
    , lbRequestFluxFields = fluxFields
    , lbRequestResultField = resultField
    }

explicitPlanFailure
    :: RequestOccurrence -> String -> Either BackendPlanError value
explicitPlanFailure occurrence = explicitPlanFailureFor
  (occurrenceOrigin occurrence)
  (opaqueDiscreteOpId (occurrenceOpaque occurrence))
  (opaqueDiscreteSemanticKey (occurrenceOpaque occurrence))

explicitPlanFailureFor
    :: OriginId
    -> VersionedOpId
    -> SemanticKey
    -> String
    -> Either BackendPlanError value
explicitPlanFailureFor origin operation key message =
  Left (ExplicitPrimitivePlanError operation key message origin)

planMetricCodifferentialRequests
    :: FEProgram
    -> Either GeometryContextError GeometryNF
    -> [RequestOccurrence]
    -> Either BackendPlanError [MetricCodifferentialRequestPlan]
planMetricCodifferentialRequests program geometryContext occurrences =
  mapM (uncurry planGroup) (zip [1 ..] grouped)
  where
    groups = unique (map
      (opaqueDiscreteRequestGroup . occurrenceOpaque) occurrences)
    grouped =
      [ [occurrence | occurrence <- occurrences,
                       opaqueDiscreteRequestGroup (occurrenceOpaque occurrence)
                         == group]
      | group <- groups
      ]

    planGroup _ [] = Left (MetricCodifferentialPlanError
      "empty metric codifferential request group" (OriginId 0))
    planGroup requestNumber groupOccurrences@(firstOccurrence : _) = do
      let origin = occurrenceOrigin firstOccurrence
          firstOpaque = occurrenceOpaque firstOccurrence
          group = opaqueDiscreteRequestGroup firstOpaque
      validateManifestEffectRoles firstOccurrence
        [ Manifest.CoefficientRole
        , Manifest.FluxRole
        , Manifest.ResultRole
        , Manifest.VolumeRole
        ]
      geometry <- metricGeometry origin geometryContext
      (dimension, degree, geometryId, operand) <-
        parseMetricCodifferentialPayload program origin firstOpaque
      if geometryId == geometryDeclId (feProgramGeometry program)
        then Right ()
        else metricPlanFailure origin
          "metric attribute does not match the program geometry"
      mapM_ (validateSamePayload origin dimension degree geometryId operand)
        (map occurrenceOpaque groupOccurrences)
      let expectedBases = canonicalFormBases dimension (degree - 1)
          actualBases = sort (nub (map
            (opaqueDiscreteResultBasis . occurrenceOpaque) groupOccurrences))
      if actualBases == expectedBases
        then Right ()
        else metricPlanFailure origin
          ("result component set is incomplete: expected "
            ++ show expectedBases ++ ", got " ++ show actualBases)
      policy <- inferMetricOperandPolicy program origin operand
      planned <- mapM
        (planMetricComponent geometry requestNumber group origin
          dimension degree policy operand groupOccurrences)
        expectedBases
      let coefficients = deduplicateAuxiliaryFields
            (concatMap fst planned)
          components = map snd planned
      Right MetricCodifferentialRequestPlan
        { metricCodifferentialRequestGroup = group
        , metricCodifferentialRequestOrigin = origin
        , metricCodifferentialRequestPolicy = policy
        , metricCodifferentialCoefficientFields = coefficients
        , metricCodifferentialComponents = components
        }

    validateSamePayload origin dimension degree geometryId operand opaque = do
      (otherDimension, otherDegree, otherGeometry, otherOperand) <-
        parseMetricCodifferentialPayload program origin opaque
      if (otherDimension, otherDegree, otherGeometry, otherOperand)
          == (dimension, degree, geometryId, operand)
        then Right ()
        else metricPlanFailure origin
          "request-group components do not share one semantic operand"

metricGeometry
    :: OriginId
    -> Either GeometryContextError GeometryNF
    -> Either BackendPlanError GeometryNF
metricGeometry origin geometryContext =
  case geometryContext of
    Right normalForm -> Right normalForm
    Left (NoVariableMetric _) -> metricPlanFailure origin
      "variable-metric codifferential requires orthogonal geometry"
    Left (UnverifiedVariableMetric _) -> metricPlanFailure origin
      "variable-metric codifferential geometry is not verified orthogonal"

parseMetricCodifferentialPayload
    :: FEProgram
    -> OriginId
    -> OpaqueDiscrete
    -> Either BackendPlanError (Int, Int, GeometryId, TensorNF)
parseMetricCodifferentialPayload program origin opaque = do
  let allowed =
        [AttributeId "dimension", AttributeId "metric", AttributeId "source-degree"]
      identifiers = map attributeId (opaqueDiscreteAttributes opaque)
  case [identifier | identifier <- identifiers,
                     identifier `notElem` allowed] of
    unknown : _ -> metricPlanFailure origin
      ("unknown attribute " ++ show unknown)
    [] -> Right ()
  dimensionValue <- metricAttributeValue origin opaque (AttributeId "dimension")
  degreeValue <- metricAttributeValue origin opaque (AttributeId "source-degree")
  metricValue <- metricAttributeValue origin opaque (AttributeId "metric")
  dimension <- metricPositiveNatural origin "dimension" dimensionValue
  degree <- metricPositiveNatural origin "source-degree" degreeValue
  geometryId <- case metricValue of
    AttributeGeometry value -> Right value
    _ -> metricPlanFailure origin "metric attribute must be a GeometryId"
  operand <- case opaqueDiscreteOperands opaque of
    [TensorValue value] -> Right value
    _ -> metricPlanFailure origin
      "metric codifferential expects one differential-form tensor operand"
  if dimension == feProgramDimension program
      && degree >= 1 && degree <= dimension
    then Right ()
    else metricPlanFailure origin
      "dimension/source-degree does not match the program"
  if tensorNFShape operand == replicate degree dimension
      && tensorNFVariances operand == replicate degree VarianceDown
      && tensorNFDfOrder operand == degree
    then Right ()
    else metricPlanFailure origin
      "operand tensor metadata does not describe the declared source form"
  Right (dimension, degree, geometryId, operand)

metricAttributeValue
    :: OriginId -> OpaqueDiscrete -> AttributeId
    -> Either BackendPlanError AttributeValue
metricAttributeValue origin opaque identifier =
  case [attributeValue attribute
       | attribute <- opaqueDiscreteAttributes opaque
       , attributeId attribute == identifier] of
    [value] -> Right value
    [] -> metricPlanFailure origin ("missing attribute " ++ show identifier)
    _ -> metricPlanFailure origin ("duplicate attribute " ++ show identifier)

metricPositiveNatural
    :: OriginId -> String -> AttributeValue -> Either BackendPlanError Int
metricPositiveNatural origin label value =
  case value of
    AttributeNatural natural
      | integer > 0 && integer <= toInteger (maxBound :: Int) ->
          Right (fromInteger integer)
      where integer = toInteger natural
    _ -> metricPlanFailure origin (label ++ " must be a positive natural")

inferMetricOperandPolicy
    :: FEProgram -> OriginId -> TensorNF -> Either BackendPlanError GridPolicy
inferMetricOperandPolicy program origin operand = do
  fieldIds <- concatMapM
    (metricScalarFieldIds program . snd) (tensorNFComponents operand)
  fields <- mapM lookupSourceField (nub fieldIds)
  case nub (map logicalFieldPolicy fields) of
    [policy] -> Right policy
    [] -> metricPlanFailure origin
      "metric codifferential operand has no logical field placement"
    _ -> metricPlanFailure origin
      "metric codifferential operand mixes grid policies"
  where
    lookupSourceField fieldId =
      case find ((== fieldId) . logicalFieldId) (feProgramFields program) of
        Just field -> Right field
        Nothing -> metricPlanFailure origin
          ("metric codifferential refers to unknown field " ++ show fieldId)

metricScalarFieldIds
    :: FEProgram -> ScalarNF -> Either BackendPlanError [FieldId]
metricScalarFieldIds program scalar =
  case scalar of
    Exact _ _ -> Right []
    NamedConstant _ -> Right []
    Parameter _ -> Right []
    Coordinate _ -> Right []
    Add values -> concatMapM recurse values
    Mul values -> concatMapM recurse values
    Div lhs rhs -> concatMapM recurse [lhs, rhs]
    Pow lhs rhs -> concatMapM recurse [lhs, rhs]
    Intrinsic _ values -> concatMapM recurse values
    AnalyticCall _ values -> concatMapM recurse values
    Select predicate yes no -> do
      predicateIds <- metricPredicateFieldIds program predicate
      branchIds <- concatMapM recurse [yes, no]
      Right (predicateIds ++ branchIds)
    FieldJet jet -> Right [fieldJetFieldId jet]
    OpaqueDiscrete nested -> concatMapM valueIds
      (opaqueDiscreteOperands nested)
    Ref nodeId ->
      case [value | BindValue candidate value _ <- feProgramStepActions program,
                    candidate == nodeId] of
        [value] -> valueIds value
        _ -> Right []
  where
    recurse = metricScalarFieldIds program
    valueIds (ScalarValue value) = recurse value
    valueIds (TensorValue tensor) = concatMapM
      (recurse . snd) (tensorNFComponents tensor)

metricPredicateFieldIds
    :: FEProgram -> PredicateNF -> Either BackendPlanError [FieldId]
metricPredicateFieldIds program predicate =
  case predicate of
    BoolExact _ -> Right []
    Compare _ lhs rhs -> concatMapM (metricScalarFieldIds program) [lhs, rhs]
    Not body -> metricPredicateFieldIds program body
    And bodies -> concatMapM (metricPredicateFieldIds program) bodies
    Or bodies -> concatMapM (metricPredicateFieldIds program) bodies

planMetricComponent
    :: GeometryNF
    -> Int
    -> RequestGroupId
    -> OriginId
    -> Int
    -> Int
    -> GridPolicy
    -> TensorNF
    -> [RequestOccurrence]
    -> Basis
    -> Either BackendPlanError
         ([AuxiliaryFieldPlan], MetricCodifferentialComponentPlan)
planMetricComponent geometry requestNumber group origin dimension degree
    policy operand occurrences resultBasis@(Basis resultAxes) = do
  occurrence <- case
    [candidate | candidate <- occurrences,
                 opaqueDiscreteResultBasis (occurrenceOpaque candidate)
                   == resultBasis] of
    first : _ -> Right first
    [] -> metricPlanFailure origin
      ("missing result component " ++ show resultBasis)
  targetPlacement <- mapLocation origin
    (componentPlacement dimension policy resultBasis)
  let complement = complementFormBasis dimension resultAxes
      componentSuffix = basisName resultBasis
      resultPrefix = internalPrefix ++ "Codiff" ++ show requestNumber
        ++ "B" ++ componentSuffix
      conventionSign = powerMinusOne (dimension * (degree + 1) + 1)
      outerSign = permutationSign (complement ++ resultAxes)
  outerCoefficient <- makeHodgeCoefficient geometry origin
    (Basis complement) targetPlacement
  termPlans <- mapM
    (planTerm resultPrefix targetPlacement resultAxes complement) complement
  let termCoefficients = map firstOf3 termPlans
      fluxFields = map secondOf3 termPlans
      resultField = AuxiliaryFieldPlan
        { auxiliaryFieldName = resultPrefix ++ "Result"
        , auxiliaryFieldLifetime = StepAuxiliary
        , auxiliaryFieldRole = MetricCodifferentialResultRole group resultBasis
        , auxiliaryFieldPlacement = targetPlacement
        , auxiliaryFieldComputation = ComputeMetricCodifferentialResult
            { auxiliaryMetricCodifferentialFluxNames =
                map auxiliaryFieldName fluxFields
            , auxiliaryMetricCodifferentialOuterCoefficientName =
                auxiliaryFieldName outerCoefficient
            , auxiliaryMetricCodifferentialResultSign =
                conventionSign * outerSign
            }
        }
  Right
    (outerCoefficient : termCoefficients,
     MetricCodifferentialComponentPlan
       { metricCodifferentialComponentSemanticKey =
           opaqueDiscreteSemanticKey (occurrenceOpaque occurrence)
       , metricCodifferentialComponentBasis = resultBasis
       , metricCodifferentialComponentFluxFields = fluxFields
       , metricCodifferentialComponentResultField = resultField
       })
  where
    planTerm resultPrefix targetPlacement componentResultAxes complement axis = do
      let sourceBasisAxes = sort (axis : componentResultAxes)
          derivativeSourceBasis = filter (/= axis) complement
          termSign = permutationSign (axis : derivativeSourceBasis)
            * permutationSign (sourceBasisAxes ++ derivativeSourceBasis)
          sourceBasis = Basis sourceBasisAxes
          axisId = AxisId axis
      sourceScalar <- case lookup sourceBasis (tensorNFComponents operand) of
        Just value -> Right value
        Nothing -> metricPlanFailure origin
          ("missing source component " ++ show sourceBasis)
      sourcePlacement <- mapLocation origin
        (componentPlacement dimension policy sourceBasis)
      coefficient <- makeHodgeCoefficient geometry origin
        sourceBasis sourcePlacement
      let fluxField = AuxiliaryFieldPlan
            { auxiliaryFieldName = resultPrefix ++ "Flux" ++ show axis
            , auxiliaryFieldLifetime = StepAuxiliary
            , auxiliaryFieldRole = MetricCodifferentialFluxRole
                group resultBasis axisId
            , auxiliaryFieldPlacement = targetPlacement
            , auxiliaryFieldComputation = ComputeMetricCodifferentialFlux
                { auxiliaryMetricCodifferentialOperand = sourceScalar
                , auxiliaryMetricCodifferentialAxis = axisId
                , auxiliaryMetricCodifferentialSourcePlacement = sourcePlacement
                , auxiliaryMetricCodifferentialPolicy = policy
                , auxiliaryMetricCodifferentialCoefficientName =
                    auxiliaryFieldName coefficient
                , auxiliaryMetricCodifferentialTermSign = termSign
                }
            }
      Right (coefficient, fluxField, ())

    firstOf3 (value, _, _) = value
    secondOf3 (_, value, _) = value

makeHodgeCoefficient
    :: GeometryNF
    -> OriginId
    -> Basis
    -> Placement
    -> Either BackendPlanError AuxiliaryFieldPlan
makeHodgeCoefficient geometry origin basis@(Basis axes) placement = do
  scales <- mapM scaleFor axes
  let denominator = case scales of
        [] -> Exact 1 1
        [scale] -> Pow scale (Exact 2 1)
        _ -> Mul [Pow scale (Exact 2 1) | scale <- scales]
  Right AuxiliaryFieldPlan
    { auxiliaryFieldName = hodgeCoefficientName basis placement
    , auxiliaryFieldLifetime = PersistentAuxiliary
    , auxiliaryFieldRole = OrthogonalHodgeCoefficientRole basis
    , auxiliaryFieldPlacement = placement
    , auxiliaryFieldComputation = SampleGeometry
        (Div (geometryVolumeElement geometry) denominator)
    }
  where
    scaleFor axis =
      case lookup (AxisId axis) (geometryScaleFactors geometry) of
        Just value -> Right value
        Nothing -> metricPlanFailure origin
          ("geometry has no scale factor for axis " ++ show axis)

metricVolumeInitializer :: FEProgram -> OriginId -> GeometryNF -> AuxiliaryFieldPlan
metricVolumeInitializer program _origin geometry = AuxiliaryFieldPlan
  { auxiliaryFieldName = internalPrefix ++ "MetricVolume"
  , auxiliaryFieldLifetime = PersistentAuxiliary
  , auxiliaryFieldRole = OrthogonalVolumeRole
  , auxiliaryFieldPlacement = placement
  , auxiliaryFieldComputation = SampleGeometry
      (geometryVolumeElement geometry)
  }
  where
    placement = either
      (error . ("metricVolumeInitializer: " ++) . show) id
      (componentPlacement (feProgramDimension program) CollocatedPolicy (Basis []))

hodgeCoefficientName :: Basis -> Placement -> String
hodgeCoefficientName basis (Placement bits) =
  internalPrefix ++ "HodgeCoefficientB" ++ basisName basis
  ++ "P" ++ map bitName bits
  where
    bitName IntegerPoint = 'I'
    bitName HalfPoint = 'H'

basisName :: Basis -> String
basisName (Basis []) = "Scalar"
basisName (Basis axes) = intercalate "_" (map show axes)

canonicalFormBases :: Int -> Int -> [Basis]
canonicalFormBases dimension degree = map Basis (choose degree [1 .. dimension])
  where
    choose 0 _ = [[]]
    choose _ [] = []
    choose count (value : rest) =
      map (value :) (choose (count - 1) rest) ++ choose count rest

complementFormBasis :: Int -> [Int] -> [Int]
complementFormBasis dimension basis =
  [axis | axis <- [1 .. dimension], axis `notElem` basis]

permutationSign :: [Int] -> Integer
permutationSign values = powerMinusOne (length
  [ ()
  | (leftPosition, left) <- zip [0 :: Int ..] values
  , (rightPosition, right) <- zip [0 :: Int ..] values
  , leftPosition < rightPosition
  , left > right
  ])

powerMinusOne :: Int -> Integer
powerMinusOne power
  | even power = 1
  | otherwise = -1

deduplicateAuxiliaryFields :: [AuxiliaryFieldPlan] -> [AuxiliaryFieldPlan]
deduplicateAuxiliaryFields = foldl add []
  where
    add accumulated field =
      case find ((== auxiliaryFieldName field) . auxiliaryFieldName) accumulated of
        Nothing -> accumulated ++ [field]
        Just existing
          | existing == field -> accumulated
          | otherwise -> error
              ("conflicting deterministic auxiliary name "
                ++ auxiliaryFieldName field)

metricPlanFailure :: OriginId -> String -> Either BackendPlanError value
metricPlanFailure origin message =
  Left (MetricCodifferentialPlanError message origin)

validateLbSource
    :: FEProgram
    -> OriginId
    -> LogicalFieldDecl
    -> FieldJet
    -> Either BackendPlanError ()
validateLbSource program origin field source = do
  if logicalFieldTensorType field == TensorType [] [] 0
      && logicalFieldLayout field == ScalarLayout
      && fieldJetBasis source == Basis []
      && null (fieldJetMultiIndex source)
    then Right ()
    else Left (LbSourceMustBeScalar (logicalFieldId field) origin)
  if logicalFieldPolicy field == CollocatedPolicy
    then Right ()
    else Left (LbSourceMustBeCollocated (logicalFieldId field)
      (logicalFieldPolicy field) origin)
  let canonicalCoordinates = map
        (Coordinate . axisDeclId) (feProgramAxes program)
  if fieldJetArguments source == canonicalCoordinates
    then Right ()
    else Left (LbSourceMustUseCanonicalCoordinates
      (logicalFieldId field) origin)

validateLbAttributes
    :: FEProgram
    -> OriginId
    -> OpaqueDiscrete
    -> Either BackendPlanError ()
validateLbAttributes program origin opaque = do
  geometryValue <- requireAttribute origin opaque metricAttribute
  case geometryValue of
    AttributeGeometry actual
      | actual == expectedGeometry -> Right ()
      | otherwise -> Left
          (OpaqueGeometryMismatch expectedGeometry actual origin)
    value -> Left (InvalidOpaqueAttribute key metricAttribute value origin)
  policyValue <- requireAttribute origin opaque sourcePolicyAttribute
  case policyValue of
    AttributeGridPolicy CollocatedPolicy -> Right ()
    value -> Left
      (InvalidOpaqueAttribute key sourcePolicyAttribute value origin)
  where
    key = opaqueDiscreteSemanticKey opaque
    expectedGeometry = geometryDeclId (feProgramGeometry program)

requireAttribute
    :: OriginId
    -> OpaqueDiscrete
    -> AttributeId
    -> Either BackendPlanError AttributeValue
requireAttribute origin opaque requested =
  case
    [ attributeValue attribute
    | attribute <- opaqueDiscreteAttributes opaque
    , attributeId attribute == requested
    ] of
    [value] -> Right value
    [] -> Left (MissingOpaqueAttribute
      (opaqueDiscreteSemanticKey opaque) requested origin)
    _ -> Left (DuplicateOpaqueAttribute
      (opaqueDiscreteSemanticKey opaque) requested origin)

makeGeometryInitializers
    :: FEProgram
    -> OriginId
    -> GeometryNF
    -> Either BackendPlanError [AuxiliaryFieldPlan]
makeGeometryInitializers program origin geometryNF = do
  coefficientFields <- mapM makeCoefficient (feProgramAxes program)
  volumePlacement <- mapLocation origin
    (componentPlacement dimension CollocatedPolicy (Basis []))
  let volumeField = AuxiliaryFieldPlan
        { auxiliaryFieldName = internalPrefix ++ "MetricVolume"
        , auxiliaryFieldLifetime = PersistentAuxiliary
        , auxiliaryFieldRole = OrthogonalVolumeRole
        , auxiliaryFieldPlacement = volumePlacement
        , auxiliaryFieldComputation = SampleGeometry
            (geometryVolumeElement geometryNF)
        }
  pure (coefficientFields ++ [volumeField])
  where
    dimension = feProgramDimension program
    makeCoefficient axis = do
      let axisId@(AxisId axisNumber) = axisDeclId axis
      scale <-
        case lookup axisId (geometryScaleFactors geometryNF) of
          Just value -> Right value
          Nothing -> Left (LbMissingScaleFactor axisId origin)
      placement <- mapLocation origin
        (componentPlacement dimension PrimalPolicy (Basis [axisNumber]))
      pure AuxiliaryFieldPlan
        { auxiliaryFieldName = coefficientName axisId
        , auxiliaryFieldLifetime = PersistentAuxiliary
        , auxiliaryFieldRole = OrthogonalCoefficientRole axisId
        , auxiliaryFieldPlacement = placement
        , auxiliaryFieldComputation = SampleGeometry
            (Div (geometryVolumeElement geometryNF)
              (Pow scale (Exact 2 1)))
        }

makeFluxField
    :: FEProgram
    -> Int
    -> RequestGroupId
    -> FieldJet
    -> [(AxisId, String)]
    -> OriginId
    -> AxisDecl
    -> Either BackendPlanError AuxiliaryFieldPlan
makeFluxField program requestNumber group source coefficients origin axis = do
  let axisId@(AxisId axisNumber) = axisDeclId axis
  coefficient <-
    case lookup axisId coefficients of
      Just value -> Right value
      Nothing -> Left (LbMissingScaleFactor axisId origin)
  placement <- mapLocation origin
    (componentPlacement (feProgramDimension program)
      PrimalPolicy (Basis [axisNumber]))
  pure AuxiliaryFieldPlan
    { auxiliaryFieldName = internalPrefix ++ "Lb" ++ show requestNumber
        ++ "Flux" ++ show axisNumber
    , auxiliaryFieldLifetime = StepAuxiliary
    , auxiliaryFieldRole = LbFluxRole group axisId
    , auxiliaryFieldPlacement = placement
    , auxiliaryFieldComputation = ComputeLbFlux
        { auxiliaryLbSource = source
        , auxiliaryLbAxis = axisId
        , auxiliaryLbCoefficientName = coefficient
        }
    }

coefficientNameForAxis
    :: OriginId -> GeometryNF -> AxisId
    -> Either BackendPlanError (AxisId, String)
coefficientNameForAxis origin geometryNF axisId =
  case lookup axisId (geometryScaleFactors geometryNF) of
    Just _ -> Right (axisId, coefficientName axisId)
    Nothing -> Left (LbMissingScaleFactor axisId origin)

coefficientName :: AxisId -> String
coefficientName (AxisId axis) =
  internalPrefix ++ "MetricCoefficient" ++ show axis

geometryNormalForm
    :: GeometryDecl -> Either GeometryContextError GeometryNF
geometryNormalForm geometry =
  case geometryDeclKind geometry of
    EuclideanGeometry -> Left (NoVariableMetric (geometryDeclId geometry))
    OrthogonalScaleGeometry _ normalForm -> checked normalForm
    EmbeddedOrthogonalGeometry _ normalForm -> checked normalForm
  where
    checked normalForm
      | geometryOrthogonalityVerified normalForm = Right normalForm
      | otherwise = Left (UnverifiedVariableMetric (geometryDeclId geometry))

mapGeometryError
    :: OriginId
    -> Either GeometryContextError GeometryNF
    -> Either BackendPlanError GeometryNF
mapGeometryError requestOrigin geometryContext =
  case geometryContext of
    Right value -> Right value
    Left (NoVariableMetric geometryId) ->
      Left (LbNeedsOrthogonalMetric geometryId requestOrigin)
    Left (UnverifiedVariableMetric geometryId) ->
      Left (LbUnverifiedOrthogonalMetric geometryId requestOrigin)

validateGeometrySampleability
    :: FEProgram -> OriginId -> GeometryNF -> Either BackendPlanError ()
validateGeometrySampleability program origin geometryNF =
  mapM_ validateAxis (map axisDeclId (feProgramAxes program))
  where
    validateAxis axisId =
      case lookup axisId (geometryScaleFactors geometryNF) of
        Nothing -> Left (LbMissingScaleFactor axisId origin)
        Just scale
          | sampleableScalar scale
              && sampleableScalar (geometryVolumeElement geometryNF) -> Right ()
          | otherwise -> Left (LbNonSampleableGeometry axisId origin)

sampleableScalar :: ScalarNF -> Bool
sampleableScalar scalar =
  case scalar of
    Exact _ _ -> True
    NamedConstant _ -> True
    Parameter _ -> True
    Coordinate _ -> True
    Add terms -> all sampleableScalar terms
    Mul factors -> all sampleableScalar factors
    Div numerator denominator ->
      sampleableScalar numerator && sampleableScalar denominator
    Pow base exponentValue ->
      sampleableScalar base && sampleableScalar exponentValue
    Intrinsic _ arguments -> all sampleableScalar arguments
    AnalyticCall _ arguments -> all sampleableScalar arguments
    Select predicate yes no ->
      sampleablePredicate predicate
      && sampleableScalar yes
      && sampleableScalar no
    FieldJet _ -> False
    OpaqueDiscrete _ -> False
    Ref _ -> False

sampleablePredicate :: PredicateNF -> Bool
sampleablePredicate predicate =
  case predicate of
    BoolExact _ -> True
    Compare _ lhs rhs -> sampleableScalar lhs && sampleableScalar rhs
    Not body -> sampleablePredicate body
    And bodies -> all sampleablePredicate bodies
    Or bodies -> all sampleablePredicate bodies

collectInitializerOccurrences :: FEInitializer -> [RequestOccurrence]
collectInitializerOccurrences initializer =
  case initializer of
    AnalyticInitializer equation -> collectTensorOccurrences
      (feEquationOrigin equation) (feEquationRhs equation)
    RawInitializer _ _ _ -> []

collectActionOccurrences :: FEAction -> [RequestOccurrence]
collectActionOccurrences action =
  case action of
    BindValue _ value origin -> collectValueOccurrences origin value
    Materialize _ value origin -> collectValueOccurrences origin value
    UpdateField equation -> collectTensorOccurrences
      (feEquationOrigin equation) (feEquationRhs equation)

collectValueOccurrences :: OriginId -> FEValue -> [RequestOccurrence]
collectValueOccurrences origin value =
  case value of
    ScalarValue scalar -> collectScalarOccurrences origin scalar
    TensorValue tensor -> collectTensorOccurrences origin tensor

collectTensorOccurrences :: OriginId -> TensorNF -> [RequestOccurrence]
collectTensorOccurrences origin tensor = concatMap
  (collectScalarOccurrences origin . snd) (tensorNFComponents tensor)

collectScalarOccurrences :: OriginId -> ScalarNF -> [RequestOccurrence]
collectScalarOccurrences origin scalar =
  case scalar of
    Exact _ _ -> []
    NamedConstant _ -> []
    Parameter _ -> []
    Coordinate _ -> []
    Add terms -> concatMap recurse terms
    Mul factors -> concatMap recurse factors
    Div numerator denominator -> recurse numerator ++ recurse denominator
    Pow base exponentValue -> recurse base ++ recurse exponentValue
    Intrinsic _ arguments -> concatMap recurse arguments
    AnalyticCall _ arguments -> concatMap recurse arguments
    Select predicate yes no ->
      collectPredicateOccurrences origin predicate ++ recurse yes ++ recurse no
    FieldJet _ -> []
    OpaqueDiscrete opaque ->
      RequestOccurrence opaque origin [origin]
      : concatMap (collectValueOccurrences origin)
          (opaqueDiscreteOperands opaque)
    Ref _ -> []
  where
    recurse = collectScalarOccurrences origin

collectPredicateOccurrences :: OriginId -> PredicateNF -> [RequestOccurrence]
collectPredicateOccurrences origin predicate =
  case predicate of
    BoolExact _ -> []
    Compare _ lhs rhs -> recurse lhs ++ recurse rhs
    Not body -> collectPredicateOccurrences origin body
    And bodies -> concatMap (collectPredicateOccurrences origin) bodies
    Or bodies -> concatMap (collectPredicateOccurrences origin) bodies
  where
    recurse = collectScalarOccurrences origin

scheduleRequestBundles
    :: [([SemanticKey], [AuxiliaryFieldPlan])]
    -> [SemanticKey]
    -> [AuxiliaryFieldPlan]
scheduleRequestBundles bundles keys = third (foldl schedule ([], [], []) keys)
  where
    schedule state@(scheduled, _, _) key
      | key `elem` scheduled = state
    schedule (scheduled, groups, auxiliaries) key =
      case find (elem key . fst) bundles of
        Nothing -> (scheduled, groups, auxiliaries)
        Just (requestKeys, requestAuxiliaries) ->
          let groupName = map auxiliaryFieldName requestAuxiliaries
          in if groupName `elem` groups
               then (unique (scheduled ++ requestKeys), groups, auxiliaries)
               else ( unique (scheduled ++ requestKeys)
                    , groups ++ [groupName]
                    , auxiliaries ++ requestAuxiliaries
                    )
    third (_, _, value) = value

actionOpaqueKeysPostorder :: FEAction -> [SemanticKey]
actionOpaqueKeysPostorder action = unique $ case action of
  BindValue _ value _ -> valueOpaqueKeysPostorder value
  Materialize _ value _ -> valueOpaqueKeysPostorder value
  UpdateField equation -> tensorOpaqueKeysPostorder (feEquationRhs equation)

valueOpaqueKeysPostorder :: FEValue -> [SemanticKey]
valueOpaqueKeysPostorder value = case value of
  ScalarValue scalar -> scalarOpaqueKeysPostorder scalar
  TensorValue tensor -> tensorOpaqueKeysPostorder tensor

tensorOpaqueKeysPostorder :: TensorNF -> [SemanticKey]
tensorOpaqueKeysPostorder tensor = concatMap
  (scalarOpaqueKeysPostorder . snd) (tensorNFComponents tensor)

scalarOpaqueKeysPostorder :: ScalarNF -> [SemanticKey]
scalarOpaqueKeysPostorder scalar =
  case scalar of
    Exact _ _ -> []
    NamedConstant _ -> []
    Parameter _ -> []
    Coordinate _ -> []
    Add values -> concatMap recurse values
    Mul values -> concatMap recurse values
    Div lhs rhs -> recurse lhs ++ recurse rhs
    Pow lhs rhs -> recurse lhs ++ recurse rhs
    Intrinsic _ values -> concatMap recurse values
    AnalyticCall _ values -> concatMap recurse values
    Select predicate yes no ->
      predicateOpaqueKeysPostorder predicate ++ recurse yes ++ recurse no
    FieldJet _ -> []
    OpaqueDiscrete opaque ->
      concatMap valueOpaqueKeysPostorder (opaqueDiscreteOperands opaque)
      ++ [opaqueDiscreteSemanticKey opaque]
    Ref _ -> []
  where
    recurse = scalarOpaqueKeysPostorder

predicateOpaqueKeysPostorder :: PredicateNF -> [SemanticKey]
predicateOpaqueKeysPostorder predicate = case predicate of
  BoolExact _ -> []
  Compare _ lhs rhs -> recurse lhs ++ recurse rhs
  Not body -> predicateOpaqueKeysPostorder body
  And values -> concatMap predicateOpaqueKeysPostorder values
  Or values -> concatMap predicateOpaqueKeysPostorder values
  where
    recurse = scalarOpaqueKeysPostorder

sameSemanticPayload :: OpaqueDiscrete -> OpaqueDiscrete -> Bool
sameSemanticPayload lhs rhs =
  opaqueDiscreteOpId lhs == opaqueDiscreteOpId rhs
  && opaqueDiscreteResultBasis lhs == opaqueDiscreteResultBasis rhs
  && opaqueDiscreteOperands lhs == opaqueDiscreteOperands rhs
  && sortedAttributes lhs == sortedAttributes rhs

sameRequestGroupPayload :: OpaqueDiscrete -> OpaqueDiscrete -> Bool
sameRequestGroupPayload lhs rhs =
  opaqueDiscreteOpId lhs == opaqueDiscreteOpId rhs
  && opaqueDiscreteOperands lhs == opaqueDiscreteOperands rhs
  && sortedAttributes lhs == sortedAttributes rhs

sortedAttributes :: OpaqueDiscrete -> [Attribute]
sortedAttributes = sortOn attributeId . opaqueDiscreteAttributes

isMaterializingOperation :: VersionedOpId -> Bool
isMaterializingOperation opId =
  case Primitives.lookupPrimitiveSignatureV1 opId of
    Just signature ->
      case Manifest.primitiveSignatureEffect signature of
        Manifest.NeedsMaterialization _ -> True
        Manifest.PureLocal -> False
    Nothing -> False

validateManifestEffectRoles
    :: RequestOccurrence
    -> [Manifest.AuxiliaryRole]
    -> Either BackendPlanError ()
validateManifestEffectRoles occurrence actualRoles =
  case Primitives.lookupPrimitiveSignatureV1 operation of
    Just signature ->
      case Manifest.primitiveSignatureEffect signature of
        Manifest.NeedsMaterialization expectedRoles
          | sort expectedRoles == sort actualRoles -> Right ()
          | otherwise -> mismatch ("manifest roles " ++ show expectedRoles
              ++ " do not match backend roles " ++ show actualRoles)
        Manifest.PureLocal -> mismatch
          "backend materializes an operation declared pure-local"
    Nothing -> mismatch "operation is absent from the generated manifest"
  where
    opaque = occurrenceOpaque occurrence
    operation = opaqueDiscreteOpId opaque
    mismatch message = explicitPlanFailure occurrence
      ("primitive effect contract mismatch: " ++ message)

metricAttribute :: AttributeId
metricAttribute = AttributeId "metric"

sourcePolicyAttribute :: AttributeId
sourcePolicyAttribute = AttributeId "source-policy"

internalPrefix :: String
internalPrefix = "FormuraeInternal"

unique :: Eq a => [a] -> [a]
unique = foldl add []
  where
    add values value
      | value `elem` values = values
      | otherwise = values ++ [value]

concatMapM :: (a -> Either e [b]) -> [a] -> Either e [b]
concatMapM function values = concat <$> mapM function values

mapLocation
    :: OriginId
    -> Either LocationError a
    -> Either BackendPlanError a
mapLocation origin = either
  (Left . flip BackendPlanningLocationError origin) Right
