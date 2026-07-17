module Main where

import Control.Monad (forM_)
import Data.Ratio ((%))

import Formurae.Post.Stencil

data ExpectedStencil = ExpectedStencil
  { expectedOrder :: Int
  , expectedAccuracy :: Int
  , expectedRadius :: Int
  , expectedWeights :: [(Int, Rational)]
  }

fixtures :: [ExpectedStencil]
fixtures =
  [ ExpectedStencil 1 2 1 [(-1, (-1) % 2), (0, 0), (1, 1 % 2)]
  , ExpectedStencil 2 2 1 [(-1, 1), (0, -2), (1, 1)]
  , ExpectedStencil 1 4 2
      [(-2, 1 % 12), (-1, (-2) % 3), (0, 0), (1, 2 % 3), (2, (-1) % 12)]
  , ExpectedStencil 2 4 2
      [(-2, (-1) % 12), (-1, 4 % 3), (0, (-5) % 2),
       (1, 4 % 3), (2, (-1) % 12)]
  , ExpectedStencil 3 2 2
      [(-2, (-1) % 2), (-1, 1), (0, 0), (1, -1), (2, 1 % 2)]
  , ExpectedStencil 4 2 2
      [(-2, 1), (-1, -4), (0, 6), (1, -4), (2, 1)]
  ]

main :: IO ()
main = do
  forM_ fixtures checkFixture
  checkMinimality
  checkRectangularRankDiagnostics
  checkInvalidRequests
  forM_ staggeredFixtures checkStaggeredFixture
  checkStaggeredCompose
  checkStaggeredInvalidRequests
  putStrLn "post stencil tests: ok"

checkFixture :: ExpectedStencil -> IO ()
checkFixture expected = do
  let order = expectedOrder expected
      accuracy = expectedAccuracy expected
      label = "m=" ++ show order ++ ", p=" ++ show accuracy
  stencil <- assertRight (label ++ " derivation") (centeredTaylor order accuracy)
  assertEqual (label ++ " order") order (centeredDerivativeOrder stencil)
  assertEqual (label ++ " accuracy") accuracy (centeredFormalAccuracy stencil)
  assertEqual (label ++ " minimal radius")
    (expectedRadius expected) (centeredRadius stencil)
  assertEqual (label ++ " exact weights")
    (expectedWeights expected) (centeredWeights stencil)
  assertEqual (label ++ " public minimal radius")
    (Right (expectedRadius expected)) (minimalCenteredRadius order accuracy)
  assertEqual (label ++ " invariant validation")
    (Right ()) (validateCenteredTaylor stencil)
  checkMoments label stencil
  checkParity label stencil
  checkEdges label stencil

checkMoments :: String -> CenteredStencil -> IO ()
checkMoments label stencil = do
  let order = centeredDerivativeOrder stencil
      accuracy = centeredFormalAccuracy stencil
      highestRequired = order + accuracy - 1
  forM_ [0 .. highestRequired] $ \momentOrder -> do
    let expected = if momentOrder == order then fromInteger (factorial order) else 0
    assertEqual (label ++ " moment " ++ show momentOrder)
      (Right expected) (stencilMoment stencil momentOrder)
  firstErrorMoment <-
    assertRight (label ++ " first error moment")
      (stencilMoment stencil (order + accuracy))
  assertBool (label ++ " first permitted error moment is nonzero")
    (firstErrorMoment /= 0)

checkParity :: String -> CenteredStencil -> IO ()
checkParity label stencil = do
  let sign = if even (centeredDerivativeOrder stencil) then 1 else -1
      weights = centeredWeights stencil
      radius = centeredRadius stencil
      weightAt offset =
        case lookup offset weights of
          Just weight -> weight
          Nothing -> error "test fixture has a missing offset"
  forM_ [0 .. radius] $ \offset ->
    assertEqual (label ++ " parity at " ++ show offset)
      (sign * weightAt offset) (weightAt (0 - offset))

checkEdges :: String -> CenteredStencil -> IO ()
checkEdges label stencil = do
  let radius = centeredRadius stencil
      weights = centeredWeights stencil
  forM_ [0 - radius, radius] $ \offset ->
    assertBool (label ++ " nonzero edge " ++ show offset)
      (lookup offset weights /= Just 0)

