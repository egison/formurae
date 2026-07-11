module Main where

import Formurae.FEIR.Syntax (AxisId(..))
import Formurae.Post.ExplicitStencil
import Formurae.Post.Location

main :: IO ()
main = do
  testOrderedCollocated
  testOrderedStaggered
  testResample
  putStrLn "post explicit stencil tests: ok"

testOrderedCollocated :: IO ()
testOrderedCollocated = do
  plan <- assertRight "collocated ordered"
    (orderedFirstDerivativeStencil False
      [AxisId 2, AxisId 1] (Placement [IntegerPoint, IntegerPoint]))
  assertEqual "collocated placement is stable"
    (Placement [IntegerPoint, IntegerPoint]) (orderedStencilTarget plan)
  assertEqual "axis order is retained for denominator scheduling"
    [AxisId 2, AxisId 1] (orderedStencilDenominatorAxes plan)
  assertEqual "ordered centered tensor product"
    [ ([-1, -1], 1 / 4)
    , ([1, -1], -1 / 4)
    , ([-1, 1], -1 / 4)
    , ([1, 1], 1 / 4)
    ]
    (orderedStencilSamples plan)

testOrderedStaggered :: IO ()
testOrderedStaggered = do
  repeated <- assertRight "staggered repeated axis"
    (orderedFirstDerivativeStencil True [AxisId 1, AxisId 1]
      (Placement [IntegerPoint]))
  assertEqual "two staggered stages return to their source placement"
    (Placement [IntegerPoint]) (orderedStencilTarget repeated)
  assertEqual "forward then backward forms the compact second difference"
    [([-1], 1), ([0], -1), ([0], -1), ([1], 1)]
    (orderedStencilSamples repeated)

testResample :: IO ()
testResample = do
  toFace <- assertRight "cell to x-face"
    (resampleLinearStencil
      (Placement [IntegerPoint, IntegerPoint])
      (Placement [HalfPoint, IntegerPoint]))
  assertEqual "cell-to-face average"
    [([0, 0], 1 / 2), ([1, 0], 1 / 2)] toFace
  toCell <- assertRight "xy-half to cell"
    (resampleLinearStencil
      (Placement [HalfPoint, HalfPoint])
      (Placement [IntegerPoint, IntegerPoint]))
  assertEqual "two-axis tensor-product average"
    [ ([-1, -1], 1 / 4)
    , ([-1, 0], 1 / 4)
    , ([0, -1], 1 / 4)
    , ([0, 0], 1 / 4)
    ] toCell

assertRight :: String -> Either error value -> IO value
assertRight _ (Right value) = pure value
assertRight label (Left _) = fail (label ++ ": expected Right")

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail (label ++ ": expected " ++ show expected
      ++ ", got " ++ show actual)
