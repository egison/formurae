module Main where

import Data.List (isInfixOf)

import Formurae.FEIR.Codec (setProfileFingerprint)
import qualified Formurae.FEIR.PrimitiveBindings as Primitives
import Formurae.FEIR.Syntax
import Formurae.Post.Compile
import Formurae.Post.FMR (renderProgram)

-- The boundary treatment is an axis property: these fixtures declare
-- boundary x : sbp and exercise the ordinary derivative requests, whose
-- rows nearest the walls become the summation-by-parts closure rows.
main :: IO ()
main = do
  testDualToPrimalClosures
  testPrimalToDualInterior
  testSecondDerivativeClosures
  testMixedBoundaryAxes
  testWideRadiusClosures
  testProfileJetClosures
  testBoundaryTrace
  testRejections
  putStrLn "post compile sbp tests: ok"

-- The boundary trace extrapolates a dual-placed operand to the walls with
-- the pair's boundary vector and is zero elsewhere; it is only meaningful
-- on a declared sbp axis.
testBoundaryTrace :: IO ()
testBoundaryTrace = do
  rendered <- compileAndRender "sbp boundary trace"
    (derivativeProgram DualPolicy PrimalPolicy (traceOpaque "sbp" 1))
  assertContains "low wall guard" "if i == 0 then" rendered
  assertContains "low extrapolation weights" "(3 / 2) * u[i]" rendered
  assertContains "high wall guard"
    "if i == (-1) + total_grid_x then" rendered
  assertContains "high extrapolation sample" "u[i-2]" rendered
  assertContains "zero interior" "else 0" rendered
  assertSbpError "the trace needs a declared sbp axis"
    (== SbpTraceRequiresSbpAxis (AxisId 1))
    (compileProgram (withPeriodicAxis
      (derivativeProgram DualPolicy PrimalPolicy (traceOpaque "sbp" 1))))
  assertSbpError "the trace needs a dual-placed operand"
    isIntegerPlacement
    (compileProgram (derivativeProgram PrimalPolicy DualPolicy
      (traceOpaque "sbp" 1)))
  assertSbpError "only the minimal-pair extrapolation exists"
    (== SbpTraceUnsupportedRadius 2)
    (compileProgram (derivativeProgram DualPolicy PrimalPolicy
      (traceOpaque "sbp" 2)))
  where
    isIntegerPlacement (SbpTraceNeedsHalfPlacement _) = True
    isIntegerPlacement _ = False

withPeriodicAxis :: FEProgram -> FEProgram
withPeriodicAxis program = program
  { feProgramAxes =
      [AxisDecl (AxisId 1) "x" "x" PeriodicBoundary (OriginId 1)]
  }

-- The dual-to-primal direction replaces the first and last primal rows
-- with the summation-by-parts closure rows behind index guards.
testDualToPrimalClosures :: IO ()
testDualToPrimalClosures = do
  rendered <- compileAndRender "dual-to-primal SBP derivative"
    (derivativeProgram DualPolicy PrimalPolicy (gridWholeOpaque "sbp"))
  assertContains "low boundary guard" "if i == 0 then" rendered
  assertContains "low closure forward sample" "u[i+1]" rendered
  assertContains "high boundary guard"
    "if i == (-1) + total_grid_x then" rendered
  assertContains "high closure backward sample" "u[i-2]" rendered
  assertContains "interior Yee pair sample" "u[i-1]" rendered
  assertContains "first derivative denominator" "/ dx" rendered

testPrimalToDualInterior :: IO ()
testPrimalToDualInterior = do
  rendered <- compileAndRender "primal-to-dual SBP derivative"
    (derivativeProgram PrimalPolicy DualPolicy (gridWholeOpaque "sbp"))
  assertContains "closure-free forward sample" "u[i+1]" rendered
  assertNotContains "no boundary guard is emitted" "if" rendered

testSecondDerivativeClosures :: IO ()
testSecondDerivativeClosures = do
  rendered <- compileAndRender "second SBP derivative"
    (derivativeProgram PrimalPolicy PrimalPolicy (wideOpaque "sbp" 2 1))
  assertContains "low boundary guard" "if i == 0 then" rendered
  assertContains "one-sided outer sample" "u[i+2]" rendered
  assertContains "interior compact sample" "(-2) * u[i]" rendered
  assertContains "second derivative denominator" "/ dx**2" rendered

