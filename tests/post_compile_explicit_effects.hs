module Main (main) where

import Data.List (findIndex)

import Formurae.FEIR.Codec (setProfileFingerprint)
import qualified Formurae.FEIR.PrimitiveBindings as Primitives
import Formurae.FEIR.Syntax
import Formurae.Post.Compile (compileProgram)
import Formurae.Post.FMR (renderProgram)

main :: IO ()
main = do
  compiled <- assertRight "compile nested explicit effects"
    (compileProgram fixture)
  rendered <- assertRight "render nested explicit effects"
    (renderProgram compiled)
  assertInOrder "child conservative divergence precedes parent materialization"
    [ "FormuraeInternalConservative1Flux1[i,j] ="
    , "FormuraeInternalConservative1Flux2[i,j] ="
    , "FormuraeInternalConservative1Result[i,j] ="
    , "FormuraeInternalMaterialized1BScalar[i,j] ="
    , "u'[i,j] = FormuraeInternalMaterialized1BScalar[i,j]"
    ] rendered
  assertInOrder "child tensor materialization precedes parent divergence"
    [ "FormuraeInternalMaterialized2B1[i,j] ="
    , "FormuraeInternalMaterialized2B2[i,j] ="
    , "FormuraeInternalConservative2Flux1[i,j] ="
    , "FormuraeInternalConservative2Flux2[i,j] ="
    , "FormuraeInternalConservative2Result[i,j] ="
    , "v'[i,j] = FormuraeInternalConservative2Result[i,j]"
    ] rendered
  assertContains "materialized tensor feeds x flux"
    "FormuraeInternalConservative2Flux1[i,j] = FormuraeInternalMaterialized2B1[i,j]"
    rendered
  assertContains "materialized tensor feeds y flux"
    "FormuraeInternalConservative2Flux2[i,j] = FormuraeInternalMaterialized2B2[i,j]"
    rendered
  assertCount "materialized tensor group is scheduled once"
    1 "FormuraeInternalMaterialized2B1[i,j] =" rendered
  assertNotContains "no opaque operation survives"
    "opaque-discrete" rendered
  putStrLn "post compile explicit effect tests: ok"

fixture :: FEProgram
fixture = FEProgram
  { feProgramVersion = 1
  , feProgramModel = ModelIdentity (ModelId "nested-model") "nested"
      (SourceIdentity (SourceId "nested-source") "nested.fme")
  , feProgramRegistryId = RegistryId "nested-registry"
  , feProgramPrimitiveManifestId = PrimitiveManifestId "nested-manifest"
  , feProgramDiscretization = setProfileFingerprint profile
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
  , feProgramFields = [scalarField (FieldId 1) "u", scalarField (FieldId 2) "v", fluxField]
  , feProgramInitializers = []
  , feProgramStepActions =
      [ UpdateField (scalarEquation (EquationId 1) (FieldId 1)
          (OpaqueDiscrete materializedDivergence))
      , UpdateField (scalarEquation (EquationId 2) (FieldId 2)
          (OpaqueDiscrete divergenceOfMaterializedFlux))
      , UpdateField (FEEquation (EquationId 3)
          (WholeFieldTarget (FieldId 3) NextTime) fluxTensor (OriginId 1))
      ]
  , feProgramRawHelpers = []
  , feProgramOrigins = OriginTable [(OriginId 1, origin)]
  , feProgramProvenance = ProvenanceTable []
  }

profile :: DiscretizationProfile
profile = DiscretizationProfile
  (VersionedProfileId "formurae-discretization@1")
  (Fingerprint "") [] FixedAxisOrder

scalarField :: FieldId -> String -> LogicalFieldDecl
scalarField fieldId name = LogicalFieldDecl fieldId name CollocatedPolicy
  (TensorType [] [] 0) ScalarLayout [] UserStateLifetime (OriginId 1)

fluxField :: LogicalFieldDecl
fluxField = LogicalFieldDecl (FieldId 3) "F" PrimalPolicy
  (TensorType [2] [VarianceDown] 0) VectorLayout [Just VarianceDown]
  UserStateLifetime (OriginId 1)

fluxTensor :: TensorNF
fluxTensor = TensorNF [2] [VarianceDown] 0
  [ (Basis [1], FieldJet (fluxJet (Basis [1])))
  , (Basis [2], FieldJet (fluxJet (Basis [2])))
  ]

