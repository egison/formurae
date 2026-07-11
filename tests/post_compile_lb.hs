module Main where

import Data.List (isInfixOf, tails)

import Formurae.FEIR.Codec (setProfileFingerprint)
import Formurae.FEIR.Syntax
import Formurae.Post.BackendPlan (lbOperationId)
import Formurae.Post.Compile
import Formurae.Post.FMR (renderProgram)

main :: IO ()
main = do
  testRenderedLb
  testVariableMetricSampling
  testSemanticDeduplication
  testDistinctBundles
  testStepLocalDependencyOrdering
  testLbConsumerMaterializationOrdering
  putStrLn "post compile lb tests: ok"

testRenderedLb :: IO ()
testRenderedLb = do
  rendered <- compileAndRender "render lb" fixture
  assertContains "persistent geometry state"
    "begin function (u,FormuraeInternalMetricCoefficient1,FormuraeInternalMetricCoefficient2,FormuraeInternalMetricVolume) = init()"
    rendered
  assertContains "first exact coefficient initializer"
    "FormuraeInternalMetricCoefficient1[i,j] = (3 / 2)" rendered
  assertContains "second exact coefficient initializer"
    "FormuraeInternalMetricCoefficient2[i,j] = (2 / 3)" rendered
  assertContains "volume initializer"
    "FormuraeInternalMetricVolume[i,j] = 6" rendered

  assertContains "cell-to-face x gradient uses forward pair"
    "FormuraeInternalLb1Flux1[i,j] = FormuraeInternalMetricCoefficient1[i,j] * (u[i+1,j] + (-1) * u[i,j]) / dx"
    rendered
  assertContains "cell-to-face y gradient uses forward pair"
    "FormuraeInternalLb1Flux2[i,j] = FormuraeInternalMetricCoefficient2[i,j] * (u[i,j+1] + (-1) * u[i,j]) / dy"
    rendered
  assertContains "face-to-cell divergence uses stored flux"
    "FormuraeInternalLb1Result[i,j] = ((FormuraeInternalLb1Flux1[i,j] + (-1) * FormuraeInternalLb1Flux1[i-1,j]) / dx + (FormuraeInternalLb1Flux2[i,j] + (-1) * FormuraeInternalLb1Flux2[i,j-1]) / dy) / FormuraeInternalMetricVolume[i,j]"
    rendered
  assertContains "opaque expression replaced by result grid"
    "u'[i,j] = FormuraeInternalLb1Result[i,j]" rendered

  assertBefore "flux before result"
    "FormuraeInternalLb1Flux1[i,j] =" "FormuraeInternalLb1Result[i,j] =" rendered
  assertBefore "result before user update"
    "FormuraeInternalLb1Result[i,j] =" "u'[i,j] =" rendered
  assertBefore "user update before metric carry"
    "u'[i,j] =" "FormuraeInternalMetricCoefficient1'[i,j] =" rendered
  assertContains "coefficient carry-forward"
    "FormuraeInternalMetricCoefficient1'[i,j] = FormuraeInternalMetricCoefficient1[i,j]"
    rendered
  assertContains "volume carry-forward"
    "FormuraeInternalMetricVolume'[i,j] = FormuraeInternalMetricVolume[i,j]"
    rendered
  assertNotContains "no opaque op marker" "lb.orthogonal" rendered
  assertNotContains "no opaque IR marker" "opaque" rendered
  -- The profile requests a wide analytic first derivative.  lb@v1 bypasses
  -- it and retains its explicit two-point conservative Yee gradient.
  assertNotContains "lb bypasses profile: no positive radius two" "u[i+2,j]" rendered
  assertNotContains "lb bypasses profile: no negative radius two" "u[i-2,j]" rendered

