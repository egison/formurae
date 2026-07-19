module Main where

import Data.List (isInfixOf)

import Formurae.FEIR.Codec (setProfileFingerprint)
import Formurae.FEIR.Syntax
import Formurae.Post.Compile
import Formurae.Post.FMR (renderProgram)

main :: IO ()
main = do
  testSecondDerivativeRadiusTwo
  testWholeNonlinearExpressionShift
  testAttributeErrors
  testAxisErrors
  testStaggeredOddHalfRadius
  putStrLn "post compile wide tests: ok"

testSecondDerivativeRadiusTwo :: IO ()
testSecondDerivativeRadiusTwo = do
  -- At (order=2, profile-accuracy=2, radius=2) the moment system is
  -- underdetermined.  The opaque contract does not inherit that profile: it
  -- derives maximal accuracy 4 for this explicit radius, making the exact
  -- five-point system unique.
  let request = wideOpaque "wide-second" (FieldJet sourceJet) 2 2 [AxisId 1]
  rendered <- compileAndRender "wide second derivative"
    (withUpdate fixture (OpaqueDiscrete request))
  assertContains "negative radius-two coefficient"
    "(-1 / 12) * u[i-2]" rendered
  assertContains "negative radius-one coefficient"
    "(4 / 3) * u[i-1]" rendered
  assertContains "center coefficient" "(-5 / 2) * u[i]" rendered
  assertContains "positive radius-one coefficient"
    "(4 / 3) * u[i+1]" rendered
  assertContains "positive radius-two coefficient"
    "(-1 / 12) * u[i+2]" rendered
  assertContains "second derivative denominator" "/ dx**2" rendered
  -- The model profile asks for the ordinary compact 3-point second
  -- derivative.  The explicit request retains radius two and maximal order.
  assertContains "explicit radius bypasses model profile" "u[i+2]" rendered
  assertNotContains "opaque operation marker is fully lowered"
    "derivative.coordinate-wide" rendered
  assertNotContains "opaque IR marker is fully lowered" "opaque" rendered

testWholeNonlinearExpressionShift :: IO ()
testWholeNonlinearExpressionShift = do
  let operand = Pow
        (Add [FieldJet sourceJet, Coordinate (AxisId 1)])
        (Exact 2 1)
      request = wideOpaque "wide-nonlinear" operand 1 1 [AxisId 1]
  rendered <- compileAndRender "whole nonlinear wide derivative"
    (withUpdate fixture (OpaqueDiscrete request))
  assertContains "negative sample shifts grid reference"
    "u[i-1]" rendered
  assertContains "positive sample shifts grid reference"
    "u[i+1]" rendered
  assertContains "negative sample shifts coordinate"
    "dx * ((-1) + i)" rendered
  assertContains "positive sample shifts coordinate"
    "dx * (1 + i)" rendered
  assertContains "whole nonlinear sample is squared before differencing"
    "**2" rendered

testAttributeErrors :: IO ()
testAttributeErrors = do
  let base = wideOpaque "bad" (FieldJet sourceJet) 2 2 [AxisId 1]
      missingRadius = base
        { opaqueDiscreteAttributes = filter
            ((/= AttributeId "radius") . attributeId)
            (opaqueDiscreteAttributes base) }
  assertWideError "missing radius"
    (== WideMetadataError
      (DerivativeMissingAttribute (AttributeId "radius")))
    (compileProgram (withUpdate fixture (OpaqueDiscrete missingRadius)))

  let orderAttribute = Attribute (AttributeId "order") (AttributeNatural 2)
      duplicateOrder = base
        { opaqueDiscreteAttributes = orderAttribute
            : opaqueDiscreteAttributes base }
  assertWideError "non-unique duplicate order attribute"
    (== WideMetadataError
      (DerivativeDuplicateAttribute (AttributeId "order")))
    (compileProgram (withUpdate fixture (OpaqueDiscrete duplicateOrder)))

  let multipleAxes = wideOpaque "many-axes" (FieldJet sourceJet)
        2 2 [AxisId 1, AxisId 1]
  assertWideError "v1 requires exactly one ordered axis"
    (\wideError -> case wideError of
      WideMetadataError
          (DerivativeInvalidAttribute (AttributeId "ordered-axes") _) -> True
      _ -> False)
    (compileProgram (withUpdate fixture (OpaqueDiscrete multipleAxes)))

  let impossibleOrder = wideOpaque "large-order" (FieldJet sourceJet)
        3 1 [AxisId 1]
  assertWideError "order exceeds stencil diameter"
    (== WideOrderExceedsDiameter 3 1)
    (compileProgram (withUpdate fixture (OpaqueDiscrete impossibleOrder)))

testAxisErrors :: IO ()
testAxisErrors = do
  let unknownAxis = wideOpaque "unknown-axis" (FieldJet sourceJet)
        2 2 [AxisId 99]
  assertLeft "unknown axis has no fallback step name"
    isUnknownAxis
    (compileProgram (withUpdate fixture (OpaqueDiscrete unknownAxis)))
  where
    isUnknownAxis (PostAtOrigin _ nested) = isUnknownAxis nested
    isUnknownAxis (PostUnknownAxis (AxisId 99)) = True
    isUnknownAxis _ = False

