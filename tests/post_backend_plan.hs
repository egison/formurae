module Main where

import Formurae.FEIR.Codec (setProfileFingerprint)
import qualified Formurae.FEIR.PrimitiveBindings as Primitives
import Formurae.FEIR.Syntax
import Formurae.Post.BackendPlan

-- planBackendEffects is program-level validation of the opaque
-- occurrences: occurrences of one semantic key must agree on their
-- payloads, request groups must agree on their group payloads, and every
-- v1 operation is pure-local, so requests are also permitted in
-- initializers.  There is no auxiliary-field planning left to test.

main :: IO ()
main = do
  testSemanticDeduplication
  testSemanticKeyConflict
  testRequestGroupConflict
  testPureLocalInitializer
  putStrLn "post backend plan tests: ok"

testSemanticDeduplication :: IO ()
testSemanticDeduplication = do
  let opaque = orderedOpaque (SemanticKey "same") (RequestGroupId "same-group")
        (FieldId 1)
      firstEquation = stepEquation (OpaqueDiscrete opaque)
      secondEquation = firstEquation
        { feEquationId = EquationId 3
        , feEquationOrigin = OriginId 2
        }
      repeated = fixture
        { feProgramStepActions =
            [UpdateField firstEquation, UpdateField secondEquation]
        }
  assertRight "identical semantic occurrences deduplicate"
    (planBackendEffects repeated)

testSemanticKeyConflict :: IO ()
testSemanticKeyConflict = do
  let expression = Add
        [ OpaqueDiscrete (orderedOpaque (SemanticKey "shared")
            (RequestGroupId "first-group") (FieldId 1))
        , OpaqueDiscrete (orderedOpaque (SemanticKey "shared")
            (RequestGroupId "second-group") (FieldId 2))
        ]
      program = twoFieldFixture
        { feProgramStepActions = [UpdateField (stepEquation expression)] }
  assertLeft "one semantic key with two payloads"
    (\err -> case err of
      ConflictingOpaqueSemanticKey (SemanticKey "shared") -> True
      _ -> False)
    (planBackendEffects program)

testRequestGroupConflict :: IO ()
testRequestGroupConflict = do
  let expression = Add
        [ OpaqueDiscrete (orderedOpaque (SemanticKey "first-key")
            (RequestGroupId "shared-group") (FieldId 1))
        , OpaqueDiscrete (orderedOpaque (SemanticKey "second-key")
            (RequestGroupId "shared-group") (FieldId 2))
        ]
      program = twoFieldFixture
        { feProgramStepActions = [UpdateField (stepEquation expression)] }
  assertLeft "one request group with two payloads"
    (\err -> case err of
      ConflictingOpaqueRequestGroup (RequestGroupId "shared-group") -> True
      _ -> False)
    (planBackendEffects program)

testPureLocalInitializer :: IO ()
testPureLocalInitializer = do
  let program = fixture
        { feProgramInitializers =
            [AnalyticInitializer (initialEquation
              (OpaqueDiscrete (orderedOpaque (SemanticKey "init-key")
                (RequestGroupId "init-group") (FieldId 1))))]
        }
  assertRight "pure-local request in an initializer"
    (planBackendEffects program)

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
  , feProgramMode = CollocatedMode
  , feProgramDimension = 2
  , feProgramAxes =
      [ AxisDecl (AxisId 1) "x" "x" (OriginId 1)
      , AxisDecl (AxisId 2) "y" "y" (OriginId 1)
      ]
  , feProgramGeometry = GeometryDecl (GeometryId 1) Nothing Nothing
      EuclideanGeometry
  , feProgramParameters = []
  , feProgramFunctions = []
  , feProgramFields = [scalarField (FieldId 1) "u" CollocatedPolicy]
  , feProgramInitializers = []
  , feProgramStepActions =
      [UpdateField (stepEquation (OpaqueDiscrete (orderedOpaque
        (SemanticKey "u-key") (RequestGroupId "u-group") (FieldId 1))))]
  , feProgramRawHelpers = []
  , feProgramOrigins = OriginTable [(OriginId 1, origin)]
  , feProgramProvenance = ProvenanceTable []
  }

twoFieldFixture :: FEProgram
twoFieldFixture = fixture
  { feProgramFields =
      [ scalarField (FieldId 1) "u" CollocatedPolicy
      , scalarField (FieldId 2) "v" CollocatedPolicy
      ]
  }

scalarField :: FieldId -> String -> GridPolicy -> LogicalFieldDecl
scalarField fieldId name policy = LogicalFieldDecl fieldId name policy
  (TensorType [] [] 0) ScalarLayout [] UserStateLifetime (OriginId 1)

fieldJet :: FieldId -> FieldJet
fieldJet fieldId = FieldJetValue fieldId CurrentTime (Basis [])
  [Coordinate (AxisId 1), Coordinate (AxisId 2)] []

orderedOpaque :: SemanticKey -> RequestGroupId -> FieldId -> OpaqueDiscrete
orderedOpaque key group fieldId = OpaqueDiscreteCall
  Primitives.derivativeOrderedV1OpId key group (Basis [])
  [ScalarValue (FieldJet (fieldJet fieldId))]
  [ Attribute (AttributeId "order") (AttributeNatural 1)
  , Attribute (AttributeId "ordered-axes")
      (AttributeValues [AttributeAxis (AxisId 1)])
  , Attribute (AttributeId "radius") (AttributeNatural 1)
  ]

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
