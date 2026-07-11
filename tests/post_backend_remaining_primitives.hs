module Main where

import Data.List (nub)

import Formurae.FEIR.Codec (setProfileFingerprint)
import qualified Formurae.FEIR.PrimitiveBindings as Primitives
import Formurae.FEIR.Syntax
import Formurae.Post.BackendPlan
import Formurae.Post.Compile (PostError(..), compileProgram)
import Formurae.Post.Diagnostic (renderPostError)
import Formurae.Post.Location

main :: IO ()
main = do
  testPlansAndDeduplication
  testInitializerRejection
  testFluxPlacementRejection
  testMaterializedPlacementRejection
  putStrLn "post backend remaining primitive tests: ok"

testPlansAndDeduplication :: IO ()
testPlansAndDeduplication = do
  let material1 = materialized "material-1" (Basis [1]) fluxTensor
      material2 = materialized "material-2" (Basis [2]) fluxTensor
      conservative = conservativeFlux "conservative" fluxTensor
      expression = Add
        [ OpaqueDiscrete material1
        , OpaqueDiscrete material1
        , OpaqueDiscrete material2
        , OpaqueDiscrete conservative
        ]
      program = withStep fixture expression
  plan <- assertRight "remaining backend plan" (planBackendEffects program)
  assertEqual "one conservative request" 1
    (length (backendConservativeDivergenceRequests plan))
  conservativePlan <- only "conservative request"
    (backendConservativeDivergenceRequests plan)
  assertEqual "one materialized face flux per axis" 2
    (length (conservativeDivergenceFluxFields conservativePlan))
  assertEqual "conservative flux placements"
    [ Placement [HalfPoint, IntegerPoint]
    , Placement [IntegerPoint, HalfPoint]
    ]
    (map auxiliaryFieldPlacement
      (conservativeDivergenceFluxFields conservativePlan))
  assertEqual "conservative result is cell-located"
    (Placement [IntegerPoint, IntegerPoint])
    (auxiliaryFieldPlacement
      (conservativeDivergenceResultField conservativePlan))

  assertEqual "one tensor materialization request group" 1
    (length (backendMaterializedRequests plan))
  materialPlan <- only "materialized request"
    (backendMaterializedRequests plan)
  let components = materializedRequestComponents materialPlan
  assertEqual "tensor materialization plans every component" 2
    (length components)
  assertEqual "tensor component placements are preserved"
    [ Placement [HalfPoint, IntegerPoint]
    , Placement [IntegerPoint, HalfPoint]
    ]
    (map (auxiliaryFieldPlacement . materializedComponentField) components)
  assertEqual "duplicate semantic occurrence is deduplicated" 2
    (length (nub (concatMap materializedComponentSemanticKeys components)))
  assertEqual "all effect auxiliaries are step-local" [StepAuxiliary]
    (nub (map auxiliaryFieldLifetime (backendStepSchedule plan)))
  assertEqual "all three opaque results have planned storage" 3
    (length (backendOpaqueResults plan))

testInitializerRejection :: IO ()
testInitializerRejection = do
  let request = conservativeFlux "initializer-flux" fluxTensor
      equation = FEEquation (EquationId 1)
        (WholeFieldTarget (FieldId 1) CurrentTime)
        (scalarTensor (OpaqueDiscrete request)) (OriginId 1)
      program = fixture
        { feProgramInitializers = [AnalyticInitializer equation] }
  assertLeft "effectful request in initializer"
    isInitializerError (planBackendEffects program)
  where
    isInitializerError (EffectfulRequestInInitializer operation _ _) =
      operation == Primitives.fluxConservativeDivergenceV1OpId
    isInitializerError _ = False

testFluxPlacementRejection :: IO ()
testFluxPlacementRejection = do
  let collocatedFlux = TensorNF [2] [VarianceDown] 0
        [ (Basis [axis], FieldJet (fieldJet (FieldId 3) (Basis [axis])))
        | axis <- [1, 2]
        ]
      request = conservativeFlux "bad-flux" collocatedFlux
      program = withStep fixture (OpaqueDiscrete request)
  assertLeft "flux components must already be on Primal faces"
    isExplicitError (planBackendEffects program)
  case compileProgram program of
    Left postError@(PostBackendPlanError (ExplicitPrimitivePlanError {})) ->
      assertContains "flux planning diagnostic retains the source origin"
        "remaining.fme:1:1: explicit primitive plan error"
        (renderPostError program postError)
    Left problem -> fail ("unexpected post error " ++ show problem)
    Right _ -> fail "invalid flux placement unexpectedly compiled"
  where
    isExplicitError (ExplicitPrimitivePlanError operation _ message _) =
      operation == Primitives.fluxConservativeDivergenceV1OpId
      && "expected Primal face" `contains` message
    isExplicitError _ = False

