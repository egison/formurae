module Main where

import Data.List (isInfixOf)

import Formurae.FEIR.Codec (setProfileFingerprint)
import Formurae.FEIR.Syntax
import Formurae.Post.Compile
import Formurae.Post.Diagnostic (renderPostError)
import Formurae.Post.FMR (renderProgram)

main :: IO ()
main = do
  testCollocatedWholeExpression
  testPrimalToDualYee
  testDualToPrimalYee
  testMetadataErrors
  testNaturalPlacementMismatch
  putStrLn "post compile grid-whole tests: ok"

testCollocatedWholeExpression :: IO ()
testCollocatedWholeExpression = do
  let operand = Div (Pow (FieldJet sourceJet) (Exact 2 1)) (Exact 2 1)
      request = gridWholeOpaque "grid-collocated" operand 1 1 [AxisId 1]
  rendered <- compileAndRender "collocated whole derivative"
    (withUpdate fixture (FieldId 1) (OpaqueDiscrete request))
  assertContains "negative whole sample"
    "(-1 / 2) * u[i-1]**2 / 2" rendered
  assertContains "positive whole sample"
    "(1 / 2) * u[i+1]**2 / 2" rendered
  assertContains "centered whole denominator" "/ dx" rendered
  assertNotContains "whole derivative is not analytic product rule"
    "u[i]" (stepBody rendered)
  -- The ordinary profile requests accuracy four.  This discrete primitive
  -- owns its radius-one semantics and never inherits that profile.
  assertNotContains "grid-whole bypasses wide analytic profile" "u[i+2]" rendered
  assertNotContains "grid-whole marker is eliminated"
    "derivative.grid-whole" rendered
  assertNotContains "opaque marker is eliminated" "opaque" rendered

testPrimalToDualYee :: IO ()
testPrimalToDualYee = do
  let source = (scalarField (FieldId 1) "u")
        { logicalFieldPolicy = PrimalPolicy }
      target = (scalarField (FieldId 2) "v")
        { logicalFieldPolicy = DualPolicy }
      operand = Pow (FieldJet sourceJet) (Exact 2 1)
      request = gridWholeOpaque "grid-primal-dual" operand 1 1 [AxisId 1]
      program = fixture
        { feProgramFields = [source, target]
        , feProgramStepActions =
            [UpdateField (equationFor (FieldId 2) (OpaqueDiscrete request))]
        }
  rendered <- compileAndRender "primal to dual whole derivative" program
  assertContains "integer-to-half uses forward whole samples"
    "v'[i] = ((-1) * u[i]**2 + u[i+1]**2) / dx" rendered
  assertNotContains "integer-to-half does not use previous sample"
    "u[i-1]" (stepBody rendered)

testDualToPrimalYee :: IO ()
testDualToPrimalYee = do
  let source = (scalarField (FieldId 1) "u")
        { logicalFieldPolicy = DualPolicy }
      target = (scalarField (FieldId 2) "v")
        { logicalFieldPolicy = PrimalPolicy }
      operand = Pow (FieldJet sourceJet) (Exact 2 1)
      request = gridWholeOpaque "grid-dual-primal" operand 1 1 [AxisId 1]
      program = fixture
        { feProgramFields = [source, target]
        , feProgramStepActions =
            [UpdateField (equationFor (FieldId 2) (OpaqueDiscrete request))]
        }
  rendered <- compileAndRender "dual to primal whole derivative" program
  assertContains "half-to-integer uses backward whole samples"
    "v'[i] = ((-1) * u[i-1]**2 + u[i]**2) / dx" rendered
  assertNotContains "half-to-integer does not use next sample"
    "u[i+1]" (stepBody rendered)