-- Boundaries are per axis: in a 2D model with x = sbp and y = periodic the
-- x factor closes while the y factor keeps the ordinary periodic stencil.
testMixedBoundaryAxes :: IO ()
testMixedBoundaryAxes = do
  rendered <- compileAndRender "mixed sbp/periodic axes"
    mixedBoundaryProgram
  assertContains "x closure guard" "if i == 0 then" rendered
  assertContains "x one-sided outer sample" "u[i+2,j]" rendered
  assertNotContains "periodic y axis has no guard" "if j" rendered
  assertContains "periodic y interior sample" "u[i,j+1]" rendered

-- A wide first derivative closes at every radius: the pair constructor
-- supplies the closure rows for that interior width.  The dual-placed
-- target grid ends one storage slot early (its final half point sits
-- outside the domain), so the high guards of the primal-to-dual direction
-- start at total_grid − 2.
testWideRadiusClosures :: IO ()
testWideRadiusClosures = do
  dualToPrimal <- compileAndRender "radius-two dual-to-primal derivative"
    (derivativeProgram DualPolicy PrimalPolicy (wideOpaque "sbp" 1 2))
  assertContains "one-sided first row" "if i == 0 then" dualToPrimal
  assertContains "outermost detached row" "if i == 3 then" dualToPrimal
  assertContains "one-sided outer sample" "u[i+2]" dualToPrimal
  assertContains "wide interior sample" "u[i-2]" dualToPrimal
  primalToDual <- compileAndRender "radius-two primal-to-dual derivative"
    (derivativeProgram PrimalPolicy DualPolicy (wideOpaque "sbp" 1 2))
  assertContains "primal-to-dual closure guard" "if i == 2 then" primalToDual
  assertContains "dual-placed high guard starts one slot early"
    "if i == (-2) + total_grid_x then" primalToDual
  assertNotContains "the out-of-domain half slot is never guarded"
    "(-1) + total_grid_x" primalToDual

-- Profile-driven field jets share the closure construction at every
-- accuracy: the pair count is the accuracy half.  Only orders above two
-- stay a static error until their closures exist.
testProfileJetClosures :: IO ()
testProfileJetClosures = do
  firstOrder <- compileAndRender "profile dual-to-primal jet"
    (jetProgram DualPolicy PrimalPolicy 1)
  assertContains "jet low boundary guard" "if i == 0 then" firstOrder
  assertContains "jet high boundary guard"
    "if i == (-1) + total_grid_x then" firstOrder
  assertContains "jet closure forward sample" "u[i+1]" firstOrder
  secondOrder <- compileAndRender "profile second-derivative jet"
    (jetProgram PrimalPolicy PrimalPolicy 2)
  assertContains "jet second closure outer sample" "u[i+2]" secondOrder
  assertContains "jet second denominator" "/ dx**2" secondOrder
  wideFirst <- compileAndRender "accuracy-four dual-to-primal jet"
    (withAccuracyFourProfile (jetProgram DualPolicy PrimalPolicy 1))
  assertContains "accuracy-four detached closure row" "if i == 3 then"
    wideFirst
  assertContains "accuracy-four interior sample" "u[i-2]" wideFirst
  wideSecond <- compileAndRender "accuracy-four second-derivative jet"
    (withAccuracyFourProfile (jetProgram PrimalPolicy PrimalPolicy 2))
  assertContains "accuracy-four second closure depth" "if i == 4 then"
    wideSecond
  assertContains "accuracy-four composed interior sample" "u[i+3]"
    wideSecond
  assertContains "accuracy-four second denominator" "/ dx**2" wideSecond
  assertSbpError "third-order jets have no closure yet"
    (== SbpProfileClosureUnavailable 3 2)
    (compileProgram (jetProgram PrimalPolicy DualPolicy 3))

testRejections :: IO ()
testRejections = do
  assertSbpError "second derivative of a half-placed operand"
    isHalfPlacement
    (compileProgram (derivativeProgram DualPolicy DualPolicy
      (wideOpaque "sbp" 2 1)))
  assertSbpError "collocated operands have no SBP pair"
    (== SbpRequiresStaggeredLattice)
    (compileProgram (derivativeProgram CollocatedPolicy CollocatedPolicy
      (gridWholeOpaque "sbp")))
  assertSbpError "prime-ring second derivative has no closure yet"
    (== SbpClosureUnavailable 2 2)
    (compileProgram (derivativeProgram PrimalPolicy PrimalPolicy
      (wideOpaque "sbp" 2 2)))
  assertSbpError "third derivative has no closure yet"
    (== SbpClosureUnavailable 3 2)
    (compileProgram (derivativeProgram PrimalPolicy DualPolicy
      (wideOpaque "sbp" 3 2)))
  assertSbpError "ordered chains cannot cross an sbp axis"
    (== SbpOrderedChainUnsupported (AxisId 1))
    (compileProgram (derivativeProgram PrimalPolicy DualPolicy
      (orderedOpaque "sbp" [AxisId 1])))
  assertSbpError "resampling toward integer points reads outside"
    (== SbpResampleUnsupported (AxisId 1))
    (compileProgram (derivativeProgram DualPolicy PrimalPolicy
      (resampleOpaque "sbp" [False])))
  _ <- compileAndRender "resampling toward half points stays admissible"
    (derivativeProgram PrimalPolicy DualPolicy (resampleOpaque "sbp" [True]))
  pure ()
  where
    isHalfPlacement (SbpSecondOrderNeedsIntegerPlacement _) = True
    isHalfPlacement _ = False

