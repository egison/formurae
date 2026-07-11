module Main where

import Data.List (sortOn)

import Formurae.FEIR.Syntax
import Formurae.Post.Geometry

main :: IO ()
main = do
  testExteriorDerivativeConvention
  testExteriorDerivativeSquaresToZero
  testHodgeConventionAndPlacement
  testCodifferentialSign
  testInvalidBases
  putStrLn "post geometry tests: ok"

testExteriorDerivativeConvention :: IO ()
testExteriorDerivativeConvention = do
  terms <- assertRight "d 1-form component"
    (exteriorDerivativeTerms 3 PrimalPolicy (Basis [1, 3]))
  assertEqual "d component signs and removed bases"
    [ ExteriorDerivativeTerm 1 (AxisId 1) (Basis [3])
    , ExteriorDerivativeTerm (-1) (AxisId 3) (Basis [1])
    ]
    terms
  collocatedTerms <- assertRight "collocated d component"
    (exteriorDerivativeTerms 3 CollocatedPolicy (Basis [1, 3]))
  assertEqual "collocated d uses the same component convention"
    terms collocatedTerms

testExteriorDerivativeSquaresToZero :: IO ()
testExteriorDerivativeSquaresToZero = do
  outer <- assertRight "outer d"
    (exteriorDerivativeTerms 2 PrimalPolicy (Basis [1, 2]))
  paths <- concatMapM expand outer
  -- Mixed partials are canonical axis-count maps in FEIR.  Once derivative
  -- order is sorted, the two paths have the same atom and opposite signs.
  assertEqual "d squared canonical paths cancel"
    [([AxisId 1, AxisId 2], 0)]
    (combine paths)
  where
    expand outerTerm = do
      inner <- assertRight "inner d"
        (exteriorDerivativeTerms 2 PrimalPolicy
          (exteriorTermSourceBasis outerTerm))
      pure
        [ ( sortAxes [exteriorTermAxis outerTerm, exteriorTermAxis innerTerm]
          , exteriorTermSign outerTerm * exteriorTermSign innerTerm
          )
        | innerTerm <- inner
        ]

    sortAxes = map snd . sortOn fst . map (\axis@(AxisId value) -> (value, axis))
    combine values =
      [ (key, sum [coefficient | (other, coefficient) <- values, other == key])
      | key <- unique (map fst values)
      ]

testHodgeConventionAndPlacement :: IO ()
testHodgeConventionAndPlacement = do
  positive <- assertRight "positive hodge component"
    (hodgeComponent 3 PrimalPolicy (Basis [2, 3]))
  assertEqual "hodge complement"
    (HodgeComponent (Basis [1]) (Basis [2, 3]) 1 DualPolicy)
    positive
  negative <- assertRight "negative hodge component"
    (hodgeComponent 3 PrimalPolicy (Basis [1, 3]))
  assertEqual "hodge orientation"
    (HodgeComponent (Basis [2]) (Basis [1, 3]) (-1) DualPolicy)
    negative
  collocated <- assertRight "collocated hodge"
    (hodgeComponent 2 CollocatedPolicy (Basis [2]))
  assertEqual "collocated policy is self-dual"
    CollocatedPolicy (hodgeTargetPolicy collocated)

testCodifferentialSign :: IO ()
testCodifferentialSign = do
  assertEqual "two-dimensional one-form delta sign" (-1)
    =<< assertRight "delta sign n2 k1" (codifferentialSign 2 1)
  assertEqual "three-dimensional two-form delta sign" 1
    =<< assertRight "delta sign n3 k2" (codifferentialSign 3 2)
  assertEqual "positive scalar Laplacian is minus delta d" (-1)
    =<< assertRight "positive laplacian sign" (positiveScalarLaplacianSign 3)

testInvalidBases :: IO ()
testInvalidBases = do
  assertLeft "duplicate form basis"
    (== NonCanonicalFormBasis (Basis [1, 1]))
    (exteriorDerivativeTerms 3 PrimalPolicy (Basis [1, 1]))
  assertLeft "unsorted hodge basis"
    (== NonCanonicalFormBasis (Basis [2, 1]))
    (hodgeComponent 3 PrimalPolicy (Basis [2, 1]))

concatMapM :: (a -> IO [b]) -> [a] -> IO [b]
concatMapM function values = concat <$> mapM function values

unique :: Eq a => [a] -> [a]
unique = foldl add []
  where
    add values value
      | value `elem` values = values
      | otherwise = values ++ [value]

assertRight :: String -> Either a b -> IO b
assertRight _ (Right value) = pure value
assertRight label (Left _) = fail (label ++ ": expected Right")

assertLeft :: String -> (a -> Bool) -> Either a b -> IO ()
assertLeft label predicate result =
  case result of
    Left err | predicate err -> pure ()
    Left _ -> fail (label ++ ": unexpected error")
    Right _ -> fail (label ++ ": expected Left")

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
