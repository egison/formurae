module Main where

import Formurae.FEIR.Codec (setProfileFingerprint)
import Formurae.FEIR.Syntax
import Formurae.Post.Compile
import Formurae.Post.FMR (FProgram, renderProgram)

main :: IO ()
main = do
  compiled <- assertRight "compile algebraic FEIR" (compileProgram fixture)
  rendered <- assertRight "render algebraic FMR" (renderProgram compiled)
  assertContains "initializer" "u[i] = exp(dx * i)" rendered
  assertContains "field reference" "u'[i] = a + u[i]" rendered
  assertContains "parameter" "double :: a = 2.0" rendered
  assertContains "external function" "extern function :: exp" rendered
  assertContains "surface-declared intrinsic survives normalization"
    "extern function :: sin" rendered
  assertNotContains "unused internal intrinsic is not declared"
    "extern function :: pow" rendered
  piCompiled <- assertRight "compile named pi" (compileProgram piFixture)
  piRendered <- assertRight "render named pi" (renderProgram piCompiled)
  assertContains "named pi lowers only at the FMR boundary"
    "19 * (884279719003555 / 281474976710656) / 24" piRendered
  testPlacementMismatch
  testCenteredDerivativeProfiles
  testYeeOrientations
  putStrLn "post compile tests: ok"

testPlacementMismatch :: IO ()
testPlacementMismatch = do
  let primalField = (headField (feProgramFields fixture))
        { logicalFieldPolicy = PrimalPolicy }
      dualTarget = primalField
        { logicalFieldId = FieldId 2
        , logicalFieldSourceName = "v"
        , logicalFieldPolicy = DualPolicy
        }
      rhs = scalarTensor (FieldJet (jet (FieldId 1)))
      equation = FEEquation (EquationId 2)
        (WholeFieldTarget (FieldId 2) NextTime) rhs (OriginId 1)
      program = fixture
        { feProgramFields = [primalField, dualTarget]
        , feProgramStepActions = [UpdateField equation]
        }
  assertLeft "placement mismatch" isMismatch (compileProgram program)
  where
    isMismatch (PostAtOrigin _ nested) = isMismatch nested
    isMismatch (PostInvalidReferencePlacement _ _) = True
    isMismatch _ = False

testCenteredDerivativeProfiles :: IO ()
testCenteredDerivativeProfiles = do
  standard <- compileDerivativeProgram [] CollocatedPolicy CollocatedPolicy 2
  standardText <- renderCompiled "standard derivative" standard
  assertContains "standard left point" "u[i-1]" standardText
  assertContains "standard right point" "u[i+1]" standardText
  assertNotContains "standard has no wide point" "u[i-2]" standardText

  let orderTwoAccuracyFour =
        [DerivativeRule CollocatedLattice (Just (Positive 2)) CenteredTaylor
          (PositiveEven 4) (OriginId 1)]
  highOrder <- compileDerivativeProgram orderTwoAccuracyFour
    CollocatedPolicy CollocatedPolicy 2
  highOrderText <- renderCompiled "fourth-order derivative" highOrder
  assertContains "fourth-order left halo" "u[i-2]" highOrderText
  assertContains "fourth-order right halo" "u[i+2]" highOrderText
  assertNotContains "direct compact second derivative has no radius four" "u[i-4]" highOrderText

testYeeOrientations :: IO ()
testYeeOrientations = do
  primalToDual <- compileDerivativeProgram [] PrimalPolicy DualPolicy 1
  primalText <- renderCompiled "primal to dual" primalToDual
  assertContains "integer-to-half uses forward source" "u[i+1]" primalText
  assertContains "integer-to-half uses current source" "u[i]" primalText
  assertNotContains "integer-to-half does not use previous source" "u[i-1]" primalText

  dualToPrimal <- compileDerivativeProgram [] DualPolicy PrimalPolicy 1
  dualText <- renderCompiled "dual to primal" dualToPrimal
  assertContains "half-to-integer uses previous source" "u[i-1]" dualText
  assertContains "half-to-integer uses current source" "u[i]" dualText
  assertNotContains "half-to-integer does not use next source" "u[i+1]" dualText

compileDerivativeProgram
    :: [DerivativeRule]
    -> GridPolicy
    -> GridPolicy
    -> Int
    -> IO FProgram
compileDerivativeProgram rules sourcePolicy targetPolicy derivativeOrder = do
  let sourceField = scalarField
        { logicalFieldPolicy = sourcePolicy }
      targetField = scalarField
        { logicalFieldId = FieldId 2
        , logicalFieldSourceName = "v"
        , logicalFieldPolicy = targetPolicy
        }
      derivativeJet = (jet (FieldId 1))
        { fieldJetMultiIndex = [(AxisId 1, fromIntegral derivativeOrder)] }
      equation = FEEquation (EquationId 3)
        (WholeFieldTarget (FieldId 2) NextTime)
        (scalarTensor (FieldJet derivativeJet)) (OriginId 1)
      configuredProfile = setProfileFingerprint
        (profile { discretizationDerivativeRules = rules })
      program = fixture
        { feProgramDiscretization = configuredProfile
        , feProgramFields = [sourceField, targetField]
        , feProgramInitializers = []
        , feProgramStepActions = [UpdateField equation]
        }
  assertRight "compile derivative" (compileProgram program)

