module Main where

import Formurae.FEIR.Codec (setProfileFingerprint)
import Formurae.FEIR.Syntax
import Formurae.Post.BackendPlan
import Formurae.Post.Location

main :: IO ()
main = do
  testLbPlan
  testSemanticDeduplication
  testDistinctSources
  testInitializerRejection
  testGeometryDiagnostics
  testSourceContract
  testRequestContract
  putStrLn "post backend plan tests: ok"

testLbPlan :: IO ()
testLbPlan = do
  plan <- assertRight "plan lb" (planBackendEffects fixture)
  assertEqual "shared metric auxiliaries"
    [ OrthogonalCoefficientRole (AxisId 1)
    , OrthogonalCoefficientRole (AxisId 2)
    , OrthogonalVolumeRole
    ]
    (map auxiliaryFieldRole (backendGeometryInitializers plan))
  assertEqual "metric sampling placements"
    [ Placement [HalfPoint, IntegerPoint]
    , Placement [IntegerPoint, HalfPoint]
    , Placement [IntegerPoint, IntegerPoint]
    ]
    (map auxiliaryFieldPlacement (backendGeometryInitializers plan))
  assertEqual "one logical lb request" 1 (length (backendLbRequests plan))
  request <- case backendLbRequests plan of
    [value] -> pure value
    values -> fail ("expected one lb request, got " ++ show values)
  assertEqual "flux/result topological schedule"
    [ LbFluxRole (RequestGroupId "lb-u") (AxisId 1)
    , LbFluxRole (RequestGroupId "lb-u") (AxisId 2)
    , LbResultRole (RequestGroupId "lb-u")
    ]
    (map auxiliaryFieldRole (backendStepSchedule plan))
  assertEqual "lb flux placements"
    [ Placement [HalfPoint, IntegerPoint]
    , Placement [IntegerPoint, HalfPoint]
    ]
    (map auxiliaryFieldPlacement (lbRequestFluxFields request))
  assertEqual "lb result placement" (Placement [IntegerPoint, IntegerPoint])
    (auxiliaryFieldPlacement (lbRequestResultField request))
  assertEqual "opaque result replacement"
    (Just "FormuraeInternalLb1Result")
    (lookupOpaqueResult plan (SemanticKey "lb-u-key"))
  case map auxiliaryFieldComputation (backendGeometryInitializers plan) of
    [ SampleGeometry coefficient1
      , SampleGeometry coefficient2
      , SampleGeometry volume
      ] -> do
        assertEqual "axis-one coefficient" (Div volume (Pow (Exact 1 1) (Exact 2 1)))
          coefficient1
        assertEqual "axis-two coefficient"
          (Div volume (Pow (Coordinate (AxisId 2)) (Exact 2 1)))
          coefficient2
    other -> fail ("unexpected geometry computations: " ++ show other)

testSemanticDeduplication :: IO ()
testSemanticDeduplication = do
  let opaque = lbOpaque (FieldId 1) (SemanticKey "same")
        (RequestGroupId "same-group")
      firstEquation = stepEquation (OpaqueDiscrete opaque)
      secondEquation = firstEquation
        { feEquationId = EquationId 3
        , feEquationOrigin = OriginId 2
        }
      repeated = fixture
        { feProgramStepActions =
            [UpdateField firstEquation, UpdateField secondEquation]
        }
  plan <- assertRight "deduplicate identical semantic request"
    (planBackendEffects repeated)
  assertEqual "same request has one bundle" 1 (length (backendLbRequests plan))
  assertEqual "dedup retains every source occurrence"
    [(SemanticKey "same", [OriginId 1, OriginId 2])]
    (backendOpaqueOrigins plan)

testDistinctSources :: IO ()
testDistinctSources = do
  let first = scalarField (FieldId 1) "u" CollocatedPolicy
      second = scalarField (FieldId 2) "v" CollocatedPolicy
      expression = Add
        [ OpaqueDiscrete (lbOpaque (FieldId 1)
            (SemanticKey "u-key") (RequestGroupId "u-group"))
        , OpaqueDiscrete (lbOpaque (FieldId 2)
            (SemanticKey "v-key") (RequestGroupId "v-group"))
        ]
      program = fixture
        { feProgramFields = [first, second]
        , feProgramStepActions = [UpdateField (stepEquation expression)]
        }
  plan <- assertRight "distinct lb sources" (planBackendEffects program)
  assertEqual "distinct requests get independent bundles" 2
    (length (backendLbRequests plan))
  assertEqual "each bundle schedules two fluxes and a result" 6
    (length (backendStepSchedule plan))
  assertEqual "deterministic distinct result names"
    [ "FormuraeInternalLb1Result"
    , "FormuraeInternalLb2Result"
    ]
    (map (auxiliaryFieldName . lbRequestResultField)
      (backendLbRequests plan))

