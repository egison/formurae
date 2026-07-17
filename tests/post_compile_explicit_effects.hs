module Main (main) where

import Data.List (findIndex)
import Numeric.Natural (Natural)

import Formurae.FEIR.Codec (setProfileFingerprint)
import Formurae.FEIR.Syntax
import Formurae.Post.Compile (compileProgram)
import Formurae.Post.FMR (renderProgram)

main :: IO ()
main = do
  compiled <- assertRight "compile ordinary Materialize action"
    (compileProgram fixture)
  rendered <- assertRight "render ordinary Materialize action"
    (renderProgram compiled)
  assertInOrder "face components materialize before their consumer"
    [ "q_down1[i,j] = F_down1[i,j]"
    , "q_down2[i,j] = F_down2[i,j]"
    , "u'[i,j] ="
    ] rendered
  assertContains "x divergence reads stored q face samples"
    "(q_down1[i,j] + (-1) * q_down1[i-1,j]) / dx" rendered
  assertContains "y divergence reads stored q face samples"
    "(q_down2[i,j] + (-1) * q_down2[i,j-1]) / dy" rendered
  assertNotContains "removed conservative auxiliary"
    "FormuraeInternalConservative" rendered
  assertNotContains "removed opaque materialization auxiliary"
    "FormuraeInternalMaterialized" rendered
  testSourceOrderedNextTimeDependency
  putStrLn "post compile Materialize action tests: ok"

testSourceOrderedNextTimeDependency :: IO ()
testSourceOrderedNextTimeDependency = do
  compiled <- assertRight "compile source-ordered NextTime dependency"
    (compileProgram sourceOrderedFixture)
  rendered <- assertRight "render source-ordered NextTime dependency"
    (renderProgram compiled)
  assertInOrder "updates and locals retain FEIR source order"
    [ "u'[i,j] ="
    , "q[i,j] = u'[i,j]"
    , "v'[i,j] = q[i,j]"
    ] rendered

fixture :: FEProgram
fixture = FEProgram
  { feProgramModel = ModelIdentity (ModelId "materialize-model") "materialize"
      (SourceIdentity (SourceId "materialize-source") "materialize.fme")
  , feProgramRegistryId = RegistryId "materialize-registry"
  , feProgramPrimitiveManifestId = PrimitiveManifestId "materialize-manifest"
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
  , feProgramFields = [stateScalar, sourceFluxField, localFluxField]
  , feProgramInitializers = []
  , feProgramStepActions =
      [ Materialize (FieldId 3) (TensorValue sourceFlux) (OriginId 1)
      , UpdateField (FEEquation (EquationId 1)
          (WholeFieldTarget (FieldId 1) NextTime)
          divergenceTensor (OriginId 1))
      ]
  , feProgramRawHelpers = []
  , feProgramOrigins = OriginTable []
  , feProgramProvenance = ProvenanceTable []
  }

sourceOrderedFixture :: FEProgram
sourceOrderedFixture = fixture
  { feProgramFields = [stateScalar, secondStateScalar, scalarLocal]
  , feProgramStepActions =
      [ UpdateField (FEEquation (EquationId 1)
          (WholeFieldTarget (FieldId 1) NextTime)
          (scalarTensor (Add
            [ Exact 1 1
            , FieldJet (scalarFieldJet (FieldId 1) CurrentTime)
            ]))
          (OriginId 1))
      , Materialize (FieldId 5)
          (ScalarValue (FieldJet
            (scalarFieldJet (FieldId 1) NextTime)))
          (OriginId 1)
      , UpdateField (FEEquation (EquationId 2)
          (WholeFieldTarget (FieldId 4) NextTime)
          (scalarTensor (FieldJet
            (scalarFieldJet (FieldId 5) CurrentTime)))
          (OriginId 1))
      ]
  }

profile :: DiscretizationProfile
profile = DiscretizationProfile
  (Fingerprint "") [] FixedAxisOrder

stateScalar :: LogicalFieldDecl
stateScalar = LogicalFieldDecl (FieldId 1) "u" CollocatedPolicy
  (TensorType [] [] 0) ScalarLayout [] UserStateLifetime (OriginId 1)

secondStateScalar :: LogicalFieldDecl
secondStateScalar = LogicalFieldDecl (FieldId 4) "v" CollocatedPolicy
  (TensorType [] [] 0) ScalarLayout [] UserStateLifetime (OriginId 1)

scalarLocal :: LogicalFieldDecl
scalarLocal = LogicalFieldDecl (FieldId 5) "q" CollocatedPolicy
  (TensorType [] [] 0) ScalarLayout [] StepLocalLifetime (OriginId 1)

sourceFluxField :: LogicalFieldDecl
sourceFluxField = vectorField (FieldId 2) "F" UserStateLifetime

localFluxField :: LogicalFieldDecl
localFluxField = vectorField (FieldId 3) "q" StepLocalLifetime

vectorField :: FieldId -> String -> Lifetime -> LogicalFieldDecl
vectorField fieldId name lifetime = LogicalFieldDecl fieldId name PrimalPolicy
  (TensorType [2] [VarianceDown] 0) VectorLayout [Just VarianceDown]
  lifetime (OriginId 1)

sourceFlux :: TensorNF
sourceFlux = TensorNF [2] [VarianceDown] 0
  [ (basis, FieldJet (fieldJet (FieldId 2) basis []))
  | basis <- [Basis [1], Basis [2]]
  ]

divergenceTensor :: TensorNF
divergenceTensor = TensorNF [] [] 0
  [ (Basis [], Add
      [ FieldJet (fieldJet (FieldId 3) (Basis [1]) [(AxisId 1, 1)])
      , FieldJet (fieldJet (FieldId 3) (Basis [2]) [(AxisId 2, 1)])
      ])
  ]

scalarTensor :: ScalarNF -> TensorNF
scalarTensor value = TensorNF [] [] 0 [(Basis [], value)]

scalarFieldJet :: FieldId -> TimeSlot -> FieldJet
scalarFieldJet field slot = FieldJetValue field slot (Basis [])
  [Coordinate (AxisId 1), Coordinate (AxisId 2)] []

fieldJet :: FieldId -> Basis -> [(AxisId, Natural)] -> FieldJet
fieldJet field basis multiIndex = FieldJetValue field CurrentTime basis
  [Coordinate (AxisId 1), Coordinate (AxisId 2)] multiIndex

assertRight :: String -> Either error value -> IO value
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

assertInOrder :: String -> [String] -> String -> IO ()
assertInOrder label needles haystack =
  case mapM (`findIndexOf` haystack) needles of
    Just positions
      | and (zipWith (<) positions (drop 1 positions)) -> pure ()
      | otherwise -> fail (label ++ ": wrong order " ++ show positions)
    Nothing -> fail (label ++ ": missing an expected line")

findIndexOf :: Eq value => [value] -> [value] -> Maybe Int
findIndexOf needle haystack = findIndex (prefix needle) (tails haystack)

contains :: Eq value => [value] -> [value] -> Bool
contains needle haystack = case findIndexOf needle haystack of
  Just _ -> True
  Nothing -> False

tails :: [value] -> [[value]]
tails [] = [[]]
tails values@(_ : rest) = values : tails rest

prefix :: Eq value => [value] -> [value] -> Bool
prefix [] _ = True
prefix _ [] = False
prefix (x : xs) (y : ys) = x == y && prefix xs ys