testVariableMetricSampling :: IO ()
testVariableMetricSampling = do
  let h2 = Add [Exact 2 1, Coordinate (AxisId 2)]
      scales = [(AxisId 1, Exact 1 1), (AxisId 2, h2)]
      normalForm = GeometryNF identityTensor inverseTensor scales h2 True
      geometry = (feProgramGeometry fixture)
        { geometryDeclKind = OrthogonalScaleGeometry scales normalForm }
      program = fixture { feProgramGeometry = geometry }
  rendered <- compileAndRender "sample variable metric" program
  assertContains "volume is sampled at the cell"
    "FormuraeInternalMetricVolume[i,j] = 2 + dy * j" rendered
  assertContains "face coefficient samples y at y plus one half"
    "FormuraeInternalMetricCoefficient2[i,j] = (2 + dy * ((1 / 2) + j)) / (2 + dy * ((1 / 2) + j))**2"
    rendered

testSemanticDeduplication :: IO ()
testSemanticDeduplication = do
  let opaque = lbOpaque (FieldId 1) (SemanticKey "same-key")
        (RequestGroupId "same-group")
      program = fixture
        { feProgramStepActions =
            [UpdateField (stepEquation (Add
              [OpaqueDiscrete opaque, OpaqueDiscrete opaque]))]
        }
  rendered <- compileAndRender "deduplicated lb" program
  assertEqual "one materialized flux bundle" 1
    (countOccurrences "FormuraeInternalLb1Flux1[i,j] =" rendered)
  assertNotContains "dedup does not allocate second bundle"
    "FormuraeInternalLb2Flux1" rendered
  assertContains "both uses normalize to coefficient two"
    "u'[i,j] = 2 * FormuraeInternalLb1Result[i,j]" rendered

testDistinctBundles :: IO ()
testDistinctBundles = do
  let v = scalarField (FieldId 2) "v"
      expression = Add
        [ OpaqueDiscrete (lbOpaque (FieldId 1)
            (SemanticKey "u-key") (RequestGroupId "u-group"))
        , OpaqueDiscrete (lbOpaque (FieldId 2)
            (SemanticKey "v-key") (RequestGroupId "v-group"))
        ]
      program = fixture
        { feProgramFields = [scalarField (FieldId 1) "u", v]
        , feProgramInitializers =
            [ analyticInitializer 1 (FieldId 1) (Exact 0 1)
            , analyticInitializer 2 (FieldId 2) (Exact 1 1)
            ]
        , feProgramStepActions = [UpdateField (stepEquation expression)]
        }
  rendered <- compileAndRender "distinct lb bundles" program
  assertContains "first source flux" "FormuraeInternalLb1Flux1[i,j] =" rendered
  assertContains "second source flux" "FormuraeInternalLb2Flux1[i,j] =" rendered
  assertContains "second flux reads second source"
    "FormuraeInternalLb2Flux1[i,j] = FormuraeInternalMetricCoefficient1[i,j] * (v[i+1,j] + (-1) * v[i,j]) / dx"
    rendered
  assertContains "distinct results both reach update"
    "u'[i,j] = FormuraeInternalLb1Result[i,j] + FormuraeInternalLb2Result[i,j]"
    rendered
  assertEqual "geometry coefficient is shared" 1
    (countOccurrences "FormuraeInternalMetricCoefficient1[i,j] =" rendered)
  assertBefore "all second bundle effects precede update"
    "FormuraeInternalLb2Result[i,j] =" "u'[i,j] =" rendered