testMetadataErrors :: IO ()
testMetadataErrors = do
  let orderTwo = gridWholeOpaque "order-two" (FieldJet sourceJet)
        2 1 [AxisId 1]
  assertGridError "v1 grid-whole order is fixed"
    (== GridWholeOrderMustBeOne 2)
    (compileProgram (withUpdate fixture (FieldId 1)
      (OpaqueDiscrete orderTwo)))

  let radiusTwo = gridWholeOpaque "radius-two" (FieldJet sourceJet)
        1 2 [AxisId 1]
      radiusProgram = withUpdate fixture (FieldId 1)
        (OpaqueDiscrete radiusTwo)
  assertGridError "v1 grid-whole radius is fixed"
    (== GridWholeRadiusMustBeOne 2)
    (compileProgram radiusProgram)
  case compileProgram radiusProgram of
    Left postError -> assertContains "grid-whole error is source-aware"
      "grid-whole.fme:1:1: grid-whole derivative radius must be 1, got 2"
      (renderPostError radiusProgram postError)
    Right _ -> fail "source-aware grid-whole error: expected Left"

  let valid = gridWholeOpaque "missing-axis" (FieldJet sourceJet)
        1 1 [AxisId 1]
      missingAxes = valid
        { opaqueDiscreteAttributes = filter
            ((/= AttributeId "ordered-axes") . attributeId)
            (opaqueDiscreteAttributes valid) }
  assertGridError "ordered axes attribute is required"
    (== GridWholeMetadataError
      (DerivativeMissingAttribute (AttributeId "ordered-axes")))
    (compileProgram (withUpdate fixture (FieldId 1)
      (OpaqueDiscrete missingAxes)))

  let manyAxes = gridWholeOpaque "many-axes" (FieldJet sourceJet)
        1 1 [AxisId 1, AxisId 1]
  assertGridError "v1 has exactly one ordered axis"
    (\gridError -> case gridError of
      GridWholeMetadataError
          (DerivativeInvalidAttribute (AttributeId "ordered-axes") _) -> True
      _ -> False)
    (compileProgram (withUpdate fixture (FieldId 1)
      (OpaqueDiscrete manyAxes)))

testNaturalPlacementMismatch :: IO ()
testNaturalPlacementMismatch = do
  let source = (scalarField (FieldId 1) "u")
        { logicalFieldPolicy = PrimalPolicy }
      wrongTarget = (scalarField (FieldId 2) "v")
        { logicalFieldPolicy = PrimalPolicy }
      request = gridWholeOpaque "bad-placement" (FieldJet sourceJet)
        1 1 [AxisId 1]
      program = fixture
        { feProgramFields = [source, wrongTarget]
        , feProgramStepActions =
            [UpdateField (equationFor (FieldId 2) (OpaqueDiscrete request))]
        }
  assertLeft "grid-whole checks natural staggered target"
    isPlacementMismatch (compileProgram program)
  where
    isPlacementMismatch (PostAtOrigin _ nested) = isPlacementMismatch nested
    isPlacementMismatch (PostInvalidReferencePlacement _ _) = True
    isPlacementMismatch _ = False

gridWholeOpaque
    :: String -> ScalarNF -> Integer -> Integer -> [AxisId] -> OpaqueDiscrete
gridWholeOpaque key operand order radius axes = OpaqueDiscreteCall
  gridWholeDerivativeOperationId
  (SemanticKey key) (RequestGroupId (key ++ "-group"))
  (Basis []) [ScalarValue operand]
  [ Attribute (AttributeId "order") (AttributeNatural (fromInteger order))
  , Attribute (AttributeId "ordered-axes")
      (AttributeValues (map AttributeAxis axes))
  , Attribute (AttributeId "radius") (AttributeNatural (fromInteger radius))
  ]

sourceJet :: FieldJet
sourceJet = FieldJetValue (FieldId 1) CurrentTime (Basis [])
  [Coordinate (AxisId 1)] []

withUpdate :: FEProgram -> FieldId -> ScalarNF -> FEProgram
withUpdate program fieldId scalar = program
  { feProgramStepActions = [UpdateField (equationFor fieldId scalar)] }

equationFor :: FieldId -> ScalarNF -> FEEquation
equationFor fieldId scalar = FEEquation (EquationId 2)
  (WholeFieldTarget fieldId NextTime)
  (scalarTensor scalar) (OriginId 1)

