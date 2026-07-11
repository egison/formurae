module Main where

import Data.List (isInfixOf)

import Formurae.FEIR.Codec (setProfileFingerprint)
import Formurae.FEIR.Syntax
import Formurae.Post.BackendPlan
import Formurae.Post.Compile
import Formurae.Post.FMR (renderProgram)

main :: IO ()
main = do
  testPrimalWeightedAdjoint
  testCollocatedWeightedAdjoint
  testDegreeTwoSignsAndPlacement
  testRequestDeduplication
  testContractErrors
  putStrLn "post compile metric codifferential tests: ok"

testPrimalWeightedAdjoint :: IO ()
testPrimalWeightedAdjoint = do
  plan <- assertRight "primal metric codifferential plan"
    (planBackendEffects primalFixture)
  assertEqual "volume and three placement-aware Hodge coefficients persist"
    4 (length (backendGeometryInitializers plan))
  assertEqual "one codifferential request group"
    1 (length (backendMetricCodifferentialRequests plan))
  assertEqual "two weighted fluxes precede one component result"
    [ MetricCodifferentialFluxRole
        (RequestGroupId "metric-codiff") (Basis []) (AxisId 1)
    , MetricCodifferentialFluxRole
        (RequestGroupId "metric-codiff") (Basis []) (AxisId 2)
    , MetricCodifferentialResultRole
        (RequestGroupId "metric-codiff") (Basis [])
    ]
    (map auxiliaryFieldRole (backendStepSchedule plan))
  rendered <- compileAndRender "primal metric codifferential" primalFixture
  assertContains "axis-one source uses half-to-integer Yee placement"
    "A_1[i-1,j]" rendered
  assertContains "axis-two source uses half-to-integer Yee placement"
    "A_2[i,j-1]" rendered
  assertContains "inner metric coefficient field is initialized at its half placement"
    "(1 / 2) + i" rendered
  assertContains "negative half-cell sample uses the preceding coefficient cell"
    "FormuraeInternalHodgeCoefficientB1PHI[i-1,j]" rendered
  assertContains "positive half-cell sample uses the current coefficient cell"
    "FormuraeInternalHodgeCoefficientB1PHI[i,j]" rendered
  assertContains "outer Hodge coefficient is materialized at the scalar target"
    "FormuraeInternalHodgeCoefficientB1_2PII[i,j]" rendered
  assertContains "weighted derivative is materialized before its result"
    "FormuraeInternalCodiff1BScalarFlux1[i,j] =" rendered
  assertContains "request result is materialized before the user update"
    "FormuraeInternalCodiff1BScalarResult[i,j] =" rendered
  assertContains "both weighted derivatives use their coordinate steps"
    "/ dx" rendered
  assertContains "axis-two derivative step" "/ dy" rendered
  assertNotContains "opaque codifferential is fully lowered"
    "codiff.metric" rendered
  assertNotContains "opaque marker is fully lowered" "opaque" rendered

testDegreeTwoSignsAndPlacement :: IO ()
testDegreeTwoSignsAndPlacement = do
  rendered <- compileAndRender "degree-two metric codifferential"
    degreeTwoFixture
  assertContains "first one-form component differentiates along axis two"
    "FormuraeInternalCodiff1B1Flux2[i,j] =" rendered
  assertContains "second one-form component differentiates along axis one"
    "FormuraeInternalCodiff1B2Flux1[i,j] =" rendered
  assertContains "basis-one result has positive composed orientation"
    "FormuraeInternalCodiff1B1Result[i,j] = FormuraeInternalCodiff1B1Flux2[i,j] * FormuraeInternalHodgeCoefficientB2PHI"
    rendered
  assertContains "basis-two result has negative composed orientation"
    "FormuraeInternalCodiff1B2Result[i,j] = (-1) * FormuraeInternalCodiff1B2Flux1[i,j] * FormuraeInternalHodgeCoefficientB1PIH"
    rendered
  assertContains "basis-one consumer reads its own placed result"
    "R_1'[i,j] = FormuraeInternalCodiff1B1Result[i,j]" rendered
  assertContains "basis-two consumer reads its own placed result"
    "R_2'[i,j] = FormuraeInternalCodiff1B2Result[i,j]" rendered

