module Main where

import Data.List (isInfixOf)

import Formurae.FEIR.Codec (setProfileFingerprint)
import Formurae.FEIR.Syntax
import Formurae.FEIR.Validate
import qualified Formurae.Post.BackendPlan as Backend
import Formurae.Post.Compile
import Formurae.Post.Diagnostic
import Formurae.Post.FMR (FMRError(..))
import Formurae.Post.Location (HalfBit(..), LocationError(..), Placement(..))
import Formurae.Post.Profile (ProfileError(..))

main :: IO ()
main = do
  testValidationRegistryPaths
  testValidationActionAndOpaquePaths
  testPostIdentifierResolution
  testBackendPlanResolution
  testProfileAndFallbackResolution
  testExpansionTrace
  putStrLn "post diagnostic tests: ok"

testValidationRegistryPaths :: IO ()
testValidationRegistryPaths = do
  assertRendered "profile rule origin"
    "/workspace/model.fme:5:3: formal accuracy must be positive and even, got 3"
    (renderValidationError fixture
      (ValidationError
        [ProgramPath, ProfilePath, DerivativeRulePath 0]
        (InvalidFormalAccuracy 3)))
  assertPrefix "field origin" "/workspace/model.fme:10:1: "
    (renderValidationError fixture
      (ValidationError [ProgramPath, FieldPath (FieldId 1)]
        (InvalidLayout VectorLayout (TensorType [] [] 0))))
  assertPrefix "function origin" "/workspace/model.fme:12:7: "
    (renderValidationError fixture
      (ValidationError [ProgramPath, FunctionPath (FunctionId 1)]
        (InvalidFunctionArity (-1))))
  assertPrefix "initializer equation origin" "/workspace/model.fme:20:5: "
    (renderValidationError fixture
      (ValidationError
        [ ProgramPath, InitializerPath 0, EquationPath (EquationId 1)
        , TensorComponentPath (Basis []), ScalarChildPath 0
        ]
        DivisionByZero))

testValidationActionAndOpaquePaths :: IO ()
testValidationActionAndOpaquePaths = do
  assertPrefix "bind node origin" "/workspace/model.fme:30:9: "
    (renderValidationError fixture
      (ValidationError
        [ProgramPath, ActionPath 0, NodePath (NodeId 1)]
        (RefNotPreceding (NodeId 1))))
  assertPrefix "equation action origin" "/workspace/model.fme:40:3: "
    (renderValidationError fixture
      (ValidationError
        [ProgramPath, ActionPath 1, EquationPath (EquationId 2)]
        (InvalidTargetTime CurrentTime NextTime)))
  assertRendered "global opaque key resolves its request occurrence"
    "/workspace/model.fme:40:3: unknown opaque operation OpId \"operator.retired\""
    (renderValidationError fixture
      (ValidationError [ProgramPath, OpaquePath opaqueKey]
        (UnknownOpaqueOperation retiredOperationId)))

testPostIdentifierResolution :: IO ()
testPostIdentifierResolution = do
  assertRendered "post field ID"
    "/workspace/model.fme:10:1: unknown field FieldId 1"
    (renderPostError fixture (PostUnknownField (FieldId 1)))
  assertPrefix "post function ID" "/workspace/model.fme:12:7: "
    (renderPostError fixture (PostUnknownFunction (FunctionId 1)))
  assertRendered "post node ID"
    "/workspace/model.fme:30:9: unknown binding NodeId 1"
    (renderPostError fixture (PostUnknownBinding (NodeId 1)))
  assertPrefix "FMR field ID" "/workspace/model.fme:10:1: "
    (renderPostError fixture
      (PostFMRError (InvalidFMRBasis (FieldId 1) (Basis [1]))))
  assertPrefix "location axis ID" "/workspace/model.fme:2:1: "
    (renderPostError fixture
      (PostLocationError (InvalidDerivativeAxis (AxisId 1) 0)))
  assertRendered "opaque operation occurrence"
    "/workspace/model.fme:40:3: unsupported opaque operation OpId \"operator.retired\""
    (renderPostError fixture (PostUnsupportedOpaque retiredOperationId))
  assertRendered "wide request error keeps opaque occurrence origin"
    "/workspace/model.fme:40:3: wide derivative is missing attribute AttributeId \"radius\""
    (renderPostError fixture
      (PostWideDerivativeError opaqueKey
        (WideMetadataError
          (DerivativeMissingAttribute (AttributeId "radius")))))
  assertRendered "grid-whole request error keeps opaque occurrence origin"
    "/workspace/model.fme:40:3: grid-whole derivative radius must be 1, got 2"
    (renderPostError fixture
      (PostGridWholeDerivativeError opaqueKey
        (GridWholeRadiusMustBeOne 2)))
  assertRendered "shared derivative lattice error keeps occurrence origin"
    "/workspace/model.fme:40:3: discrete derivative operand mixes lattice classes CollocatedLattice and StaggeredLattice"
    (renderPostError fixture
      (PostDerivativeLatticeMismatch opaqueKey
        CollocatedLattice StaggeredLattice))