testInitializerRejection :: IO ()
testInitializerRejection = do
  let program = fixture
        { feProgramInitializers =
            [AnalyticInitializer (initialEquation
              (OpaqueDiscrete defaultLbOpaque))]
        }
  assertLeft "effectful initializer"
    (\err -> case err of
      EffectfulRequestInInitializer op _ _ -> op == lbOperationId
      _ -> False)
    (planBackendEffects program)

testGeometryDiagnostics :: IO ()
testGeometryDiagnostics = do
  let euclidean = fixture
        { feProgramGeometry = GeometryDecl (GeometryId 1) Nothing Nothing
            EuclideanGeometry
        }
  assertLeft "lb needs variable orthogonal metric"
    (\err -> case err of
      LbNeedsOrthogonalMetric (GeometryId 1) _ -> True
      _ -> False)
    (planBackendEffects euclidean)

  let geometry = feProgramGeometry fixture
      unverifiedKind = case geometryDeclKind geometry of
        OrthogonalScaleGeometry scales normalForm ->
          OrthogonalScaleGeometry scales
            (normalForm { geometryOrthogonalityVerified = False })
        other -> other
      unverified = fixture
        { feProgramGeometry = geometry { geometryDeclKind = unverifiedKind } }
  assertLeft "unverified geometry"
    (\err -> case err of
      LbUnverifiedOrthogonalMetric (GeometryId 1) _ -> True
      _ -> False)
    (planBackendEffects unverified)

testSourceContract :: IO ()
testSourceContract = do
  let primal = fixture
        { feProgramFields = [scalarField (FieldId 1) "u" PrimalPolicy] }
  assertLeft "lb source must be collocated"
    (\err -> case err of
      LbSourceMustBeCollocated (FieldId 1) PrimalPolicy _ -> True
      _ -> False)
    (planBackendEffects primal)

  let badJet = (fieldJet (FieldId 1))
        { fieldJetArguments = [Coordinate (AxisId 2), Coordinate (AxisId 1)] }
      badCoordinates = withOpaque fixture
        (defaultLbOpaque
          { opaqueDiscreteOperands = [ScalarValue (FieldJet badJet)] })
  assertLeft "canonical coordinate vector"
    (\err -> case err of
      LbSourceMustUseCanonicalCoordinates (FieldId 1) _ -> True
      _ -> False)
    (planBackendEffects badCoordinates)

testRequestContract :: IO ()
testRequestContract = do
  let missingMetric = withOpaque fixture
        (defaultLbOpaque
          { opaqueDiscreteAttributes =
              [Attribute (AttributeId "source-policy")
                (AttributeGridPolicy CollocatedPolicy)] })
  assertLeft "metric attribute is required"
    (\err -> case err of
      MissingOpaqueAttribute _ (AttributeId "metric") _ -> True
      _ -> False)
    (planBackendEffects missingMetric)

  let codiff = defaultLbOpaque
        { opaqueDiscreteOpId = metricCodifferentialOperationId
        , opaqueDiscreteSemanticKey = SemanticKey "delta-key"
        , opaqueDiscreteRequestGroup = RequestGroupId "delta-group"
        }
  assertLeft "metric codifferential validates its form payload"
    (\err -> case err of
      MetricCodifferentialPlanError _ _ -> True
      _ -> False)
    (planBackendEffects (withOpaque fixture codiff))