testRequestDeduplication :: IO ()
testRequestDeduplication = do
  let repeated = primalFixture
        { feProgramStepActions =
            [UpdateField updateEquation
              { feEquationRhs = TensorNF [] [] 0
                  [(Basis [], Add
                    [OpaqueDiscrete defaultOpaque, OpaqueDiscrete defaultOpaque])]
              }]
        }
  plan <- assertRight "deduplicated codifferential plan"
    (planBackendEffects repeated)
  assertEqual "same semantic request has one group"
    1 (length (backendMetricCodifferentialRequests plan))
  rendered <- compileAndRender "deduplicated codifferential" repeated
  assertEqual "weighted axis-one flux is emitted once"
    1 (occurrences "FormuraeInternalCodiff1BScalarFlux1[i,j] =" rendered)

testCollocatedWeightedAdjoint :: IO ()
testCollocatedWeightedAdjoint = do
  let collocatedA = formField (FieldId 1) "A" CollocatedPolicy
      collocatedD = scalarFormField (FieldId 2) "D" CollocatedPolicy
      program = primalFixture
        { feProgramFields = [collocatedA, collocatedD] }
  rendered <- compileAndRender "collocated metric codifferential" program
  assertContains "collocated x derivative is centered"
    "A_1[i-1,j]" rendered
  assertContains "collocated x derivative has positive sample"
    "A_1[i+1,j]" rendered
  assertContains "collocated coefficient follows the negative shifted product"
    "FormuraeInternalHodgeCoefficientB1PII[i-1,j]" rendered
  assertContains "collocated coefficient follows the positive shifted product"
    "FormuraeInternalHodgeCoefficientB1PII[i+1,j]" rendered

testContractErrors :: IO ()
testContractErrors = do
  let badDimension = defaultOpaque
        { opaqueDiscreteAttributes =
            [ Attribute (AttributeId "dimension") (AttributeNatural 3)
            , Attribute (AttributeId "metric")
                (AttributeGeometry (GeometryId 1))
            , Attribute (AttributeId "source-degree") (AttributeNatural 1)
            ] }
  assertMetricError "dimension mismatch"
    (compileProgram (withOpaque primalFixture badDimension))

  let euclidean = primalFixture
        { feProgramGeometry = GeometryDecl (GeometryId 1) Nothing Nothing
            EuclideanGeometry }
  assertMetricError "variable geometry is required"
    (compileProgram euclidean)

  let mixedOperand = sourceTensor
        { tensorNFComponents =
            [ (Basis [1], FieldJet (sourceJet (FieldId 1) (Basis [1])))
            , (Basis [2], FieldJet (sourceJet (FieldId 3) (Basis [2])))
            ] }
      mixedOpaque = defaultOpaque
        { opaqueDiscreteOperands = [TensorValue mixedOperand] }
      mixed = (withOpaque primalFixture mixedOpaque)
        { feProgramFields =
            [ formField (FieldId 1) "A" PrimalPolicy
            , scalarFormField (FieldId 2) "D" PrimalPolicy
            , formField (FieldId 3) "B" DualPolicy
            ] }
  assertMetricError "mixed source policies are rejected" (compileProgram mixed)

primalFixture :: FEProgram
primalFixture = FEProgram
  { feProgramVersion = 1
  , feProgramModel = ModelIdentity (ModelId "model") "metric-codiff"
      (SourceIdentity (SourceId "source") "metric-codiff.fme")
  , feProgramRegistryId = RegistryId "registry"
  , feProgramPrimitiveManifestId = PrimitiveManifestId "manifest"
  , feProgramDiscretization = setProfileFingerprint
      (DiscretizationProfile
        (VersionedProfileId "formurae-discretization@1")
        (Fingerprint "") [] FixedAxisOrder)
  , feProgramMode = DecMode
  , feProgramDimension = 2
  , feProgramAxes =
      [ AxisDecl (AxisId 1) "x" "x" (OriginId 1)
      , AxisDecl (AxisId 2) "y" "y" (OriginId 1)
      ]
  , feProgramGeometry = orthogonalGeometry
  , feProgramParameters = []
  , feProgramFunctions = []
  , feProgramFields =
      [ formField (FieldId 1) "A" PrimalPolicy
      , scalarFormField (FieldId 2) "D" PrimalPolicy
      ]
  , feProgramInitializers = []
  , feProgramStepActions = [UpdateField updateEquation]
  , feProgramRawHelpers = []
  , feProgramOrigins = OriginTable [(OriginId 1, origin)]
  , feProgramProvenance = ProvenanceTable []
  }

