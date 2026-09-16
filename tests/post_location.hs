module Main where

import Formurae.FEIR.Syntax
import Formurae.Post.Location

main :: IO ()
main = do
  testComponentPlacement
  testMixedPlacement
  testDerivativePlacement
  testFieldJetPlacement
  testCapabilities
  testErrors
  putStrLn "post location tests: ok"

testComponentPlacement :: IO ()
testComponentPlacement = do
  assertEqual "collocated vector"
    (Right (Placement [IntegerPoint, IntegerPoint, IntegerPoint]))
    (componentPlacement 3 CollocatedPolicy (Basis [2]))
  assertEqual "primal component 1"
    (Right (Placement [HalfPoint, IntegerPoint, IntegerPoint]))
    (componentPlacement 3 PrimalPolicy (Basis [1]))
  assertEqual "primal repeated component"
    (Right (Placement [IntegerPoint, IntegerPoint, IntegerPoint]))
    (componentPlacement 3 PrimalPolicy (Basis [1, 1]))
  assertEqual "dual component 1"
    (Right (Placement [IntegerPoint, HalfPoint, HalfPoint]))
    (componentPlacement 3 DualPolicy (Basis [1]))

testMixedPlacement :: IO ()
testMixedPlacement = do
  let field = (vectorField (FieldId 1) PrimalPolicy)
        { logicalFieldTensorType = TensorType [9,3] [VarianceDown, VarianceUp] 0
        , logicalFieldLayout = FullLayout
        , logicalFieldDeclaredVariances = [Just VarianceDown, Just VarianceUp]
        , logicalFieldSpatialSlots = [2]
        }
  assertEqual "only the spatial slot affects primal placement"
    (Right (Placement [IntegerPoint, HalfPoint, IntegerPoint]))
    (fieldComponentPlacement 3 field (Basis [9,2]))
  assertEqual "only the spatial slot affects dual placement"
    (Right (Placement [HalfPoint, IntegerPoint, HalfPoint]))
    (fieldComponentPlacement 3 (field { logicalFieldPolicy = DualPolicy }) (Basis [9,2]))
  assertEqual "a component number equal to a direction is still non-spatial"
    (Right (Placement [IntegerPoint, HalfPoint, IntegerPoint]))
    (fieldComponentPlacement 3 field (Basis [2,2]))
  assertEqual "component extent is checked independently of dimension"
    (Left (FieldJetBasisMismatch (FieldId 1) (Basis [10,2])))
    (fieldComponentPlacement 3 field (Basis [10,2]))

testDerivativePlacement :: IO ()
testDerivativePlacement = do
  let source = Placement [HalfPoint, IntegerPoint, IntegerPoint]
  assertEqual "first derivative toggles"
    (Right (Placement [HalfPoint, HalfPoint, IntegerPoint]))
    (derivativePlacement [(AxisId 2, 1)] source)
  assertEqual "second derivative restores"
    (Right source)
    (derivativePlacement [(AxisId 1, 2)] source)
  assertEqual "mixed derivative"
    (Right (Placement [IntegerPoint, HalfPoint, IntegerPoint]))
    (derivativePlacement [(AxisId 1, 1), (AxisId 2, 1)] source)
  assertEqual "relative half offset"
    (Right [1 / 2, -1 / 2])
    (relativePlacement
       (Placement [HalfPoint, IntegerPoint])
       (Placement [IntegerPoint, HalfPoint]))

testFieldJetPlacement :: IO ()
testFieldJetPlacement = do
  let field = vectorField (FieldId 1) PrimalPolicy
      jet = FieldJetValue
        { fieldJetFieldId = FieldId 1
        , fieldJetTimeSlot = CurrentTime
        , fieldJetBasis = Basis [3]
        , fieldJetArguments = [Coordinate (AxisId 1), Coordinate (AxisId 2), Coordinate (AxisId 3)]
        , fieldJetMultiIndex = [(AxisId 1, 1), (AxisId 3, 2)]
        }
  assertEqual "field jet source and natural target"
    (Right
      ( Placement [IntegerPoint, IntegerPoint, HalfPoint]
      , Placement [HalfPoint, IntegerPoint, HalfPoint]
      ))
    (fieldJetPlacements 3 [field] jet)
  let collocated = vectorField (FieldId 2) CollocatedPolicy
      collocatedJet = jet { fieldJetFieldId = FieldId 2 }
      collocatedPoint = Placement
        [IntegerPoint, IntegerPoint, IntegerPoint]
  assertEqual "collocated analytic derivatives stay collocated"
    (Right (collocatedPoint, collocatedPoint))
    (fieldJetPlacements 3 [collocated] collocatedJet)

testCapabilities :: IO ()
testCapabilities = do
  let point = Placement [IntegerPoint, HalfPoint]
      other = Placement [HalfPoint, HalfPoint]
      located = LocatedCapability point
  assertEqual "constant is neutral"
    (Right located) (joinCapability ConstantCapability located)
  assertEqual "sampleable adopts location"
    (Right located) (joinCapability SampleableCapability located)
  assertEqual "equal locations join"
    (Right located) (joinCapability located located)
  assertEqual "neutral demand"
    (Right point) (demandCapability point SampleableCapability)
  assertEqual "mismatched locations"
    (Left (LocatedPlacementMismatch point other))
    (joinCapability located (LocatedCapability other))

testErrors :: IO ()
testErrors = do
  assertEqual "invalid basis"
    (Left (InvalidBasisAxis 4 3))
    (componentPlacement 3 PrimalPolicy (Basis [4]))
  assertEqual "invalid derivative axis"
    (Left (InvalidDerivativeAxis (AxisId 0) 2))
    (togglePlacement (AxisId 0) (Placement [IntegerPoint, IntegerPoint]))
  assertEqual "zero derivative multiplicity"
    (Left (ZeroDerivativeMultiplicity (AxisId 1)))
    (derivativePlacement [(AxisId 1, 0)] (Placement [IntegerPoint]))
  let badJet = FieldJetValue
        { fieldJetFieldId = FieldId 9
        , fieldJetTimeSlot = CurrentTime
        , fieldJetBasis = Basis []
        , fieldJetArguments = []
        , fieldJetMultiIndex = []
        }
  assertEqual "unknown field"
    (Left (UnknownLocationField (FieldId 9)))
    (fieldJetPlacements 1 [] badJet)

vectorField :: FieldId -> GridPolicy -> LogicalFieldDecl
vectorField fieldId policy = LogicalFieldDecl
  { logicalFieldId = fieldId
  , logicalFieldSourceName = "V"
  , logicalFieldPolicy = policy
  , logicalFieldTensorType = TensorType [3] [VarianceDown] 0
  , logicalFieldLayout = VectorLayout
  , logicalFieldDeclaredVariances = [Just VarianceDown]
  , logicalFieldSpatialSlots = [1]
  , logicalFieldLifetime = UserStateLifetime
  , logicalFieldOrigin = OriginId 1
  }

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
