module Main where

import Data.List (isInfixOf)

import Formurae.FEIR.Codec (setProfileFingerprint)
import Formurae.FEIR.Syntax
import Formurae.Post.Compile
import Formurae.Post.FMR (renderProgram)

main :: IO ()
main = do
  testDualToPrimalClosures
  testPrimalToDualInterior
  testSecondDerivativeClosures
  testRejections
  putStrLn "post compile sbp tests: ok"

-- The dual-to-primal direction replaces the first and last primal rows
-- with the summation-by-parts closure rows behind index guards.
testDualToPrimalClosures :: IO ()
testDualToPrimalClosures = do
  rendered <- compileAndRender "dual-to-primal SBP derivative"
    (sbpProgram DualPolicy PrimalPolicy 1)
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
    (sbpProgram PrimalPolicy DualPolicy 1)
  assertContains "closure-free forward sample" "u[i+1]" rendered
  assertNotContains "no boundary guard is emitted" "if" rendered

testSecondDerivativeClosures :: IO ()
testSecondDerivativeClosures = do
  rendered <- compileAndRender "second SBP derivative"
    (sbpProgram PrimalPolicy PrimalPolicy 2)
  assertContains "low boundary guard" "if i == 0 then" rendered
  assertContains "one-sided outer sample" "u[i+2]" rendered
  assertContains "interior compact sample" "(-2) * u[i]" rendered
  assertContains "second derivative denominator" "/ dx**2" rendered

testRejections :: IO ()
testRejections = do
  assertSbpError "second derivative of a half-placed operand"
    isHalfPlacement
    (compileProgram (sbpProgram DualPolicy DualPolicy 2))
  assertSbpError "collocated operands have no SBP pair"
    (== SbpRequiresStaggeredLattice)
    (compileProgram (sbpProgram CollocatedPolicy CollocatedPolicy 1))
  assertSbpError "order above two"
    (== SbpOrderUnsupported 3)
    (compileProgram (sbpProgram DualPolicy PrimalPolicy 3))
  where
    isHalfPlacement (SbpSecondOrderNeedsIntegerPlacement _) = True
    isHalfPlacement _ = False

sbpProgram :: GridPolicy -> GridPolicy -> Integer -> FEProgram
sbpProgram sourcePolicy targetPolicy order =
  let source = (scalarField (FieldId 1) "u")
        { logicalFieldPolicy = sourcePolicy }
      target = (scalarField (FieldId 2) "v")
        { logicalFieldPolicy = targetPolicy }
      request = OpaqueDiscreteCall sbpStaggeredOperationId
        (SemanticKey "sbp") (RequestGroupId "sbp-group")
        (Basis []) [ScalarValue (FieldJet sourceJet)]
        [ Attribute (AttributeId "order")
            (AttributeNatural (fromInteger order))
        , Attribute (AttributeId "ordered-axes")
            (AttributeValues [AttributeAxis (AxisId 1)])
        , Attribute (AttributeId "radius") (AttributeNatural 1)
        ]
      equation = FEEquation (EquationId 2)
        (WholeFieldTarget (FieldId 2) NextTime)
        (scalarTensor (OpaqueDiscrete request)) (OriginId 1)
  in fixture
       { feProgramFields = [source, target]
       , feProgramStepActions = [UpdateField equation]
       }

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
  , feProgramAxes = [AxisDecl (AxisId 1) "x" "x" (OriginId 1)]
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