fixture :: FEProgram
fixture = FEProgram
  { feProgramModel = ModelIdentity (ModelId "model") "grid-whole"
      (SourceIdentity (SourceId "source") "grid-whole.fme")
  , feProgramRegistryId = RegistryId "registry"
  , feProgramPrimitiveManifestId = PrimitiveManifestId "manifest"
  , feProgramDiscretization = setProfileFingerprint
      (DiscretizationProfile
        (Fingerprint "")
        [DerivativeRule CollocatedLattice (Just (Positive 1))
          CenteredTaylor (PositiveEven 4) (OriginId 1)]
        FixedAxisOrder)
  , feProgramMode = CollocatedMode
  , feProgramDimension = 1
  , feProgramAxes = [AxisDecl (AxisId 1) "x" "x" PeriodicBoundary (OriginId 1)]
  , feProgramGeometry = GeometryDecl (GeometryId 1) Nothing Nothing
      EuclideanGeometry
  , feProgramParameters = []
  , feProgramFunctions = []
  , feProgramFields = [scalarField (FieldId 1) "u"]
  , feProgramInitializers =
      [AnalyticInitializer (FEEquation (EquationId 1)
        (WholeFieldTarget (FieldId 1) CurrentTime)
        (scalarTensor (Exact 0 1)) (OriginId 1))]
  , feProgramStepActions = []
  , feProgramRawHelpers = []
  , feProgramOrigins = OriginTable [(OriginId 1, origin)]
  , feProgramProvenance = ProvenanceTable []
  }

scalarField :: FieldId -> String -> LogicalFieldDecl
scalarField fieldId name = LogicalFieldDecl fieldId name CollocatedPolicy
  (TensorType [] [] 0) ScalarLayout [] UserStateLifetime (OriginId 1)

scalarTensor :: ScalarNF -> TensorNF
scalarTensor scalar = TensorNF [] [] 0 [(Basis [], scalar)]

origin :: SourceOrigin
origin = SourceOrigin
  (SourceLocation (SourceId "source") "grid-whole.fme" 1 1 1 1) []

compileAndRender :: String -> FEProgram -> IO String
compileAndRender label program = do
  compiled <- assertRight label (compileProgram program)
  assertRight (label ++ " render") (renderProgram compiled)

stepBody :: String -> String
stepBody rendered =
  case dropWhile (not . isPrefix "begin function") (lines rendered) of
    [] -> ""
    sections -> unlines (dropWhile (not . isStepStart) sections)
  where
    isStepStart line = "begin function" `isPrefix` line && "step(" `isInfixOf` line
    isPrefix [] _ = True
    isPrefix _ [] = False
    isPrefix (x : xs) (y : ys) = x == y && isPrefix xs ys

assertGridError
    :: String
    -> (GridWholeDerivativeError -> Bool)
    -> Either PostError value
    -> IO ()
assertGridError label predicate = assertLeft label match
  where
    match (PostAtOrigin _ nested) = match nested
    match (PostGridWholeDerivativeError _ gridError) = predicate gridError
    match _ = False

assertRight :: String -> Either a b -> IO b
assertRight _ (Right value) = pure value
assertRight label (Left _) = fail (label ++ ": expected Right")

assertLeft :: Show a => String -> (a -> Bool) -> Either a b -> IO ()
assertLeft label predicate result =
  case result of
    Left err | predicate err -> pure ()
    Left err -> fail (label ++ ": unexpected error " ++ show err)
    Right _ -> fail (label ++ ": expected Left")

assertContains :: String -> String -> String -> IO ()
assertContains label needle haystack
  | needle `isInfixOf` haystack = pure ()
  | otherwise = fail
      (label ++ ": missing " ++ show needle ++ " in:\n" ++ haystack)

assertNotContains :: String -> String -> String -> IO ()
assertNotContains label needle haystack
  | needle `isInfixOf` haystack = fail
      (label ++ ": unexpectedly found " ++ show needle ++ " in:\n" ++ haystack)
  | otherwise = pure ()