degreeTwoFixture :: FEProgram
degreeTwoFixture = primalFixture
  { feProgramFields =
      [ twoFormField (FieldId 1) "Q" PrimalPolicy
      , formField (FieldId 2) "R" PrimalPolicy
      ]
  , feProgramStepActions = [UpdateField degreeTwoEquation]
  }

degreeTwoEquation :: FEEquation
degreeTwoEquation = FEEquation (EquationId 2)
  (WholeFieldTarget (FieldId 2) NextTime)
  (TensorNF [2] [VarianceDown] 1
    [ (Basis [1], OpaqueDiscrete (degreeTwoOpaque "degree-two-1" (Basis [1])))
    , (Basis [2], OpaqueDiscrete (degreeTwoOpaque "degree-two-2" (Basis [2])))
    ])
  (OriginId 1)

degreeTwoOpaque :: String -> Basis -> OpaqueDiscrete
degreeTwoOpaque key resultBasis = OpaqueDiscreteCall
  metricCodifferentialOperationId
  (SemanticKey key) (RequestGroupId "degree-two") resultBasis
  [TensorValue degreeTwoSource]
  [ Attribute (AttributeId "dimension") (AttributeNatural 2)
  , Attribute (AttributeId "metric") (AttributeGeometry (GeometryId 1))
  , Attribute (AttributeId "source-degree") (AttributeNatural 2)
  ]

degreeTwoSource :: TensorNF
degreeTwoSource = TensorNF [2, 2] [VarianceDown, VarianceDown] 2
  [ (Basis [1, 1], Exact 0 1)
  , (Basis [1, 2], FieldJet
      (sourceJet (FieldId 1) (Basis [1, 2])))
  , (Basis [2, 1], Mul
      [ Exact (-1) 1
      , FieldJet (sourceJet (FieldId 1) (Basis [1, 2]))
      ])
  , (Basis [2, 2], Exact 0 1)
  ]

orthogonalGeometry :: GeometryDecl
orthogonalGeometry = GeometryDecl (GeometryId 1) (Just "g")
  (Just (OriginId 1)) (OrthogonalScaleGeometry scales normalForm)
  where
    h1 = Add [Exact 1 1, Coordinate (AxisId 1)]
    h2 = Exact 2 1
    volume = Mul [Exact 2 1, h1]
    scales = [(AxisId 1, h1), (AxisId 2, h2)]
    normalForm = GeometryNF metric inverse scales volume True
    metric = TensorNF [2, 2] [VarianceDown, VarianceDown] 0
      [ (Basis [1, 1], Pow h1 (Exact 2 1))
      , (Basis [1, 2], Exact 0 1)
      , (Basis [2, 1], Exact 0 1)
      , (Basis [2, 2], Exact 4 1)
      ]
    inverse = TensorNF [2, 2] [VarianceUp, VarianceUp] 0
      [ (Basis [1, 1], Div (Exact 1 1) (Pow h1 (Exact 2 1)))
      , (Basis [1, 2], Exact 0 1)
      , (Basis [2, 1], Exact 0 1)
      , (Basis [2, 2], Exact 1 4)
      ]

updateEquation :: FEEquation
updateEquation = FEEquation (EquationId 1)
  (WholeFieldTarget (FieldId 2) NextTime)
  (TensorNF [] [] 0 [(Basis [], OpaqueDiscrete defaultOpaque)])
  (OriginId 1)