derivativeProgram
    :: GridPolicy -> GridPolicy -> (ScalarNF -> OpaqueDiscrete) -> FEProgram
derivativeProgram sourcePolicy targetPolicy request =
  let source = (scalarField (FieldId 1) "u")
        { logicalFieldPolicy = sourcePolicy }
      target = (scalarField (FieldId 2) "v")
        { logicalFieldPolicy = targetPolicy }
      equation = FEEquation (EquationId 2)
        (WholeFieldTarget (FieldId 2) NextTime)
        (scalarTensor (OpaqueDiscrete (request (FieldJet sourceJet))))
        (OriginId 1)
  in fixture
       { feProgramFields = [source, target]
       , feProgramStepActions = [UpdateField equation]
       }

jetProgram :: GridPolicy -> GridPolicy -> Integer -> FEProgram
jetProgram sourcePolicy targetPolicy order =
  let source = (scalarField (FieldId 1) "u")
        { logicalFieldPolicy = sourcePolicy }
      target = (scalarField (FieldId 2) "v")
        { logicalFieldPolicy = targetPolicy }
      jet = sourceJet
        { fieldJetMultiIndex = [(AxisId 1, fromInteger order)] }
      equation = FEEquation (EquationId 2)
        (WholeFieldTarget (FieldId 2) NextTime)
        (scalarTensor (FieldJet jet)) (OriginId 1)
  in fixture
       { feProgramFields = [source, target]
       , feProgramStepActions = [UpdateField equation]
       }

withAccuracyFourProfile :: FEProgram -> FEProgram
withAccuracyFourProfile program = program
  { feProgramDiscretization = setProfileFingerprint
      (DiscretizationProfile (Fingerprint "")
        [DerivativeRule StaggeredLattice Nothing Yee
          (PositiveEven 4) (OriginId 1)]
        FixedAxisOrder)
  }

mixedBoundaryProgram :: FEProgram
mixedBoundaryProgram =
  let source = (scalarField2d (FieldId 1) "u")
        { logicalFieldPolicy = PrimalPolicy }
      jet = FieldJetValue (FieldId 1) CurrentTime (Basis []) [] []
      rhs = Add
        [ OpaqueDiscrete (wideOpaque2d "sbp-x" (AxisId 1) (FieldJet jet))
        , OpaqueDiscrete (wideOpaque2d "per-y" (AxisId 2) (FieldJet jet))
        ]
      equation = FEEquation (EquationId 1)
        (WholeFieldTarget (FieldId 1) NextTime)
        (scalarTensor rhs) (OriginId 1)
  in fixture
       { feProgramDimension = 2
       , feProgramAxes =
           [ AxisDecl (AxisId 1) "x" "x" SbpBoundary (OriginId 1)
           , AxisDecl (AxisId 2) "y" "y" PeriodicBoundary (OriginId 1)
           ]
       , feProgramFields = [source]
       , feProgramStepActions = [UpdateField equation]
       }

gridWholeOpaque :: String -> ScalarNF -> OpaqueDiscrete
gridWholeOpaque key operand = OpaqueDiscreteCall
  Primitives.derivativeGridWholeOpId
  (SemanticKey key) (RequestGroupId (key ++ "-group"))
  (Basis []) [ScalarValue operand]
  (derivativeAttributes (AxisId 1) 1 1)

wideOpaque :: String -> Integer -> Integer -> ScalarNF -> OpaqueDiscrete
wideOpaque key order radius operand = OpaqueDiscreteCall
  Primitives.derivativeCoordinateWideOpId
  (SemanticKey key) (RequestGroupId (key ++ "-group"))
  (Basis []) [ScalarValue operand]
  (derivativeAttributes (AxisId 1) order radius)

wideOpaque2d :: String -> AxisId -> ScalarNF -> OpaqueDiscrete
wideOpaque2d key axis operand = OpaqueDiscreteCall
  Primitives.derivativeCoordinateWideOpId
  (SemanticKey key) (RequestGroupId (key ++ "-group"))
  (Basis []) [ScalarValue operand]
  (derivativeAttributes axis 2 1)