testBackendPlanResolution :: IO ()
testBackendPlanResolution = do
  assertRendered "origin-bearing backend error"
    "/workspace/model.fme:40:3: effectful operation OpId \"operator.retired\" (SemanticKey \"opaque-key\") is not supported by this formurae-post"
    (renderPostError fixture
      (PostBackendPlanError (Backend.UnsupportedEffectfulOperation
        retiredOperationId opaqueKey (OriginId 7))))
  assertRendered "originless semantic conflict finds occurrence"
    "/workspace/model.fme:40:3: conflicting opaque semantic key SemanticKey \"opaque-key\""
    (renderPostError fixture
      (PostBackendPlanError
        (Backend.ConflictingOpaqueSemanticKey opaqueKey)))
  assertRendered "originless request-group conflict finds occurrence"
    "/workspace/model.fme:40:3: conflicting opaque request group RequestGroupId \"opaque-group\""
    (renderPostError fixture
      (PostBackendPlanError
        (Backend.ConflictingOpaqueRequestGroup opaqueGroup)))

testProfileAndFallbackResolution :: IO ()
testProfileAndFallbackResolution = do
  assertRendered "post profile rule origin"
    "/workspace/model.fme:5:3: profile formal accuracy must be positive and even, got 3"
    (renderPostError fixture
      (PostProfileError (InvalidProfileFormalAccuracy 3)))
  assertRendered "fallback source path"
    "/workspace/model.fme:2:1: invalid placement dimension 0"
    (renderPostError fixture
      (PostLocationError (InvalidLocationDimension 0)))
  assertRendered "unknown identifier fallback"
    "/workspace/model.fme:2:1: unknown field FieldId 999"
    (renderPostError fixture (PostUnknownField (FieldId 999)))
  assertRendered "validation header fallback"
    "/workspace/model.fme:2:1: dimension must be positive, got 0"
    (renderValidationError fixture
      (ValidationError [ProgramPath] (InvalidDimension 0)))
  assertPrefix "compile context overrides the global fallback"
    "/workspace/model.fme:40:3: grid placement mismatch: "
    (renderPostError fixture
      (PostAtOrigin (OriginId 7)
        (PostInvalidReferencePlacement
          (Placement [IntegerPoint]) (Placement [HalfPoint]))))

testExpansionTrace :: IO ()
testExpansionTrace = do
  let rendered = renderPostError fixture (PostUnknownFunction (FunctionId 1))
  assertContains "expansion call note"
    "expanded from helper at /workspace/model.fme:12:7" rendered
  assertContains "expansion definition note"
    "defined at /workspace/model.fme:8:1" rendered

