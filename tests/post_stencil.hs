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
  checkSbpPair
  putStrLn "post stencil tests: ok"

checkSbpPair :: IO ()
checkSbpPair = do
  pair <- assertRight "second-order SBP pair" (sbpStaggeredPair 1)
  assertEqual "SBP low closure row"
    [SbpBoundaryRow 0 [(0, -1), (1, 1)]] (sbpDualToPrimalLow pair)
  assertEqual "SBP high closure row"
    [SbpBoundaryRow 0 [(-2, -1), (-1, 1)]] (sbpDualToPrimalHigh pair)
  assertEqual "SBP second-order low closure row"
    [SbpBoundaryRow 0 [(0, 1), (1, -2), (2, 1)]] (sbpSecondLow pair)
  assertEqual "SBP primal norm boundary weight" [1 % 2] (sbpPrimalNorm pair)
  assertEqual "SBP dual norm is the identity" [] (sbpDualNorm pair)
  assertEqual "SBP boundary extrapolation"
    [(0, 3 % 2), (1, (-1) % 2)] (sbpExtrapolate pair)
  assertEqual "the minimal primal-to-dual direction is closure-free"
    [] (sbpPrimalToDualLow pair)
  forM_ [8, 9, 12, 17] $ \intervals ->
    assertEqual ("SBP identity at N=" ++ show intervals)
      (Right ()) (validateSbpStaggeredPair pair intervals)
  assertLeft "SBP grid too small"
    isTooSmall (validateSbpStaggeredPair pair 5)
  checkConstructedPair 2
  checkConstructedPair 3
  wide <- assertRight "fourth-order SBP pair" (sbpStaggeredPair 2)
  assertEqual "fourth-order boundary extrapolation is second order"
    [(0, 15 % 8), (1, (-5) % 4), (2, 3 % 8)] (sbpExtrapolate wide)
  assertEqual "fourth-order one-sided first row"
    (Just [(0, -2), (1, 3), (2, -1)])
    (lookup 0 [ (sbpRowOffset row, sbpRowWeights row)
              | row <- sbpDualToPrimalLow wide ])
  assertEqual "zero interior pairs are rejected"
    (Left (UnsupportedSbpInterior 0)) (sbpStaggeredPair 0)
  where
    isTooSmall (SbpGridTooSmall 5 _) = True
    isTooSmall _ = False

-- The general constructor must deliver both closure directions with
-- positive norms and pass the full finite-interval validation at several
-- sizes, including sizes above the construction's own checks; the boundary
-- rows must also be exact through the boundary order k (the interior pair
-- count), which is what the accuracy-(2k) profile promises at the walls.
checkConstructedPair :: Int -> IO ()
checkConstructedPair pairs = do
  let label = "constructed SBP pair k=" ++ show pairs
  pair <- assertRight label (sbpStaggeredPair pairs)
  assertBool (label ++ " has primal-to-dual closures")
    (not (null (sbpPrimalToDualLow pair)))
  assertBool (label ++ " has dual-to-primal closures")
    (not (null (sbpDualToPrimalLow pair)))
  assertBool (label ++ " positive norms")
    (all (> 0) (sbpPrimalNorm pair ++ sbpDualNorm pair))
  let minimumIntervals = sbpMinimumIntervals pair
  forM_ [minimumIntervals, minimumIntervals + 1, minimumIntervals + 7] $
    \intervals ->
      assertEqual (label ++ " identity at N=" ++ show intervals)
        (Right ()) (validateSbpStaggeredPair pair intervals)
  forM_ (sbpDualToPrimalLow pair) $ \row ->
    forM_ [0 .. pairs] $ \power ->
      assertEqual
        (label ++ " dual-to-primal row " ++ show (sbpRowOffset row)
         ++ " moment " ++ show power)
        (momentTarget power (fromIntegral (sbpRowOffset row)))
        (sum [ weight * dualPoint (sbpRowOffset row + offset) ^ power
             | (offset, weight) <- sbpRowWeights row ])
  forM_ (sbpPrimalToDualLow pair) $ \row ->
    forM_ [0 .. pairs] $ \power ->
      assertEqual
        (label ++ " primal-to-dual row " ++ show (sbpRowOffset row)
         ++ " moment " ++ show power)
        (momentTarget power (dualPoint (sbpRowOffset row)))
        (sum [ weight * fromIntegral (sbpRowOffset row + offset) ^ power
             | (offset, weight) <- sbpRowWeights row ])
  where
    dualPoint index = fromIntegral index + 1 % 2
    momentTarget power position
      | power == 0 = 0
      | otherwise = fromIntegral power * position ^ (power - 1)

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
