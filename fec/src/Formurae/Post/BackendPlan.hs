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
  , ConservativeDivergenceRequestPlan(..)
  , MaterializedComponentPlan(..)
  , MaterializedRequestPlan(..)
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
import Formurae.Post.ExplicitStencil
import Formurae.Post.Location
import Formurae.Post.PrimitiveContract

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
  | ConservativeFluxRole RequestGroupId AxisId
  | ConservativeResultRole RequestGroupId
  | MaterializedIntermediateRole RequestGroupId Basis
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
  | ComputeConservativeFlux ScalarNF
  | ComputeConservativeResult [(AxisId, String)]
  | ComputeMaterialized ScalarNF
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

data ConservativeDivergenceRequestPlan = ConservativeDivergenceRequestPlan
  { conservativeDivergenceSemanticKey :: SemanticKey
  , conservativeDivergenceGroup :: RequestGroupId
  , conservativeDivergenceOrigin :: OriginId
  , conservativeDivergenceFluxFields :: [AuxiliaryFieldPlan]
  , conservativeDivergenceResultField :: AuxiliaryFieldPlan
  } deriving (Eq, Ord, Show)

data MaterializedComponentPlan = MaterializedComponentPlan
  { materializedComponentBasis :: Basis
  , materializedComponentSemanticKeys :: [SemanticKey]
  , materializedComponentField :: AuxiliaryFieldPlan
  } deriving (Eq, Ord, Show)

data MaterializedRequestPlan = MaterializedRequestPlan
  { materializedRequestGroup :: RequestGroupId
  , materializedRequestOrigin :: OriginId
  , materializedRequestComponents :: [MaterializedComponentPlan]
  } deriving (Eq, Ord, Show)

