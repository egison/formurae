module Main where

import Formurae.FEIR.Codec (setProfileFingerprint)
import Formurae.FEIR.Syntax
import Formurae.Post.BackendPlan
import Formurae.Post.Compile (PostError(..), compileProgram)

main :: IO ()
main = do
  testRemovedOpaque (VersionedOpId "flux.conservative-divergence@1")
  testRemovedOpaque (VersionedOpId "operator.materialized@1")
  testMaterializeActionNeedsNoOpaquePlan
  putStrLn "post backend removed primitive tests: ok"

testRemovedOpaque :: VersionedOpId -> IO ()
testRemovedOpaque operation =
  assertLeft ("removed opaque primitive " ++ show operation)
    isUnsupported
    (compileProgram (withOpaqueStep fixture operation))
  where
    isUnsupported (PostAtOrigin _ problem) = isUnsupported problem
    isUnsupported (PostUnsupportedOpaque actual) = actual == operation
    isUnsupported _ = False

testMaterializeActionNeedsNoOpaquePlan :: IO ()
testMaterializeActionNeedsNoOpaquePlan =
  assertRight "ordinary FEIR Materialize action"
    (planBackendEffects materializeProgram)

withOpaqueStep :: FEProgram -> VersionedOpId -> FEProgram
withOpaqueStep program operation = program
  { feProgramStepActions =
      [ UpdateField (scalarEquation (OpaqueDiscrete (OpaqueDiscreteCall
          operation (SemanticKey "removed") (RequestGroupId "removed-group")
          (Basis []) [ScalarValue source] [])))
      ]
  }

materializeProgram :: FEProgram
materializeProgram = fixture
  { feProgramStepActions =
      [ Materialize (FieldId 2) (ScalarValue source) (OriginId 1)
      , UpdateField (scalarEquation (FieldJet (fieldJet (FieldId 2))))
      ]
  }

scalarEquation :: ScalarNF -> FEEquation
scalarEquation scalar = FEEquation (EquationId 1)
  (WholeFieldTarget (FieldId 1) NextTime)
  (TensorNF [] [] 0 [(Basis [], scalar)]) (OriginId 1)

source :: ScalarNF
source = FieldJet (fieldJet (FieldId 1))

fieldJet :: FieldId -> FieldJet
fieldJet field = FieldJetValue field CurrentTime (Basis [])
  [Coordinate (AxisId 1), Coordinate (AxisId 2)] []

fixture :: FEProgram
fixture = FEProgram
  { feProgramVersion = 1
  , feProgramModel = ModelIdentity (ModelId "model") "removed-primitives"
      (SourceIdentity (SourceId "source") "removed-primitives.fme")
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
  , feProgramFields =
      [ LogicalFieldDecl (FieldId 1) "u" CollocatedPolicy
          (TensorType [] [] 0) ScalarLayout [] UserStateLifetime (OriginId 1)
      , LogicalFieldDecl (FieldId 2) "q" CollocatedPolicy
          (TensorType [] [] 0) ScalarLayout [] StepLocalLifetime (OriginId 1)
      ]
  , feProgramInitializers = []
  , feProgramStepActions = []
  , feProgramRawHelpers = []
  , feProgramOrigins = OriginTable []
  , feProgramProvenance = ProvenanceTable []
  }

assertRight :: String -> Either error value -> IO value
assertRight _ (Right value) = pure value
assertRight label (Left _) = fail (label ++ ": expected Right")

assertLeft
    :: Show error => String -> (error -> Bool) -> Either error value -> IO ()
assertLeft label predicate result =
  case result of
    Left problem | predicate problem -> pure ()
    Left problem -> fail (label ++ ": unexpected error " ++ show problem)
    Right _ -> fail (label ++ ": expected Left")