orderedOpaque :: String -> [AxisId] -> ScalarNF -> OpaqueDiscrete
orderedOpaque key axes operand = OpaqueDiscreteCall
  Primitives.derivativeOrderedOpId
  (SemanticKey key) (RequestGroupId (key ++ "-group"))
  (Basis []) [ScalarValue operand]
  [ Attribute (AttributeId "order")
      (AttributeNatural (fromIntegral (length axes)))
  , Attribute (AttributeId "ordered-axes")
      (AttributeValues (map AttributeAxis axes))
  , Attribute (AttributeId "radius") (AttributeNatural 1)
  ]

traceOpaque :: String -> Integer -> ScalarNF -> OpaqueDiscrete
traceOpaque key radius operand = OpaqueDiscreteCall
  Primitives.boundarySbpTraceOpId
  (SemanticKey key) (RequestGroupId (key ++ "-group"))
  (Basis []) [ScalarValue operand]
  [ Attribute (AttributeId "ordered-axes")
      (AttributeValues [AttributeAxis (AxisId 1)])
  , Attribute (AttributeId "radius")
      (AttributeNatural (fromInteger radius))
  ]

resampleOpaque :: String -> [Bool] -> ScalarNF -> OpaqueDiscrete
resampleOpaque key bits operand = OpaqueDiscreteCall
  Primitives.resampleExplicitOpId
  (SemanticKey key) (RequestGroupId (key ++ "-group"))
  (Basis []) [ScalarValue operand]
  [Attribute (AttributeId "target-placement")
    (AttributeValues (map AttributeBoolean bits))]

derivativeAttributes :: AxisId -> Integer -> Integer -> [Attribute]
derivativeAttributes axis order radius =
  [ Attribute (AttributeId "order")
      (AttributeNatural (fromInteger order))
  , Attribute (AttributeId "ordered-axes")
      (AttributeValues [AttributeAxis axis])
  , Attribute (AttributeId "radius")
      (AttributeNatural (fromInteger radius))
  ]

sourceJet :: FieldJet
sourceJet = FieldJetValue (FieldId 1) CurrentTime (Basis []) [] []

fixture :: FEProgram
fixture = FEProgram
  { feProgramModel = ModelIdentity (ModelId "model") "sbp"
      (SourceIdentity (SourceId "source") "sbp.fme")
  , feProgramRegistryId = RegistryId "registry"
  , feProgramPrimitiveManifestId = PrimitiveManifestId "manifest"
  , feProgramDiscretization = setProfileFingerprint
      (DiscretizationProfile (Fingerprint "") [] FixedAxisOrder)
  , feProgramMode = CollocatedMode
  , feProgramDimension = 1
  , feProgramAxes = [AxisDecl (AxisId 1) "x" "x" SbpBoundary (OriginId 1)]
  , feProgramGeometry = GeometryDecl (GeometryId 1) Nothing Nothing
      EuclideanGeometry
  , feProgramParameters = []
  , feProgramFunctions = []
  , feProgramFields = []
  , feProgramInitializers = []
  , feProgramStepActions = []
  , feProgramRawHelpers = []
  , feProgramOrigins = OriginTable [(OriginId 1, origin)]
  , feProgramProvenance = ProvenanceTable []
  }

scalarField :: FieldId -> String -> LogicalFieldDecl
scalarField fieldId name = LogicalFieldDecl fieldId name CollocatedPolicy
  (TensorType [] [] 0) ScalarLayout [] UserStateLifetime (OriginId 1)

scalarField2d :: FieldId -> String -> LogicalFieldDecl
scalarField2d = scalarField

scalarTensor :: ScalarNF -> TensorNF
scalarTensor scalar = TensorNF [] [] 0 [(Basis [], scalar)]

origin :: SourceOrigin
origin = SourceOrigin
  (SourceLocation (SourceId "source") "sbp.fme" 1 1 1 1) []

compileAndRender :: String -> FEProgram -> IO String
compileAndRender label program = do
  compiled <- assertRight label (compileProgram program)
  assertRight (label ++ " render") (renderProgram compiled)

assertSbpError
    :: String
    -> (SbpDerivativeError -> Bool)
    -> Either PostError value
    -> IO ()
assertSbpError label predicate = assertLeft label match
  where
    match (PostAtOrigin _ nested) = match nested
    match (PostSbpDerivativeError _ sbpError) = predicate sbpError
    match (PostSbpProfileError sbpError) = predicate sbpError
    match _ = False

assertRight :: Show a => String -> Either a b -> IO b
assertRight _ (Right value) = pure value
assertRight label (Left err) =
  fail (label ++ ": expected Right, got " ++ show err)

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
