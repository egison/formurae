module Main where

import Formurae.FEIR.Syntax
import Formurae.Post.Location

main :: IO ()
main = do
  testComponentPlacement
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
  , logicalFieldLifetime = UserStateLifetime
  , logicalFieldOrigin = OriginId 1
  }

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