checkMinimality :: IO ()
checkMinimality = do
  assertLeft "m=1,p=4 has no radius-1 solution"
    isInconsistent (centeredTaylorAtRadius 1 4 1)
  assertLeft "m=2,p=4 has no radius-1 solution"
    isInconsistent (centeredTaylorAtRadius 2 4 1)
  where
    isInconsistent (MomentSystemInconsistent _ _ _) = True
    isInconsistent _ = False

checkRectangularRankDiagnostics :: IO ()
checkRectangularRankDiagnostics = do
  -- m=2,p=4 is a 6-by-5 system at radius 2.  Its successful fixture above
  -- exercises the consistent overdetermined path.  This wider m=1,p=2 case
  -- has three equations and five unknowns, so exact RREF must reject it as
  -- non-unique rather than selecting an arbitrary solution.
  assertLeft "underdetermined rectangular system"
    isNonUnique (centeredTaylorAtRadius 1 2 2)
  where
    isNonUnique (MomentSystemNotUnique 1 2 2) = True
    isNonUnique _ = False

checkInvalidRequests :: IO ()
checkInvalidRequests = do
  assertEqual "zero derivative order"
    (Left (InvalidDerivativeOrder 0)) (centeredTaylor 0 2)
  assertEqual "zero formal accuracy"
    (Left (InvalidFormalAccuracy 0)) (centeredTaylor 1 0)
  assertEqual "odd formal accuracy"
    (Left (InvalidFormalAccuracy 3)) (centeredTaylor 1 3)
  assertEqual "radius below derivative lower bound"
    (Left (RadiusTooSmall 1 2)) (centeredTaylorAtRadius 3 2 1)
  stencil <- assertRight "valid stencil for negative moment test" (centeredTaylor 1 2)
  assertEqual "negative moment order"
    (Left (InvalidMomentOrder (-1))) (stencilMoment stencil (-1))

data ExpectedStaggered = ExpectedStaggered
  { expectedStaggeredOrder :: Int
  , expectedStaggeredAccuracy :: Int
  , expectedStaggeredPairs :: Int
  , expectedStaggeredWeights :: [(Int, Rational)]
  }

-- Offsets are doubled: entry t weights the sample at t/2.
staggeredFixtures :: [ExpectedStaggered]
staggeredFixtures =
  [ ExpectedStaggered 1 2 1 [(-1, -1), (1, 1)]
  , ExpectedStaggered 1 4 2
      [(-3, 1 % 24), (-1, (-9) % 8), (1, 9 % 8), (3, (-1) % 24)]
  , ExpectedStaggered 1 6 3
      [(-5, (-3) % 640), (-3, 25 % 384), (-1, (-75) % 64),
       (1, 75 % 64), (3, (-25) % 384), (5, 3 % 640)]
  , ExpectedStaggered 3 2 2
      [(-3, -1), (-1, 3), (1, -3), (3, 1)]
  ]

checkStaggeredFixture :: ExpectedStaggered -> IO ()
checkStaggeredFixture expected = do
  let order = expectedStaggeredOrder expected
      accuracy = expectedStaggeredAccuracy expected
      pairs = expectedStaggeredPairs expected
      label = "staggered m=" ++ show order ++ ", p=" ++ show accuracy
  stencil <- assertRight (label ++ " derivation")
    (staggeredTaylorAtPairs order accuracy pairs)
  assertEqual (label ++ " order") order (staggeredDerivativeOrder stencil)
  assertEqual (label ++ " accuracy") accuracy
    (staggeredFormalAccuracy stencil)
  assertEqual (label ++ " pairs") pairs (staggeredPairCount stencil)
  assertEqual (label ++ " exact weights")
    (expectedStaggeredWeights expected) (staggeredTwiceWeights stencil)
  assertEqual (label ++ " invariant validation")
    (Right ()) (validateStaggeredTaylor stencil)