fixture :: FEProgram
fixture = FEProgram
  { feProgramVersion = 1
  , feProgramModel = ModelIdentity (ModelId "model") "geometry"
      (SourceIdentity (SourceId "source") "geometry.fme")
  , feProgramRegistryId = RegistryId "registry"
  , feProgramPrimitiveManifestId = PrimitiveManifestId "manifest"
  , feProgramDiscretization = setProfileFingerprint
      (DiscretizationProfile
        (VersionedProfileId "formurae-discretization@1")
        (Fingerprint "") [] FixedAxisOrder)
  , feProgramMode = DecMode
  , feProgramDimension = 2
  , feProgramAxes =
      [ AxisDecl (AxisId 1) "x" "x" (OriginId 1)
      , AxisDecl (AxisId 2) "y" "y" (OriginId 1)
      ]
  , feProgramGeometry = orthogonalGeometry
  , feProgramParameters = []
  , feProgramFunctions = []
  , feProgramFields = [scalarField (FieldId 1) "u" CollocatedPolicy]
  , feProgramInitializers = []
  , feProgramStepActions =
      [UpdateField (stepEquation (OpaqueDiscrete defaultLbOpaque))]
  , feProgramRawHelpers = []
  , feProgramOrigins = OriginTable [(OriginId 1, origin)]
  , feProgramProvenance = ProvenanceTable []
  }

orthogonalGeometry :: GeometryDecl
orthogonalGeometry = GeometryDecl (GeometryId 1) (Just "g")
  (Just (OriginId 1))
  (OrthogonalScaleGeometry scales geometryNF)
  where
    scales =
      [ (AxisId 1, Exact 1 1)
      , (AxisId 2, Coordinate (AxisId 2))
      ]
    geometryNF = GeometryNF identityTensor identityTensor scales
      (Coordinate (AxisId 2)) True

identityTensor :: TensorNF
identityTensor = TensorNF [2, 2] [VarianceDown, VarianceDown] 0
  [ (Basis [1, 1], Exact 1 1)
  , (Basis [1, 2], Exact 0 1)
  , (Basis [2, 1], Exact 0 1)
  , (Basis [2, 2], Exact 1 1)
  ]

scalarField :: FieldId -> String -> GridPolicy -> LogicalFieldDecl
scalarField fieldId name policy = LogicalFieldDecl fieldId name policy
  (TensorType [] [] 0) ScalarLayout [] UserStateLifetime (OriginId 1)

fieldJet :: FieldId -> FieldJet
fieldJet fieldId = FieldJetValue fieldId CurrentTime (Basis [])
  [Coordinate (AxisId 1), Coordinate (AxisId 2)] []

defaultLbOpaque :: OpaqueDiscrete
defaultLbOpaque = lbOpaque (FieldId 1)
  (SemanticKey "lb-u-key") (RequestGroupId "lb-u")

lbOpaque :: FieldId -> SemanticKey -> RequestGroupId -> OpaqueDiscrete
lbOpaque fieldId key group = OpaqueDiscreteCall
  lbOperationId key group (Basis [])
  [ScalarValue (FieldJet (fieldJet fieldId))]
  [ Attribute (AttributeId "metric") (AttributeGeometry (GeometryId 1))
  , Attribute (AttributeId "source-policy")
      (AttributeGridPolicy CollocatedPolicy)
  ]

withOpaque :: FEProgram -> OpaqueDiscrete -> FEProgram
withOpaque program opaque = program
  { feProgramStepActions =
      [UpdateField (stepEquation (OpaqueDiscrete opaque))] }

stepEquation :: ScalarNF -> FEEquation
stepEquation scalar = FEEquation (EquationId 1)
  (WholeFieldTarget (FieldId 1) NextTime)
  (scalarTensor scalar) (OriginId 1)

initialEquation :: ScalarNF -> FEEquation
initialEquation scalar = FEEquation (EquationId 2)
  (WholeFieldTarget (FieldId 1) CurrentTime)
  (scalarTensor scalar) (OriginId 1)

scalarTensor :: ScalarNF -> TensorNF
scalarTensor scalar = TensorNF [] [] 0 [(Basis [], scalar)]

origin :: SourceOrigin
origin = SourceOrigin
  (SourceLocation (SourceId "source") "geometry.fme" 1 1 1 1) []

assertRight :: String -> Either a b -> IO b
assertRight _ (Right value) = pure value
assertRight label (Left _) = fail (label ++ ": expected Right")

assertLeft :: String -> (a -> Bool) -> Either a b -> IO ()
assertLeft label predicate result =
  case result of
    Left err | predicate err -> pure ()
    Left _ -> fail (label ++ ": unexpected error")
    Right _ -> fail (label ++ ": expected Left")

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