defaultOpaque :: OpaqueDiscrete
defaultOpaque = OpaqueDiscreteCall
  metricCodifferentialOperationId
  (SemanticKey "metric-codiff-scalar")
  (RequestGroupId "metric-codiff")
  (Basis [])
  [TensorValue sourceTensor]
  [ Attribute (AttributeId "dimension") (AttributeNatural 2)
  , Attribute (AttributeId "metric") (AttributeGeometry (GeometryId 1))
  , Attribute (AttributeId "source-degree") (AttributeNatural 1)
  ]

sourceTensor :: TensorNF
sourceTensor = TensorNF [2] [VarianceDown] 1
  [ (Basis [1], FieldJet (sourceJet (FieldId 1) (Basis [1])))
  , (Basis [2], FieldJet (sourceJet (FieldId 1) (Basis [2])))
  ]

sourceJet :: FieldId -> Basis -> FieldJet
sourceJet field basis = FieldJetValue field CurrentTime basis
  [Coordinate (AxisId 1), Coordinate (AxisId 2)] []

formField :: FieldId -> String -> GridPolicy -> LogicalFieldDecl
formField identifier name policy = LogicalFieldDecl identifier name policy
  (TensorType [2] [VarianceDown] 1) FormLayout [Nothing]
  UserStateLifetime (OriginId 1)

twoFormField :: FieldId -> String -> GridPolicy -> LogicalFieldDecl
twoFormField identifier name policy = LogicalFieldDecl identifier name policy
  (TensorType [2, 2] [VarianceDown, VarianceDown] 2) FormLayout
  [Nothing, Nothing] UserStateLifetime (OriginId 1)

scalarFormField :: FieldId -> String -> GridPolicy -> LogicalFieldDecl
scalarFormField identifier name policy = LogicalFieldDecl identifier name policy
  (TensorType [] [] 0) FormLayout [] UserStateLifetime (OriginId 1)

withOpaque :: FEProgram -> OpaqueDiscrete -> FEProgram
withOpaque program opaque = program
  { feProgramStepActions =
      [UpdateField updateEquation
        { feEquationRhs = TensorNF [] [] 0
            [(Basis [], OpaqueDiscrete opaque)] }]
  }

origin :: SourceOrigin
origin = SourceOrigin
  (SourceLocation (SourceId "source") "metric-codiff.fme" 1 1 1 1) []

compileAndRender :: String -> FEProgram -> IO String
compileAndRender label program = do
  compiled <- assertRight label (compileProgram program)
  assertRight (label ++ " render") (renderProgram compiled)

assertMetricError :: String -> Either PostError value -> IO ()
assertMetricError label result =
  case result of
    Left (PostAtOrigin _ nested) -> assertMetricError label (Left nested)
    Left (PostMetricCodifferentialError _ _) -> pure ()
    Left (PostBackendPlanError (MetricCodifferentialPlanError _ _)) -> pure ()
    Left err -> fail (label ++ ": unexpected error " ++ show err)
    Right _ -> fail (label ++ ": expected metric codifferential error")

assertRight :: Show a => String -> Either a b -> IO b
assertRight _ (Right value) = pure value
assertRight label (Left err) = fail (label ++ ": " ++ show err)

assertContains :: String -> String -> String -> IO ()
assertContains label needle haystack
  | needle `isInfixOf` haystack = pure ()
  | otherwise = fail (label ++ ": missing " ++ show needle ++ " in:\n" ++ haystack)

assertNotContains :: String -> String -> String -> IO ()
assertNotContains label needle haystack
  | needle `isInfixOf` haystack =
      fail (label ++ ": unexpectedly found " ++ show needle ++ " in:\n" ++ haystack)
  | otherwise = pure ()

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)

occurrences :: String -> String -> Int
occurrences needle = length . filter (prefix needle) . tails
  where
    tails [] = [[]]
    tails value@(_ : rest) = value : tails rest
    prefix [] _ = True
    prefix _ [] = False
    prefix (x : xs) (y : ys) = x == y && prefix xs ys