data BackendPlan = BackendPlan
  { backendGeometryInitializers :: [AuxiliaryFieldPlan]
  , backendLbRequests :: [LbRequestPlan]
  , backendMetricCodifferentialRequests :: [MetricCodifferentialRequestPlan]
  , backendConservativeDivergenceRequests :: [ConservativeDivergenceRequestPlan]
  , backendMaterializedRequests :: [MaterializedRequestPlan]
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
  | LbSourceMustBeCurrent FieldId TimeSlot OriginId
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
      conservativeOccurrences = filter
        ((== Primitives.fluxConservativeDivergenceV1OpId) .
          opaqueDiscreteOpId . occurrenceOpaque)
        uniqueOccurrences
      materializedOccurrences = filter
        ((== Primitives.operatorMaterializedV1OpId) .
          opaqueDiscreteOpId . occurrenceOpaque)
        uniqueOccurrences
  requests <- mapM (uncurry (planLbRequest program geometryContext))
    (zip [1 ..] lbOccurrences)
  metricRequests <- planMetricCodifferentialRequests program geometryContext
    metricCodifferentialOccurrences
  conservativeRequests <- mapM
    (uncurry (planConservativeDivergenceRequest program))
    (zip [1 ..] conservativeOccurrences)
  materializedRequests <- planMaterializedRequests program
    materializedOccurrences
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
        ++ [ ([conservativeDivergenceSemanticKey request],
              conservativeDivergenceFluxFields request
                ++ [conservativeDivergenceResultField request])
           | request <- conservativeRequests
           ]
        ++ [ (concatMap materializedComponentSemanticKeys components,
              map materializedComponentField components)
           | request <- materializedRequests
           , let components = materializedRequestComponents request
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
      conservativeResults =
        [ (conservativeDivergenceSemanticKey request,
           auxiliaryFieldName
             (conservativeDivergenceResultField request))
        | request <- conservativeRequests
        ]
      materializedResults =
        [ (key, auxiliaryFieldName (materializedComponentField component))
        | request <- materializedRequests
        , component <- materializedRequestComponents request
        , key <- materializedComponentSemanticKeys component
        ]
  pure BackendPlan
    { backendGeometryInitializers = geometryInitializers
    , backendLbRequests = requests
    , backendMetricCodifferentialRequests = metricRequests
    , backendConservativeDivergenceRequests = conservativeRequests
    , backendMaterializedRequests = materializedRequests
    , backendStepSchedule = stepSchedule
    , backendOpaqueResults = lbResults ++ metricResults
        ++ conservativeResults ++ materializedResults
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
    , opId /= Primitives.fluxConservativeDivergenceV1OpId
    , opId /= Primitives.operatorMaterializedV1OpId
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

planConservativeDivergenceRequest
    :: FEProgram
    -> Int
    -> RequestOccurrence
    -> Either BackendPlanError ConservativeDivergenceRequestPlan
planConservativeDivergenceRequest program requestNumber occurrence = do
  let opaque = occurrenceOpaque occurrence
      origin = occurrenceOrigin occurrence
      key = opaqueDiscreteSemanticKey opaque
      group = opaqueDiscreteRequestGroup opaque
  validateManifestEffectRoles occurrence
    [Manifest.FluxRole, Manifest.ResultRole]
  request <- mapPrimitivePlanError origin opaque
    (parseConservativeDivergenceRequest (feProgramDimension program) opaque)
  fluxFields <- mapM makeFlux
    (conservativeDivergenceComponents request)
  resultPlacement <- mapLocation origin
    (componentPlacement (feProgramDimension program)
      PrimalPolicy (Basis []))
  let resultField = AuxiliaryFieldPlan
        { auxiliaryFieldName = internalPrefix ++ "Conservative"
            ++ show requestNumber ++ "Result"
        , auxiliaryFieldLifetime = StepAuxiliary
        , auxiliaryFieldRole = ConservativeResultRole group
        , auxiliaryFieldPlacement = resultPlacement
        , auxiliaryFieldComputation = ComputeConservativeResult
            [ (axisId, auxiliaryFieldName field)
            | ((axisId, _), field) <- zip
                (conservativeDivergenceComponents request) fluxFields
            ]
        }
  Right ConservativeDivergenceRequestPlan
    { conservativeDivergenceSemanticKey = key
    , conservativeDivergenceGroup = group
    , conservativeDivergenceOrigin = origin
    , conservativeDivergenceFluxFields = fluxFields
    , conservativeDivergenceResultField = resultField
    }
  where
    makeFlux (axisId@(AxisId axis), scalar) = do
      expected <- mapLocation (occurrenceOrigin occurrence)
        (componentPlacement (feProgramDimension program)
          PrimalPolicy (Basis [axis]))
      location <- inferStoredScalarLocation program
        (occurrenceOrigin occurrence) scalar
      case storedLocationCapability location of
        LocatedCapability actual
          | actual == expected -> Right ()
          | otherwise -> explicitPlanFailure occurrence
              ("flux component " ++ show axisId ++ " is at " ++ show actual
                ++ ", expected Primal face " ++ show expected)
        capability -> explicitPlanFailure occurrence
          ("flux component " ++ show axisId
            ++ " must be Located, got " ++ show capability)
      Right AuxiliaryFieldPlan
        { auxiliaryFieldName = internalPrefix ++ "Conservative"
            ++ show requestNumber ++ "Flux" ++ show axis
        , auxiliaryFieldLifetime = StepAuxiliary
        , auxiliaryFieldRole = ConservativeFluxRole
            (opaqueDiscreteRequestGroup (occurrenceOpaque occurrence)) axisId
        , auxiliaryFieldPlacement = expected
        , auxiliaryFieldComputation = ComputeConservativeFlux scalar
        }

planMaterializedRequests
    :: FEProgram
    -> [RequestOccurrence]
    -> Either BackendPlanError [MaterializedRequestPlan]
planMaterializedRequests program occurrences =
  mapM (uncurry planGroup) (zip [1 :: Int ..] grouped)
  where
    groups = unique (map
      (opaqueDiscreteRequestGroup . occurrenceOpaque) occurrences)
    grouped =
      [ [ occurrence
        | occurrence <- occurrences
        , opaqueDiscreteRequestGroup (occurrenceOpaque occurrence) == group
        ]
      | group <- groups
      ]

    planGroup _ [] = Left (ExplicitPrimitivePlanError
      Primitives.operatorMaterializedV1OpId (SemanticKey "")
      "empty materialization request group" (OriginId 0))
    planGroup requestNumber
        groupOccurrences@(firstOccurrence : remainingOccurrences) = do
      validateManifestEffectRoles firstOccurrence [Manifest.IntermediateRole]
      firstRequest <- parseOccurrence firstOccurrence
      remainingRequests <- mapM parseOccurrence remainingOccurrences
      let parsed = firstRequest : remainingRequests
          sourceValue = materializedSourceValue firstRequest
          group = opaqueDiscreteRequestGroup
            (occurrenceOpaque firstOccurrence)
          origin = occurrenceOrigin firstOccurrence
      if all ((== sourceValue) . materializedSourceValue) parsed
        then Right ()
        else explicitPlanFailure firstOccurrence
          "materialization request-group operands differ"
      components <- mapM
        (planComponent requestNumber group origin firstOccurrence
          groupOccurrences)
        (valueComponents sourceValue)
      Right MaterializedRequestPlan
        { materializedRequestGroup = group
        , materializedRequestOrigin = origin
        , materializedRequestComponents = components
        }

    parseOccurrence occurrence = mapPrimitivePlanError
      (occurrenceOrigin occurrence) (occurrenceOpaque occurrence)
      (parseMaterializedComponentRequest (occurrenceOpaque occurrence))

    planComponent requestNumber group origin firstOccurrence groupOccurrences
        (basis, scalar) = do
      location <- inferStoredScalarLocation program origin scalar
      placement <- case storedLocationCapability location of
        LocatedCapability value -> Right value
        capability -> explicitPlanFailure firstOccurrence
          ("materialized component " ++ show basis
            ++ " must be Located, got " ++ show capability)
      let keys =
            [ opaqueDiscreteSemanticKey opaque
            | occurrence <- groupOccurrences
            , let opaque = occurrenceOpaque occurrence
            , opaqueDiscreteResultBasis opaque == basis
            ]
      Right MaterializedComponentPlan
        { materializedComponentBasis = basis
        , materializedComponentSemanticKeys = keys
        , materializedComponentField = AuxiliaryFieldPlan
            { auxiliaryFieldName = internalPrefix ++ "Materialized"
                ++ show requestNumber ++ "B" ++ basisName basis
            , auxiliaryFieldLifetime = StepAuxiliary
            , auxiliaryFieldRole = MaterializedIntermediateRole group basis
            , auxiliaryFieldPlacement = placement
            , auxiliaryFieldComputation = ComputeMaterialized scalar
            }
        }

    valueComponents value = case value of
      ScalarValue scalar -> [(Basis [], scalar)]
      TensorValue tensor -> tensorNFComponents tensor

data StoredScalarLocation = StoredScalarLocation
  { storedLocationCapability :: Capability
  , storedLocationLattice :: Maybe LatticeClass
  } deriving (Eq, Ord, Show)

inferStoredScalarLocation
    :: FEProgram
    -> OriginId
    -> ScalarNF
    -> Either BackendPlanError StoredScalarLocation
inferStoredScalarLocation program origin scalar =
  case scalar of
    Exact _ _ -> Right storedConstantLocation
    Parameter _ -> Right storedConstantLocation
    Coordinate _ -> Right storedSampleableLocation
    Add values -> inferMany values
    Mul values -> inferMany values
    Div lhs rhs -> inferMany [lhs, rhs]
    Pow lhs rhs -> inferMany [lhs, rhs]
    Intrinsic _ values -> inferCall values
    AnalyticCall _ values -> inferCall values
    Select predicate yes no -> do
      predicateLocation <- inferStoredPredicateLocation program origin predicate
      yesLocation <- recurse yes
      noLocation <- recurse no
      joinStoredLocations origin predicateLocation yesLocation
        >>= (\joined -> joinStoredLocations origin joined noLocation)
    FieldJet jet -> inferStoredFieldJetLocation program origin jet
    OpaqueDiscrete opaque -> inferStoredOpaqueLocation program origin opaque
    Ref nodeId ->
      case [value | BindValue candidate value _ <- feProgramStepActions program,
                    candidate == nodeId] of
        [ScalarValue value] -> recurse value
        [TensorValue _] -> explicitPlanFailureFor origin
          Primitives.operatorMaterializedV1OpId (SemanticKey "")
          ("tensor binding " ++ show nodeId ++ " was used as a scalar")
        _ -> explicitPlanFailureFor origin
          Primitives.operatorMaterializedV1OpId (SemanticKey "")
          ("unknown binding " ++ show nodeId)
  where
    recurse = inferStoredScalarLocation program origin
    inferMany values = mapM recurse values >>= foldStoredLocations origin
    inferCall [] = Right storedSampleableLocation
    inferCall values = inferMany values

inferStoredPredicateLocation
    :: FEProgram
    -> OriginId
    -> PredicateNF
    -> Either BackendPlanError StoredScalarLocation
inferStoredPredicateLocation program origin predicate =
  case predicate of
    BoolExact _ -> Right storedConstantLocation
    Compare _ lhs rhs -> inferMany [lhs, rhs]
    Not body -> inferStoredPredicateLocation program origin body
    And bodies -> inferPredicates bodies
    Or bodies -> inferPredicates bodies
  where
    inferMany values = mapM
      (inferStoredScalarLocation program origin) values
      >>= foldStoredLocations origin
    inferPredicates values = mapM
      (inferStoredPredicateLocation program origin) values
      >>= foldStoredLocations origin

inferStoredFieldJetLocation
    :: FEProgram
    -> OriginId
    -> FieldJet
    -> Either BackendPlanError StoredScalarLocation
inferStoredFieldJetLocation program origin jet = do
  field <- case find ((== fieldJetFieldId jet) . logicalFieldId)
      (feProgramFields program) of
    Just value -> Right value
    Nothing -> explicitPlanFailureFor origin
      Primitives.operatorMaterializedV1OpId (SemanticKey "")
      ("unknown field " ++ show (fieldJetFieldId jet))
  source <- mapLocation origin
    (componentPlacement (feProgramDimension program)
      (logicalFieldPolicy field) (fieldJetBasis jet))
  target <- mapLocation origin
    (derivativePlacementForPolicy (logicalFieldPolicy field)
      (fieldJetMultiIndex jet) source)
  Right StoredScalarLocation
    { storedLocationCapability = LocatedCapability target
    , storedLocationLattice = Just
        (latticeClassOfPolicy (logicalFieldPolicy field))
    }

inferStoredOpaqueLocation
    :: FEProgram
    -> OriginId
    -> OpaqueDiscrete
    -> Either BackendPlanError StoredScalarLocation
inferStoredOpaqueLocation program origin opaque
  | operation == Primitives.resampleExplicitV1OpId = do
      request <- mapPrimitivePlanError origin opaque
        (parseResampleRequest dimension opaque)
      _ <- inferStoredScalarLocation program origin (resampleOperand request)
      let bits = resampleTargetBits request
      Right StoredScalarLocation
        { storedLocationCapability = LocatedCapability
            (Placement (map (\bit -> if bit then HalfPoint else IntegerPoint) bits))
        , storedLocationLattice = Just
            (if or bits then StaggeredLattice else CollocatedLattice)
        }
  | operation == Primitives.derivativeOrderedV1OpId = do
      request <- mapPrimitivePlanError origin opaque
        (parseOrderedDerivativeRequest dimension opaque)
      source <- inferStoredScalarLocation program origin
        (orderedDerivativeOperand request)
      case storedLocationCapability source of
        LocatedCapability placement -> do
          plan <- mapExplicitPlanError origin opaque
            (orderedFirstDerivativeStencil
              (storedLocationLattice source == Just StaggeredLattice)
              (orderedDerivativeAxes request) placement)
          Right source
            { storedLocationCapability = LocatedCapability
                (orderedStencilTarget plan) }
        _ -> Right source
  | operation == Primitives.operatorMaterializedV1OpId = do
      request <- mapPrimitivePlanError origin opaque
        (parseMaterializedComponentRequest opaque)
      inferStoredScalarLocation program origin
        (materializedSourceComponent request)
  | operation == Primitives.fluxConservativeDivergenceV1OpId = do
      _ <- mapPrimitivePlanError origin opaque
        (parseConservativeDivergenceRequest dimension opaque)
      cell <- mapLocation origin
        (componentPlacement dimension PrimalPolicy (Basis []))
      Right StoredScalarLocation
        { storedLocationCapability = LocatedCapability cell
        , storedLocationLattice = Just CollocatedLattice
        }
  | operation == lbOperationId = fixedCell
  | operation == metricCodifferentialOperationId = do
      (metricDimension, _, _, operand) <-
        parseMetricCodifferentialPayload program origin opaque
      policy <- inferMetricOperandPolicy program origin operand
      placement <- mapLocation origin
        (componentPlacement metricDimension policy
          (opaqueDiscreteResultBasis opaque))
      Right StoredScalarLocation
        { storedLocationCapability = LocatedCapability placement
        , storedLocationLattice = Just (latticeClassOfPolicy policy)
        }
  | operation == Primitives.derivativeCoordinateWideV1OpId =
      inferStoredCoordinateDerivative False
  | operation == Primitives.derivativeGridWholeV1OpId =
      inferStoredCoordinateDerivative True
  | otherwise = explicitPlanFailureFor origin operation
      (opaqueDiscreteSemanticKey opaque)
      ("unsupported nested opaque operation " ++ show operation)
  where
    operation = opaqueDiscreteOpId opaque
    dimension = feProgramDimension program
    fixedCell = do
      cell <- mapLocation origin
        (componentPlacement dimension CollocatedPolicy (Basis []))
      Right StoredScalarLocation
        { storedLocationCapability = LocatedCapability cell
        , storedLocationLattice = Just CollocatedLattice
        }
    inferStoredCoordinateDerivative isGridWhole = do
      (operand, axisId, order) <- backendDerivativePayload dimension origin opaque
      source <- inferStoredScalarLocation program origin operand
      case storedLocationCapability source of
        LocatedCapability placement -> do
          target <- case storedLocationLattice source of
            Just StaggeredLattice -> mapLocation origin
              (derivativePlacement [(axisId, fromIntegral order)] placement)
            _ -> Right placement
          if not isGridWhole && target /= placement
            then explicitPlanFailureFor origin operation
              (opaqueDiscreteSemanticKey opaque)
              "centered wide derivative cannot change staggered placement"
            else Right source
              { storedLocationCapability = LocatedCapability target }
        _ -> Right source

backendDerivativePayload
    :: Int
    -> OriginId
    -> OpaqueDiscrete
    -> Either BackendPlanError (ScalarNF, AxisId, Int)
backendDerivativePayload dimension origin opaque = do
  operand <- case opaqueDiscreteOperands opaque of
    [ScalarValue value] -> Right value
    _ -> failure "derivative expects one scalar operand"
  orderValue <- oneAttribute (AttributeId "order")
  order <- positive "order" orderValue
  axesValue <- oneAttribute (AttributeId "ordered-axes")
  axis <- case axesValue of
    AttributeValues [AttributeAxis value] -> Right value
    _ -> failure "derivative ordered-axes must contain exactly one AxisId"
  let AxisId axisNumber = axis
  if axisNumber >= 1 && axisNumber <= dimension
    then Right ()
    else failure ("derivative axis is outside dimension " ++ show dimension)
  Right (operand, axis, order)
  where
    failure = explicitPlanFailureFor origin (opaqueDiscreteOpId opaque)
      (opaqueDiscreteSemanticKey opaque)
    oneAttribute identifier =
      case [attributeValue attribute
           | attribute <- opaqueDiscreteAttributes opaque
           , attributeId attribute == identifier] of
        [value] -> Right value
        _ -> failure ("missing or duplicate attribute " ++ show identifier)
    positive label value = case value of
      AttributeNatural natural
        | integer > 0 && integer <= toInteger (maxBound :: Int) ->
            Right (fromInteger integer)
        where integer = toInteger natural
      _ -> failure (label ++ " must be a positive natural")

joinStoredLocations
    :: OriginId
    -> StoredScalarLocation
    -> StoredScalarLocation
    -> Either BackendPlanError StoredScalarLocation
joinStoredLocations origin lhs rhs = do
  capability <- mapLocation origin
    (joinCapability (storedLocationCapability lhs)
      (storedLocationCapability rhs))
  lattice <- case (storedLocationLattice lhs, storedLocationLattice rhs) of
    (Nothing, value) -> Right value
    (value, Nothing) -> Right value
    (left@(Just lhsValue), Just rhsValue)
      | lhsValue == rhsValue -> Right left
      | otherwise -> explicitPlanFailureFor origin
          Primitives.operatorMaterializedV1OpId (SemanticKey "")
          ("expression mixes lattice classes " ++ show lhsValue
            ++ " and " ++ show rhsValue)
  Right StoredScalarLocation
    { storedLocationCapability = capability
    , storedLocationLattice = case capability of
        LocatedCapability _ -> lattice
        _ -> Nothing
    }

foldStoredLocations
    :: OriginId
    -> [StoredScalarLocation]
    -> Either BackendPlanError StoredScalarLocation
foldStoredLocations _ [] = Right storedConstantLocation
foldStoredLocations origin (first : rest) = foldl step (Right first) rest
  where
    step result value = result >>= (\joined ->
      joinStoredLocations origin joined value)

storedConstantLocation :: StoredScalarLocation
storedConstantLocation = StoredScalarLocation ConstantCapability Nothing

storedSampleableLocation :: StoredScalarLocation
storedSampleableLocation = StoredScalarLocation SampleableCapability Nothing

mapPrimitivePlanError
    :: OriginId
    -> OpaqueDiscrete
    -> Either PrimitiveContractError value
    -> Either BackendPlanError value
mapPrimitivePlanError origin opaque = either
  (\problem -> explicitPlanFailureFor origin (opaqueDiscreteOpId opaque)
    (opaqueDiscreteSemanticKey opaque) (show problem)) Right

mapExplicitPlanError
    :: OriginId
    -> OpaqueDiscrete
    -> Either ExplicitStencilError value
    -> Either BackendPlanError value
mapExplicitPlanError origin opaque = either
  (\problem -> explicitPlanFailureFor origin (opaqueDiscreteOpId opaque)
    (opaqueDiscreteSemanticKey opaque) (show problem)) Right

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
  if fieldJetTimeSlot source == CurrentTime
    then Right ()
    else Left (LbSourceMustBeCurrent (logicalFieldId field)
      (fieldJetTimeSlot source) origin)
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