renderCompiled :: String -> FProgram -> IO String
renderCompiled label program = assertRight label (renderProgram program)

fixture :: FEProgram
fixture = FEProgram
  { feProgramVersion = 1
  , feProgramModel = ModelIdentity (ModelId "model-1") "algebraic"
      (SourceIdentity (SourceId "source-1") "algebraic.fme")
  , feProgramRegistryId = RegistryId "registry-1"
  , feProgramPrimitiveManifestId = PrimitiveManifestId "manifest-1"
  , feProgramDiscretization = setProfileFingerprint profile
  , feProgramMode = CollocatedMode
  , feProgramDimension = 1
  , feProgramAxes = [AxisDecl (AxisId 1) "x" "x" (OriginId 1)]
  , feProgramGeometry = GeometryDecl (GeometryId 1) Nothing Nothing EuclideanGeometry
  , feProgramParameters = [ParameterDecl (ParamId 1) "a" "a" "2.0" (OriginId 1)]
  , feProgramFunctions =
      [ FunctionDecl (FunctionId 1) "exp" "exp" (Just 1)
          IntrinsicFunction (Just (OriginId 1))
      , FunctionDecl (FunctionId 2) "sin" "sin" (Just 1)
          IntrinsicFunction (Just (OriginId 1))
      , FunctionDecl (FunctionId 3) "pow" "pow" (Just 2)
          IntrinsicFunction Nothing
      ]
  , feProgramFields = [scalarField]
  , feProgramInitializers =
      [ AnalyticInitializer (FEEquation (EquationId 1)
          (WholeFieldTarget (FieldId 1) CurrentTime)
          (scalarTensor (AnalyticCall (FunctionId 1) [Coordinate (AxisId 1)]))
          (OriginId 1))
      ]
  , feProgramStepActions =
      [ UpdateField (FEEquation (EquationId 2)
          (WholeFieldTarget (FieldId 1) NextTime)
          (scalarTensor (Add [Parameter (ParamId 1), FieldJet (jet (FieldId 1))]))
          (OriginId 1))
      ]
  , feProgramRawHelpers = []
  , feProgramOrigins = OriginTable [(OriginId 1, origin)]
  , feProgramProvenance = ProvenanceTable []
  }

piFixture :: FEProgram
piFixture = fixture
  { feProgramInitializers =
      [ AnalyticInitializer (FEEquation (EquationId 1)
          (WholeFieldTarget (FieldId 1) CurrentTime)
          (scalarTensor
            (Div (Mul [Exact 19 1, NamedConstant Pi]) (Exact 24 1)))
          (OriginId 1))
      ]
  }

profile :: DiscretizationProfile
profile = DiscretizationProfile
  (VersionedProfileId "formurae-discretization@1")
  (Fingerprint "") [] FixedAxisOrder

scalarField :: LogicalFieldDecl
scalarField = LogicalFieldDecl (FieldId 1) "u" CollocatedPolicy
  (TensorType [] [] 0) ScalarLayout [] UserStateLifetime (OriginId 1)

jet :: FieldId -> FieldJet
jet fieldId = FieldJetValue fieldId CurrentTime (Basis [])
  [Coordinate (AxisId 1)] []

scalarTensor :: ScalarNF -> TensorNF
scalarTensor value = TensorNF [] [] 0 [(Basis [], value)]

origin :: SourceOrigin
origin = SourceOrigin
  (SourceLocation (SourceId "source-1") "algebraic.fme" 1 1 1 1) []

headField :: [LogicalFieldDecl] -> LogicalFieldDecl
headField (field : _) = field
headField [] = error "missing fixture field"

assertRight :: String -> Either a b -> IO b
assertRight _ (Right value) = pure value
assertRight label (Left _) = fail (label ++ ": expected Right")

assertLeft :: String -> (a -> Bool) -> Either a b -> IO ()
assertLeft label predicate result =
  case result of
    Left err | predicate err -> pure ()
    Left _ -> fail (label ++ ": unexpected error")
    Right _ -> fail (label ++ ": expected Left")

assertContains :: String -> String -> String -> IO ()
assertContains label needle haystack
  | contains needle haystack = pure ()
  | otherwise = fail (label ++ ": missing " ++ show needle ++ " in " ++ show haystack)

assertNotContains :: String -> String -> String -> IO ()
assertNotContains label needle haystack
  | contains needle haystack = fail
      (label ++ ": unexpectedly found " ++ show needle ++ " in " ++ show haystack)
  | otherwise = pure ()

contains :: Eq a => [a] -> [a] -> Bool
contains [] _ = True
contains _ [] = False
contains needle haystack@(_ : rest) = prefix needle haystack || contains needle rest
  where
    prefix [] _ = True
    prefix _ [] = False
    prefix (x : xs) (y : ys) = x == y && prefix xs ys