fluxJet :: Basis -> FieldJet
fluxJet basis = FieldJetValue (FieldId 3) CurrentTime basis
  [Coordinate (AxisId 1), Coordinate (AxisId 2)] []

innerDivergence :: OpaqueDiscrete
innerDivergence = opaque Primitives.fluxConservativeDivergenceV1OpId
  "inner-divergence" "inner-divergence-group" (Basis [])
  [TensorValue fluxTensor]

materializedDivergence :: OpaqueDiscrete
materializedDivergence = opaque Primitives.operatorMaterializedV1OpId
  "outer-materialized" "outer-materialized-group" (Basis [])
  [ScalarValue (OpaqueDiscrete innerDivergence)]

materializedFlux1, materializedFlux2 :: OpaqueDiscrete
materializedFlux1 = materializedFluxComponent (Basis [1]) "materialized-flux-1"
materializedFlux2 = materializedFluxComponent (Basis [2]) "materialized-flux-2"

materializedFluxComponent :: Basis -> String -> OpaqueDiscrete
materializedFluxComponent basis key =
  opaque Primitives.operatorMaterializedV1OpId key
    "materialized-flux-group" basis [TensorValue fluxTensor]

materializedFluxTensor :: TensorNF
materializedFluxTensor = TensorNF [2] [VarianceDown] 0
  [ (Basis [1], OpaqueDiscrete materializedFlux1)
  , (Basis [2], OpaqueDiscrete materializedFlux2)
  ]

divergenceOfMaterializedFlux :: OpaqueDiscrete
divergenceOfMaterializedFlux =
  opaque Primitives.fluxConservativeDivergenceV1OpId
    "outer-divergence" "outer-divergence-group" (Basis [])
    [TensorValue materializedFluxTensor]

opaque
    :: VersionedOpId
    -> String
    -> String
    -> Basis
    -> [FEValue]
    -> OpaqueDiscrete
opaque operation key group basis operands = OpaqueDiscreteCall
  operation (SemanticKey key) (RequestGroupId group) basis operands []

scalarEquation :: EquationId -> FieldId -> ScalarNF -> FEEquation
scalarEquation equationId fieldId scalar = FEEquation equationId
  (WholeFieldTarget fieldId NextTime)
  (TensorNF [] [] 0 [(Basis [], scalar)]) (OriginId 1)

origin :: SourceOrigin
origin = SourceOrigin
  (SourceLocation (SourceId "nested-source") "nested.fme" 1 1 1 1) []

assertRight :: String -> Either a b -> IO b
assertRight _ (Right value) = pure value
assertRight label (Left _) = fail (label ++ ": expected Right")

assertContains :: String -> String -> String -> IO ()
assertContains label needle haystack
  | contains needle haystack = pure ()
  | otherwise = fail (label ++ ": missing " ++ show needle)

assertNotContains :: String -> String -> String -> IO ()
assertNotContains label needle haystack
  | contains needle haystack = fail (label ++ ": found " ++ show needle)
  | otherwise = pure ()

assertCount :: String -> Int -> String -> String -> IO ()
assertCount label expected needle haystack
  | actual == expected = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
  where
    actual = length
      [ ()
      | suffix <- tails haystack
      , prefix needle suffix
      ]

assertInOrder :: String -> [String] -> String -> IO ()
assertInOrder label needles haystack =
  case mapM (`findIndexOf` haystack) needles of
    Just positions
      | and (zipWith (<) positions (drop 1 positions)) -> pure ()
      | otherwise -> fail (label ++ ": wrong order " ++ show positions)
    Nothing -> fail (label ++ ": missing an expected line")

findIndexOf :: Eq a => [a] -> [a] -> Maybe Int
findIndexOf needle haystack = findIndex (prefix needle) (tails haystack)

contains :: Eq a => [a] -> [a] -> Bool
contains needle haystack = case findIndexOf needle haystack of
  Just _ -> True
  Nothing -> False

tails :: [a] -> [[a]]
tails [] = [[]]
tails values@(_ : rest) = values : tails rest

prefix :: Eq a => [a] -> [a] -> Bool
prefix [] _ = True
prefix _ [] = False
prefix (x : xs) (y : ys) = x == y && prefix xs ys