checkStaggeredCompose :: IO ()
checkStaggeredCompose = do
  compact <- assertRight "k=1 stage" (staggeredTaylorAtPairs 1 2 1)
  composed <- assertCentered "k=1 twofold composition"
    =<< assertRight "k=1 twofold composition" (composeStages 2 compact)
  assertEqual "k=1 twofold composition is the compact second derivative"
    [(-1, 1), (0, -2), (1, 1)] (centeredWeights composed)
  assertEqual "k=1 composed order" 2 (centeredDerivativeOrder composed)
  assertEqual "k=1 composed accuracy" 2 (centeredFormalAccuracy composed)

  onefold <- assertStaggered "k=1 onefold composition"
    =<< assertRight "k=1 onefold composition" (composeStages 1 compact)
  assertEqual "onefold composition is the stage itself" compact onefold

  -- At the minimal width the composed and directly solved stencils
  -- coincide for every order: the moment systems are exactly determined.
  threefold <- assertStaggered "k=1 threefold composition"
    =<< assertRight "k=1 threefold composition" (composeStages 3 compact)
  direct3 <- assertRight "direct third derivative"
    (staggeredTaylorAtPairs 3 2 2)
  assertEqual "threefold composition equals the direct third derivative"
    direct3 threefold
  fourfold <- assertCentered "k=1 fourfold composition"
    =<< assertRight "k=1 fourfold composition" (composeStages 4 compact)
  direct4 <- assertRight "direct fourth derivative" (centeredTaylor 4 2)
  assertEqual "fourfold composition equals the direct fourth derivative"
    direct4 fourfold

  wide <- assertRight "k=2 stage" (staggeredTaylorAtPairs 1 4 2)
  composedWide <- assertCentered "k=2 twofold composition"
    =<< assertRight "k=2 twofold composition" (composeStages 2 wide)
  assertEqual "k=2 composed radius" 3 (centeredRadius composedWide)
  assertEqual "k=2 composed accuracy" 4 (centeredFormalAccuracy composedWide)
  assertEqual "k=2 composed weights"
    [ (-3, 1 % 576), (-2, (-3) % 32), (-1, 87 % 64), (0, (-365) % 144)
    , (1, 87 % 64), (2, (-3) % 32), (3, 1 % 576)
    ]
    (centeredWeights composedWide)
  assertEqual "k=2 composed invariant validation"
    (Right ()) (validateCenteredTaylor composedWide)

  wideThird <- assertStaggered "k=2 threefold composition"
    =<< assertRight "k=2 threefold composition" (composeStages 3 wide)
  assertEqual "k=2 threefold order" 3 (staggeredDerivativeOrder wideThird)
  assertEqual "k=2 threefold accuracy" 4
    (staggeredFormalAccuracy wideThird)
  assertEqual "k=2 threefold pairs" 5 (staggeredPairCount wideThird)
  assertEqual "k=2 threefold edge weight"
    (Just ((-1) % 13824)) (lookup 9 (staggeredTwiceWeights wideThird))
  assertEqual "k=2 threefold invariant validation"
    (Right ()) (validateStaggeredTaylor wideThird)

assertCentered :: String -> ComposedStencil -> IO CenteredStencil
assertCentered _ (ComposedCentered stencil) = return stencil
assertCentered label (ComposedStaggered _) =
  fail (label ++ ": expected a centered composition")

assertStaggered :: String -> ComposedStencil -> IO StaggeredStencil
assertStaggered _ (ComposedStaggered stencil) = return stencil
assertStaggered label (ComposedCentered _) =
  fail (label ++ ": expected a staggered composition")

checkStaggeredInvalidRequests :: IO ()
checkStaggeredInvalidRequests = do
  assertEqual "even staggered order"
    (Left (StaggeredOrderMustBeOdd 2)) (staggeredTaylorAtPairs 2 2 1)
  assertEqual "zero staggered order"
    (Left (InvalidDerivativeOrder 0)) (staggeredTaylorAtPairs 0 2 1)
  assertEqual "odd staggered accuracy"
    (Left (InvalidFormalAccuracy 3)) (staggeredTaylorAtPairs 1 3 1)
  assertEqual "pairs below derivative lower bound"
    (Left (RadiusTooSmall 1 2)) (staggeredTaylorAtPairs 3 2 1)

factorial :: Int -> Integer
factorial n = product [1 .. toInteger n]

assertRight :: String -> Either a b -> IO b
assertRight _ (Right value) = return value
assertRight label (Left _) = fail (label ++ ": expected Right")

assertLeft :: String -> (a -> Bool) -> Either a b -> IO ()
assertLeft label predicate result =
  case result of
    Left err
      | predicate err -> return ()
      | otherwise -> fail (label ++ ": unexpected Left value")
    Right _ -> fail (label ++ ": expected Left")

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = return ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)

assertBool :: String -> Bool -> IO ()
assertBool _ True = return ()
assertBool label False = fail (label ++ ": condition is false")