fixture :: FEProgram
fixture = FEProgram
  { feProgramModel = ModelIdentity (ModelId "model") "model"
      (SourceIdentity (SourceId "source") "/workspace/model.fme")
  , feProgramRegistryId = RegistryId "registry"
  , feProgramPrimitiveManifestId = PrimitiveManifestId "manifest"
  , feProgramDiscretization = setProfileFingerprint
      (DiscretizationProfile
        (Fingerprint "")
        [DerivativeRule CollocatedLattice (Just (Positive 1))
          CenteredTaylor (PositiveEven 3) (OriginId 2)]
        FixedAxisOrder)
  , feProgramMode = CollocatedMode
  , feProgramDimension = 1
  , feProgramAxes = [AxisDecl (AxisId 1) "x" "x" PeriodicBoundary (OriginId 1)]
  , feProgramGeometry = GeometryDecl (GeometryId 1) Nothing Nothing
      EuclideanGeometry
  , feProgramParameters = []
  , feProgramFunctions =
      [FunctionDecl (FunctionId 1) "exp" "exp" (Just 1)
        IntrinsicFunction (Just (OriginId 4))]
  , feProgramFields =
      [LogicalFieldDecl (FieldId 1) "u" CollocatedPolicy
        (TensorType [] [] 0) ScalarLayout [] UserStateLifetime (OriginId 3)]
  , feProgramInitializers =
      [AnalyticInitializer (FEEquation (EquationId 1)
        (WholeFieldTarget (FieldId 1) CurrentTime)
        (scalarTensor (Exact 0 1)) (OriginId 5))]
  , feProgramStepActions =
      [ BindValue (NodeId 1) (ScalarValue (Exact 1 1)) (OriginId 6)
      , UpdateField (FEEquation (EquationId 2)
          (WholeFieldTarget (FieldId 1) NextTime)
          (scalarTensor (OpaqueDiscrete opaque)) (OriginId 7))
      ]
  , feProgramRawHelpers = []
  , feProgramOrigins = OriginTable
      [ (OriginId 1, sourceOrigin 2 1 [])
      , (OriginId 2, sourceOrigin 5 3 [])
      , (OriginId 3, sourceOrigin 10 1 [])
      , (OriginId 4, sourceOrigin 12 7 [expansion])
      , (OriginId 5, sourceOrigin 20 5 [])
      , (OriginId 6, sourceOrigin 30 9 [])
      , (OriginId 7, sourceOrigin 40 3 [])
      ]
  , feProgramProvenance = ProvenanceTable
      [(NodeId 1, [OriginId 6])]
  }

retiredOperationId :: OpId
retiredOperationId = OpId "operator.retired"

opaqueKey :: SemanticKey
opaqueKey = SemanticKey "opaque-key"

opaqueGroup :: RequestGroupId
opaqueGroup = RequestGroupId "opaque-group"

opaque :: OpaqueDiscrete
opaque = OpaqueDiscreteCall retiredOperationId opaqueKey opaqueGroup
  (Basis []) [ScalarValue (FieldJet fieldJet)]
  [Attribute (AttributeId "metric") (AttributeGeometry (GeometryId 1))]

fieldJet :: FieldJet
fieldJet = FieldJetValue (FieldId 1) CurrentTime (Basis [])
  [Coordinate (AxisId 1)] []

scalarTensor :: ScalarNF -> TensorNF
scalarTensor scalar = TensorNF [] [] 0 [(Basis [], scalar)]

sourceOrigin :: Int -> Int -> [ExpansionFrame] -> SourceOrigin
sourceOrigin line column trace = SourceOrigin
  (location line column) trace

location :: Int -> Int -> SourceLocation
location line column = SourceLocation (SourceId "source")
  "/workspace/model.fme" line line column column

expansion :: ExpansionFrame
expansion = ExpansionFrame "helper" (location 8 1) (location 12 7)

assertRendered :: String -> String -> String -> IO ()
assertRendered label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected\n" ++ expected ++ "\ngot\n" ++ actual)

assertPrefix :: String -> String -> String -> IO ()
assertPrefix label prefix actual
  | beginsWith prefix actual = pure ()
  | otherwise = fail
      (label ++ ": expected prefix " ++ show prefix ++ " in " ++ show actual)

assertContains :: String -> String -> String -> IO ()
assertContains label needle haystack
  | needle `isInfixOf` haystack = pure ()
  | otherwise = fail
      (label ++ ": missing " ++ show needle ++ " in " ++ show haystack)

beginsWith :: Eq a => [a] -> [a] -> Bool
beginsWith [] _ = True
beginsWith _ [] = False
beginsWith (x : xs) (y : ys) = x == y && beginsWith xs ys