testStepLocalDependencyOrdering :: IO ()
testStepLocalDependencyOrdering = do
  let local = (scalarField (FieldId 2) "q")
        { logicalFieldLifetime = StepLocalLifetime }
      localSource = ScalarValue (FieldJet (fieldJet (FieldId 1)))
      localLb = lbOpaque (FieldId 2)
        (SemanticKey "q-key") (RequestGroupId "q-group")
      program = fixture
        { feProgramFields = [scalarField (FieldId 1) "u", local]
        , feProgramStepActions =
            [ Materialize (FieldId 2) localSource (OriginId 1)
            , UpdateField (stepEquation (OpaqueDiscrete localLb))
            ]
        }
  rendered <- compileAndRender "step-local lb source" program
  assertContains "step local is materialized" "q[i,j] = u[i,j]" rendered
  assertContains "lb reads the materialized local"
    "FormuraeInternalLb1Flux1[i,j] = FormuraeInternalMetricCoefficient1[i,j] * (q[i+1,j] + (-1) * q[i,j]) / dx"
    rendered
  assertBefore "local dependency before flux" "q[i,j] =" "FormuraeInternalLb1Flux1[i,j] ="
    rendered
  assertBefore "local lb result before update"
    "FormuraeInternalLb1Result[i,j] =" "u'[i,j] =" rendered

testLbConsumerMaterializationOrdering :: IO ()
testLbConsumerMaterializationOrdering = do
  let local = (scalarField (FieldId 2) "q")
        { logicalFieldLifetime = StepLocalLifetime }
      program = fixture
        { feProgramFields = [scalarField (FieldId 1) "u", local]
        , feProgramStepActions =
            [ Materialize (FieldId 2)
                (ScalarValue (OpaqueDiscrete defaultLbOpaque)) (OriginId 1)
            , UpdateField (stepEquation (FieldJet (fieldJet (FieldId 2))))
            ]
        }
  rendered <- compileAndRender "lb materialization consumer" program
  assertContains "materialized consumer reads result"
    "q[i,j] = FormuraeInternalLb1Result[i,j]" rendered
  assertBefore "effect before its materialized consumer"
    "FormuraeInternalLb1Result[i,j] =" "q[i,j] =" rendered
  assertBefore "materialized consumer before update" "q[i,j] =" "u'[i,j] = q[i,j]" rendered

compileAndRender :: String -> FEProgram -> IO String
compileAndRender label program = do
  compiled <- assertRight label (compileProgram program)
  assertRight (label ++ " render") (renderProgram compiled)

fixture :: FEProgram
fixture = FEProgram
  { feProgramVersion = 1
  , feProgramModel = ModelIdentity (ModelId "model") "lb"
      (SourceIdentity (SourceId "source") "lb.fme")
  , feProgramRegistryId = RegistryId "registry"
  , feProgramPrimitiveManifestId = PrimitiveManifestId "manifest"
  , feProgramDiscretization = setProfileFingerprint
      (DiscretizationProfile
        (VersionedProfileId "formurae-discretization@1")
        (Fingerprint "")
        [DerivativeRule CollocatedLattice (Just (Positive 1))
          CenteredTaylor (PositiveEven 4) (OriginId 1)]
        FixedAxisOrder)
  , feProgramMode = CollocatedMode
  , feProgramDimension = 2
  , feProgramAxes =
      [ AxisDecl (AxisId 1) "x" "x" (OriginId 1)
      , AxisDecl (AxisId 2) "y" "y" (OriginId 1)
      ]
  , feProgramGeometry = orthogonalGeometry
  , feProgramParameters = []
  , feProgramFunctions = []
  , feProgramFields = [scalarField (FieldId 1) "u"]
  , feProgramInitializers =
      [analyticInitializer 1 (FieldId 1) (Exact 0 1)]
  , feProgramStepActions =
      [UpdateField (stepEquation (OpaqueDiscrete defaultLbOpaque))]
  , feProgramRawHelpers = []
  , feProgramOrigins = OriginTable [(OriginId 1, origin)]
  , feProgramProvenance = ProvenanceTable []
  }

orthogonalGeometry :: GeometryDecl
orthogonalGeometry = GeometryDecl (GeometryId 1) (Just "g")
  (Just (OriginId 1))
  (OrthogonalScaleGeometry scales geometryNF)
  where
    scales = [(AxisId 1, Exact 2 1), (AxisId 2, Exact 3 1)]
    geometryNF = GeometryNF identityTensor inverseTensor scales
      (Exact 6 1) True