-- Odd orders on a staggered lattice land on the toggled sub-lattice, so the
-- attribute radius r selects the half-offset stencil of effective radius
-- r − 1/2 around the natural target: the pair orientation follows the
-- operand's placement bit exactly as for the Yee pair.
testStaggeredOddHalfRadius :: IO ()
testStaggeredOddHalfRadius = do
  integerToHalf <- compileAndRender "integer-to-half fourth-order Yee"
    (staggeredOddProgram PrimalPolicy DualPolicy)
  assertContains "backward outer sample" "(1 / 24) * u[i-1]" integerToHalf
  assertContains "backward inner sample" "(-9 / 8) * u[i]" integerToHalf
  assertContains "forward inner sample" "(9 / 8) * u[i+1]" integerToHalf
  assertContains "forward outer sample" "(-1 / 24) * u[i+2]" integerToHalf
  assertContains "first derivative denominator" "/ dx" integerToHalf

  halfToInteger <- compileAndRender "half-to-integer fourth-order Yee"
    (staggeredOddProgram DualPolicy PrimalPolicy)
  assertContains "mirrored backward outer sample"
    "(1 / 24) * u[i-2]" halfToInteger
  assertContains "mirrored backward inner sample"
    "(-9 / 8) * u[i-1]" halfToInteger
  assertContains "mirrored forward inner sample"
    "(9 / 8) * u[i]" halfToInteger
  assertContains "mirrored forward outer sample"
    "(-1 / 24) * u[i+1]" halfToInteger

staggeredOddProgram :: GridPolicy -> GridPolicy -> FEProgram
staggeredOddProgram sourcePolicy targetPolicy =
  let source = (scalarField (FieldId 1) "u")
        { logicalFieldPolicy = sourcePolicy }
      target = (scalarField (FieldId 2) "v")
        { logicalFieldPolicy = targetPolicy }
      oddRequest = wideOpaque "staggered-odd" (FieldJet sourceJet)
        1 2 [AxisId 1]
      equation = FEEquation (EquationId 2)
        (WholeFieldTarget (FieldId 2) NextTime)
        (scalarTensor (OpaqueDiscrete oddRequest)) (OriginId 1)
  in fixture
       { feProgramFields = [source, target]
       , feProgramStepActions = [UpdateField equation]
       }

wideOpaque
    :: String -> ScalarNF -> Integer -> Integer -> [AxisId] -> OpaqueDiscrete
wideOpaque key operand order radius axes = OpaqueDiscreteCall
  wideDerivativeOperationId (SemanticKey key) (RequestGroupId (key ++ "-group"))
  (Basis []) [ScalarValue operand]
  [ Attribute (AttributeId "order") (AttributeNatural (fromInteger order))
  , Attribute (AttributeId "ordered-axes")
      (AttributeValues (map AttributeAxis axes))
  , Attribute (AttributeId "radius") (AttributeNatural (fromInteger radius))
  ]

sourceJet :: FieldJet
sourceJet = FieldJetValue (FieldId 1) CurrentTime (Basis [])
  [Coordinate (AxisId 1)] []

withUpdate :: FEProgram -> ScalarNF -> FEProgram
withUpdate program scalar = program
  { feProgramStepActions =
      [UpdateField (FEEquation (EquationId 2)
        (WholeFieldTarget (FieldId 1) NextTime)
        (scalarTensor scalar) (OriginId 1))]
  }

fixture :: FEProgram
fixture = FEProgram
  { feProgramModel = ModelIdentity (ModelId "model") "wide"
      (SourceIdentity (SourceId "source") "wide.fme")
  , feProgramRegistryId = RegistryId "registry"
  , feProgramPrimitiveManifestId = PrimitiveManifestId "manifest"
  , feProgramDiscretization = setProfileFingerprint
      (DiscretizationProfile
        (Fingerprint "")
        [DerivativeRule CollocatedLattice (Just (Positive 2))
          CenteredTaylor (PositiveEven 2) (OriginId 1)]
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
  (SourceLocation (SourceId "source") "wide.fme" 1 1 1 1) []

compileAndRender :: String -> FEProgram -> IO String
compileAndRender label program = do
  compiled <- assertRight label (compileProgram program)
  assertRight (label ++ " render") (renderProgram compiled)

assertWideError
    :: String
    -> (WideDerivativeError -> Bool)
    -> Either PostError value
    -> IO ()
assertWideError label predicate = assertLeft label match
  where
    match (PostAtOrigin _ nested) = match nested
    match (PostWideDerivativeError _ wideError) = predicate wideError
    match _ = False

assertRight :: String -> Either a b -> IO b
assertRight _ (Right value) = pure value
assertRight label (Left _) = fail (label ++ ": expected Right")

assertLeft :: (Show a) => String -> (a -> Bool) -> Either a b -> IO ()
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