testMaterializedPlacementRejection :: IO ()
testMaterializedPlacementRejection = do
  let request = materialized "constant-material" (Basis [])
        (TensorNF [] [] 0 [(Basis [], Exact 1 1)])
  assertLeft "materialize never infers placement from a constant"
    isExplicitError (planBackendEffects
      (withStep fixture (OpaqueDiscrete request)))
  where
    isExplicitError (ExplicitPrimitivePlanError operation _ message _) =
      operation == Primitives.operatorMaterializedV1OpId
      && "must be Located" `contains` message
    isExplicitError _ = False

fluxTensor :: TensorNF
fluxTensor = TensorNF [2] [VarianceDown] 0
  [ (Basis [axis], FieldJet (fieldJet (FieldId 2) (Basis [axis])))
  | axis <- [1, 2]
  ]

fieldJet :: FieldId -> Basis -> FieldJet
fieldJet field basis = FieldJetValue field CurrentTime basis
  [Coordinate (AxisId 1), Coordinate (AxisId 2)] []

materialized :: String -> Basis -> TensorNF -> OpaqueDiscrete
materialized key basis tensor = OpaqueDiscreteCall
  Primitives.operatorMaterializedV1OpId
  (SemanticKey key) (RequestGroupId "material-group")
  basis [if tensorNFShape tensor == []
          then ScalarValue (scalarComponent tensor)
          else TensorValue tensor] []
  where
    scalarComponent value = case tensorNFComponents value of
      [(Basis [], scalar)] -> scalar
      _ -> error "test fixture scalar tensor is malformed"

conservativeFlux :: String -> TensorNF -> OpaqueDiscrete
conservativeFlux key tensor = OpaqueDiscreteCall
  Primitives.fluxConservativeDivergenceV1OpId
  (SemanticKey key) (RequestGroupId (key ++ "-group"))
  (Basis []) [TensorValue tensor] []

withStep :: FEProgram -> ScalarNF -> FEProgram
withStep program scalar = program
  { feProgramStepActions =
      [UpdateField (FEEquation (EquationId 2)
        (WholeFieldTarget (FieldId 1) NextTime)
        (scalarTensor scalar) (OriginId 1))]
  }

fixture :: FEProgram
fixture = FEProgram
  { feProgramVersion = 1
  , feProgramModel = ModelIdentity (ModelId "model") "remaining"
      (SourceIdentity (SourceId "source") "remaining.fme")
  , feProgramRegistryId = RegistryId "registry"
  , feProgramPrimitiveManifestId = PrimitiveManifestId "manifest"
  , feProgramDiscretization = setProfileFingerprint
      (DiscretizationProfile
        (VersionedProfileId "formurae-discretization@1")
        (Fingerprint "") [] FixedAxisOrder)
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
      , vectorField (FieldId 2) "F" PrimalPolicy
      , vectorField (FieldId 3) "G" CollocatedPolicy
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

vectorField :: FieldId -> String -> GridPolicy -> LogicalFieldDecl
vectorField identifier name policy = LogicalFieldDecl identifier name policy
  (TensorType [2] [VarianceDown] 0) VectorLayout [Just VarianceDown]
  UserStateLifetime (OriginId 1)

scalarTensor :: ScalarNF -> TensorNF
scalarTensor scalar = TensorNF [] [] 0 [(Basis [], scalar)]

origin :: SourceOrigin
origin = SourceOrigin
  (SourceLocation (SourceId "source") "remaining.fme" 1 1 1 1) []

contains :: String -> String -> Bool
contains needle haystack = any (prefix needle) (tails haystack)
  where
    tails [] = [[]]
    tails values@(_ : rest) = values : tails rest
    prefix [] _ = True
    prefix _ [] = False
    prefix (x : xs) (y : ys) = x == y && prefix xs ys

assertRight :: String -> Either error value -> IO value
assertRight _ (Right value) = pure value
assertRight label (Left _) = fail (label ++ ": expected Right")

assertLeft
    :: Show error => String -> (error -> Bool) -> Either error value -> IO ()
assertLeft label predicate result =
  case result of
    Left problem | predicate problem -> pure ()
    Left problem -> fail (label ++ ": unexpected error " ++ show problem)
    Right _ -> fail (label ++ ": expected Left")

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail (label ++ ": expected " ++ show expected
      ++ ", got " ++ show actual)

assertContains :: String -> String -> String -> IO ()
assertContains label needle haystack
  | needle `contains` haystack = pure ()
  | otherwise = fail (label ++ ": missing " ++ show needle)

only :: String -> [value] -> IO value
only _ [value] = pure value
only label values = fail (label ++ ": expected one value, got "
  ++ show (length values))