identityTensor :: TensorNF
identityTensor = TensorNF [2, 2] [VarianceDown, VarianceDown] 0
  [ (Basis [1, 1], Exact 4 1)
  , (Basis [1, 2], Exact 0 1)
  , (Basis [2, 1], Exact 0 1)
  , (Basis [2, 2], Exact 9 1)
  ]

inverseTensor :: TensorNF
inverseTensor = TensorNF [2, 2] [VarianceUp, VarianceUp] 0
  [ (Basis [1, 1], Exact 1 4)
  , (Basis [1, 2], Exact 0 1)
  , (Basis [2, 1], Exact 0 1)
  , (Basis [2, 2], Exact 1 9)
  ]

scalarField :: FieldId -> String -> LogicalFieldDecl
scalarField fieldId name = LogicalFieldDecl fieldId name CollocatedPolicy
  (TensorType [] [] 0) ScalarLayout [] UserStateLifetime (OriginId 1)

fieldJet :: FieldId -> FieldJet
fieldJet fieldId = FieldJetValue fieldId CurrentTime (Basis [])
  [Coordinate (AxisId 1), Coordinate (AxisId 2)] []

defaultLbOpaque :: OpaqueDiscrete
defaultLbOpaque = lbOpaque (FieldId 1)
  (SemanticKey "lb-u-key") (RequestGroupId "lb-u")

lbOpaque :: FieldId -> SemanticKey -> RequestGroupId -> OpaqueDiscrete
lbOpaque fieldId key group = OpaqueDiscreteCall
  lbOperationId key group (Basis [])
  [ScalarValue (FieldJet (fieldJet fieldId))]
  [ Attribute (AttributeId "metric") (AttributeGeometry (GeometryId 1))
  , Attribute (AttributeId "source-policy")
      (AttributeGridPolicy CollocatedPolicy)
  ]

stepEquation :: ScalarNF -> FEEquation
stepEquation scalar = FEEquation (EquationId 3)
  (WholeFieldTarget (FieldId 1) NextTime)
  (scalarTensor scalar) (OriginId 1)

analyticInitializer :: Int -> FieldId -> ScalarNF -> FEInitializer
analyticInitializer equationNumber fieldId scalar =
  AnalyticInitializer (FEEquation (EquationId equationNumber)
    (WholeFieldTarget fieldId CurrentTime)
    (scalarTensor scalar) (OriginId 1))

scalarTensor :: ScalarNF -> TensorNF
scalarTensor scalar = TensorNF [] [] 0 [(Basis [], scalar)]

origin :: SourceOrigin
origin = SourceOrigin
  (SourceLocation (SourceId "source") "lb.fme" 1 1 1 1) []

assertRight :: String -> Either a b -> IO b
assertRight _ (Right value) = pure value
assertRight label (Left _) = fail (label ++ ": expected Right")

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

assertBefore :: String -> String -> String -> String -> IO ()
assertBefore label first second source =
  case (firstIndex first source, firstIndex second source) of
    (Just left, Just right) | left < right -> pure ()
    _ -> fail (label ++ ": expected " ++ show first ++ " before "
      ++ show second ++ " in:\n" ++ source)

firstIndex :: String -> String -> Maybe Int
firstIndex needle source =
  case [index | (index, suffix) <- zip [0 ..] (tails source)
              , needle `isPrefix` suffix] of
    value : _ -> Just value
    [] -> Nothing
  where
    isPrefix [] _ = True
    isPrefix _ [] = False
    isPrefix (x : xs) (y : ys) = x == y && isPrefix xs ys

countOccurrences :: String -> String -> Int
countOccurrences needle source = length
  [() | suffix <- tails source, needle `isPrefix` suffix]
  where
    isPrefix [] _ = True
    isPrefix _ [] = False
    isPrefix (x : xs) (y : ys) = x == y && isPrefix xs ys

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
