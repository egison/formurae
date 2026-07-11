module Main where

import Formurae.FEIR.RegistryFingerprint
import Formurae.FEIR.Syntax
import Formurae.Pre.Parse (parseModel)
import Formurae.Pre.Registry
import qualified Formurae.Syntax as Surface

main :: IO ()
main = do
  model <- parseModel "registry-id.fme" "registry-id" source
  registry <- requireRight (buildRegistry model)
  let program = programFrom model registry
      registryId = computeRegistryId program
      operationalChange = program
        { feProgramStepActions =
            [BindValue (NodeId 1) (ScalarValue (Exact 7 3)) (OriginId 1)]
        , feProgramProvenance = ProvenanceTable [(NodeId 1, [OriginId 1])]
        , feProgramDiscretization = (feProgramDiscretization program)
            { discretizationMixedRule = FixedAxisOrder }
        }
      renamedField = program
        { feProgramFields =
            [field { logicalFieldSourceName = logicalFieldSourceName field ++ "2" }
            | field <- feProgramFields program]
        }
  assertEqual "registry digest is deterministic"
    registryId (computeRegistryId program)
  assertEqual "actions, provenance, and profile are outside registry identity"
    registryId (computeRegistryId operationalChange)
  assert "logical field declarations are inside registry identity"
    (registryId /= computeRegistryId renamedField)
  assert "stored ID verifies" (registryIdMatches program
    { feProgramRegistryId = registryId })
  putStrLn "FEIR registry fingerprint tests: ok"

programFrom :: Surface.Model -> PreRegistry -> FEProgram
programFrom model registry = FEProgram
  { feProgramVersion = 1
  , feProgramModel = preRegistryModelIdentity registry
  , feProgramRegistryId = RegistryId "pending"
  , feProgramPrimitiveManifestId = PrimitiveManifestId "manifest-test"
  , feProgramDiscretization = preRegistryDiscretization registry
  , feProgramMode = CollocatedMode
  , feProgramDimension = Surface.mDim model
  , feProgramAxes = preRegistryAxes registry
  , feProgramGeometry = preRegistryGeometry registry
  , feProgramParameters = preRegistryParameters registry
  , feProgramFunctions = preRegistryFunctions registry
  , feProgramFields = preRegistryFields registry
  , feProgramInitializers = []
  , feProgramStepActions = []
  , feProgramRawHelpers = preRegistryRawHelpers registry
  , feProgramOrigins = preRegistryOrigins registry
  , feProgramProvenance = ProvenanceTable []
  }

source :: String
source = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "param alpha = 0.25"
  , "field u : scalar"
  , "init:"
  , "  u = 0.0"
  , "step:"
  , "  u' = u"
  ]

requireRight :: Either RegistryError a -> IO a
requireRight (Right value) = pure value
requireRight (Left err) = fail (show err)

assert :: String -> Bool -> IO ()
assert _ True = pure ()
assert label False = fail label

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
