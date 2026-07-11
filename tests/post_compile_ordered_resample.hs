module Main where

import Data.List (isInfixOf)

import Formurae.FEIR.Codec (setProfileFingerprint)
import qualified Formurae.FEIR.PrimitiveBindings as Primitives
import Formurae.FEIR.Syntax
import Formurae.Post.Compile
import Formurae.Post.Diagnostic (renderPostError)
import Formurae.Post.FMR (renderProgram)

main :: IO ()
main = do
  testOrderedAndResample
  testSourceAwarePlacementError
  testSourceAwareMetadataError
  putStrLn "post compile ordered/resample tests: ok"

testOrderedAndResample :: IO ()
testOrderedAndResample = do
  let ordered = orderedOpaque "ordered" sourceJet [AxisId 2, AxisId 1]
      sampled = resampleOpaque "sampled" sourceJet [True, True]
      program = fixture
        { feProgramStepActions =
            [ update (EquationId 1) (FieldId 1) (OpaqueDiscrete ordered)
            , update (EquationId 2) (FieldId 2) (OpaqueDiscrete sampled)
            ]
        }
  compiled <- assertRight "ordered/resample compile" (compileProgram program)
  rendered <- assertRight "ordered/resample render" (renderProgram compiled)
  assertContains "ordered axis sequence becomes fixed cross stencil"
    "u'[i,j] = ((-1 / 4) * u[i-1,j+1] + (-1 / 4) * u[i+1,j-1] + (1 / 4) * u[i-1,j-1] + (1 / 4) * u[i+1,j+1]) / (dx * dy)"
    rendered
  assertContains "absolute half/half resampling is tensor-product linear"
    "v'[i,j] = (1 / 4) * u[i,j] + (1 / 4) * u[i,j+1] + (1 / 4) * u[i+1,j] + (1 / 4) * u[i+1,j+1]"
    rendered
  assertNotContains "ordered derivative bypasses accuracy-four profile"
    "i+2" rendered
  assertNotContains "no opaque marker survives" "opaque" rendered

testSourceAwarePlacementError :: IO ()
testSourceAwarePlacementError = do
  let sampled = resampleOpaque "wrong-target" sourceJet [True, True]
      program = fixture
        { feProgramStepActions =
            [update (EquationId 3) (FieldId 1) (OpaqueDiscrete sampled)] }
  case compileProgram program of
    Left postError -> case stripOrigin postError of
      PostExplicitStencilError (SemanticKey "wrong-target") _ ->
        assertContains "placement diagnostic points to the source equation"
          "ordered-resample.fme:7:3: explicit primitive stencil error"
          (renderPostError program postError)
      problem -> fail ("unexpected placement error " ++ show problem)
    Right _ -> fail "wrong resample target unexpectedly compiled"

testSourceAwareMetadataError :: IO ()
testSourceAwareMetadataError = do
  let ordered = orderedOpaque "unknown-axis" sourceJet [AxisId 3]
      program = fixture
        { feProgramStepActions =
            [update (EquationId 4) (FieldId 1) (OpaqueDiscrete ordered)] }
  case compileProgram program of
    Left postError -> case stripOrigin postError of
      PostPrimitiveContractError (SemanticKey "unknown-axis") _ ->
        assertContains "metadata diagnostic points to the source equation"
          "ordered-resample.fme:7:3: explicit primitive contract error"
          (renderPostError program postError)
      problem -> fail ("unexpected metadata error " ++ show problem)
    Right _ -> fail "unknown ordered axis unexpectedly compiled"

stripOrigin :: PostError -> PostError
stripOrigin (PostAtOrigin _ nested) = stripOrigin nested
stripOrigin value = value

orderedOpaque :: String -> FieldJet -> [AxisId] -> OpaqueDiscrete
orderedOpaque key jet axes = OpaqueDiscreteCall
  Primitives.derivativeOrderedV1OpId
  (SemanticKey key) (RequestGroupId (key ++ "-group")) (Basis [])
  [ScalarValue (FieldJet jet)]
  [ Attribute (AttributeId "order")
      (AttributeNatural (fromIntegral (length axes)))
  , Attribute (AttributeId "ordered-axes")
      (AttributeValues (map AttributeAxis axes))
  , Attribute (AttributeId "radius") (AttributeNatural 1)
  ]

resampleOpaque :: String -> FieldJet -> [Bool] -> OpaqueDiscrete
resampleOpaque key jet bits = OpaqueDiscreteCall
  Primitives.resampleExplicitV1OpId
  (SemanticKey key) (RequestGroupId (key ++ "-group")) (Basis [])
  [ScalarValue (FieldJet jet)]
  [Attribute (AttributeId "target-placement")
    (AttributeValues (map AttributeBoolean bits))]

sourceJet :: FieldJet
sourceJet = FieldJetValue (FieldId 1) CurrentTime (Basis [])
  [Coordinate (AxisId 1), Coordinate (AxisId 2)] []

update :: EquationId -> FieldId -> ScalarNF -> FEAction
update equationId fieldId scalar = UpdateField
  (FEEquation equationId (WholeFieldTarget fieldId NextTime)
    (TensorNF [] [] 0 [(Basis [], scalar)]) (OriginId 1))

fixture :: FEProgram
fixture = FEProgram
  { feProgramVersion = 1
  , feProgramModel = ModelIdentity (ModelId "ordered-resample")
      "ordered-resample"
      (SourceIdentity (SourceId "source") "ordered-resample.fme")
  , feProgramRegistryId = RegistryId "registry"
  , feProgramPrimitiveManifestId = PrimitiveManifestId "manifest"
  , feProgramDiscretization = setProfileFingerprint
      (DiscretizationProfile
        (VersionedProfileId "formurae-discretization@1")
        (Fingerprint "")
        [DerivativeRule CollocatedLattice Nothing CenteredTaylor
          (PositiveEven 4) (OriginId 1)]
        FixedAxisOrder)
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
      [ scalarField (FieldId 1) "u" CollocatedPolicy
      , scalarField (FieldId 2) "v" DualPolicy
      ]
  , feProgramInitializers = []
  , feProgramStepActions = []
  , feProgramRawHelpers = []
  , feProgramOrigins = OriginTable [(OriginId 1, origin)]
  , feProgramProvenance = ProvenanceTable []
  }

scalarField :: FieldId -> String -> GridPolicy -> LogicalFieldDecl
scalarField identifier name policy = LogicalFieldDecl identifier name policy
  (TensorType [] [] 0) ScalarLayout [] UserStateLifetime (OriginId 1)

origin :: SourceOrigin
origin = SourceOrigin
  (SourceLocation (SourceId "source") "ordered-resample.fme"
    7 7 3 20) []

assertRight :: String -> Either error value -> IO value
assertRight _ (Right value) = pure value
assertRight label (Left _) = fail (label ++ ": expected Right")

assertContains :: String -> String -> String -> IO ()
assertContains label needle haystack
  | needle `isInfixOf` haystack = pure ()
  | otherwise = fail (label ++ ": missing " ++ show needle
      ++ " in:\n" ++ haystack)

assertNotContains :: String -> String -> String -> IO ()
assertNotContains label needle haystack
  | needle `isInfixOf` haystack = fail
      (label ++ ": unexpectedly found " ++ show needle)
  | otherwise = pure ()
