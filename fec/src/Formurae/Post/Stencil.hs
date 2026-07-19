module Formurae.Post.Stencil
  ( CenteredStencil
  , ComposedStencil(..)
  , SbpBoundaryRow(..)
  , SbpStaggeredPair(..)
  , StaggeredStencil
  , StencilError(..)
  , centeredDerivativeOrder
  , centeredFormalAccuracy
  , centeredRadius
  , centeredWeights
  , centeredTaylor
  , centeredTaylorAtRadius
  , minimalCenteredRadius
  , composeStages
  , sbpStaggeredPair
  , staggeredDerivativeOrder
  , staggeredFormalAccuracy
  , staggeredPairCount
  , staggeredTaylorAtPairs
  , staggeredTwiceWeights
  , stencilMoment
  , validateCenteredTaylor
  , validateSbpStaggeredPair
  , validateStaggeredTaylor
  ) where

import Data.List (findIndex)

-- | A centered, single-axis finite-difference stencil.  The weights multiply
-- samples at the integer offsets and the resulting sum is divided by h^m,
-- where m is 'centeredDerivativeOrder'.
data CenteredStencil = CenteredStencil
  { centeredDerivativeOrder :: Int
  , centeredFormalAccuracy :: Int
  , centeredRadius :: Int
  , centeredWeights :: [(Int, Rational)]
  } deriving (Eq, Show)

data StencilError
  = InvalidDerivativeOrder Int
  | InvalidFormalAccuracy Int
  | InvalidMomentOrder Int
  | RadiusTooSmall Int Int
  | MomentSystemInconsistent Int Int Int
  | MomentSystemNotUnique Int Int Int
  | InvalidOffsetLayout [Int] [Int]
  | MomentMismatch Int Rational Rational
  | ParityMismatch Int Rational Rational
  | ZeroEdgeCoefficient Int
  | NoCenteredTaylorStencil Int Int
  | StaggeredOrderMustBeOdd Int
  | UnsupportedSbpInterior Int
  | SbpGridTooSmall Int Int
  | SbpSampleOutOfRange Int Int
  | SbpAccuracyMismatch Int Int Rational Rational
  | SbpIdentityMismatch Int Int Rational Rational
  | SbpCompositionMismatch Int Int Rational Rational
  | SbpNormNotPositive Int Rational
  | SbpExtrapolationMismatch Int Rational Rational
  deriving (Eq, Show)

-- | A staggered, single-axis finite-difference stencil.  Samples sit at the
-- half-integer offsets t/2 (t odd) around the target point, which lies on
-- the dual sub-lattice of the operand.  Offsets are stored doubled so the
-- representation stays integral; the weighted sum is divided by h^m.
data StaggeredStencil = StaggeredStencil
  { staggeredDerivativeOrder :: Int
  , staggeredFormalAccuracy :: Int
  , staggeredPairCount :: Int
  , staggeredTwiceWeights :: [(Int, Rational)]
  } deriving (Eq, Show)

-- | Derive the unique centered Taylor stencil at the smallest radius that
-- satisfies derivative order m and formal accuracy p.
centeredTaylor :: Int -> Int -> Either StencilError CenteredStencil
centeredTaylor derivativeOrder formalAccuracy = do
  validateRequest derivativeOrder formalAccuracy
  search minimumRadius
  where
    minimumRadius = minimumAdmissibleRadius derivativeOrder
    maximumRadius = (derivativeOrder + formalAccuracy - 1) `div` 2

    search radius
      | radius > maximumRadius =
          Left (NoCenteredTaylorStencil derivativeOrder formalAccuracy)
      | otherwise =
          case centeredTaylorAtRadius derivativeOrder formalAccuracy radius of
            Right stencil -> Right stencil
            Left (MomentSystemInconsistent _ _ _) -> search (radius + 1)
            Left (MomentSystemNotUnique _ _ _) -> search (radius + 1)
            Left (ZeroEdgeCoefficient _) -> search (radius + 1)
            Left err -> Left err

-- | Solve the complete moment system at one explicit radius.  The system is
-- generally rectangular: for even derivatives it contains one more moment
-- equation than unknown at the minimal radius.  Exact RREF detects whether
-- that overdetermined system is consistent and uniquely determined.
centeredTaylorAtRadius
    :: Int -> Int -> Int -> Either StencilError CenteredStencil
centeredTaylorAtRadius derivativeOrder formalAccuracy radius = do
  validateRequest derivativeOrder formalAccuracy
  let minimumRadius = minimumAdmissibleRadius derivativeOrder
  if radius < minimumRadius
    then Left (RadiusTooSmall radius minimumRadius)
    else do
      let offsets = [-radius .. radius]
          highestMoment = derivativeOrder + formalAccuracy - 1
          momentOrders = [0 .. highestMoment]
          coefficients =
            [ [integerPower offset momentOrder | offset <- offsets]
            | momentOrder <- momentOrders
            ]
          targets =
            [ if momentOrder == derivativeOrder
                then fromInteger (factorial derivativeOrder)
                else 0
            | momentOrder <- momentOrders
            ]
      weights <-
        case solveUnique coefficients targets of
          Inconsistent ->
            Left (MomentSystemInconsistent derivativeOrder formalAccuracy radius)
          NonUnique ->
            Left (MomentSystemNotUnique derivativeOrder formalAccuracy radius)
          Unique solution -> Right solution
      let stencil = CenteredStencil
            { centeredDerivativeOrder = derivativeOrder
            , centeredFormalAccuracy = formalAccuracy
            , centeredRadius = radius
            , centeredWeights = zip offsets weights
            }
      validateCenteredTaylor stencil
      return stencil

minimalCenteredRadius :: Int -> Int -> Either StencilError Int
minimalCenteredRadius derivativeOrder formalAccuracy =
  centeredRadius <$> centeredTaylor derivativeOrder formalAccuracy

-- | Solve the staggered moment system for an odd derivative order at an
-- explicit pair count k: 2k samples at the half-integer offsets
-- ±1/2 … ±(2k−1)/2, i.e. effective radius k − 1/2.  The system has one more
-- moment equation than unknown; exact RREF confirms the antisymmetric
-- solution satisfies it.
staggeredTaylorAtPairs
    :: Int -> Int -> Int -> Either StencilError StaggeredStencil
staggeredTaylorAtPairs derivativeOrder formalAccuracy pairs = do
  validateStaggeredRequest derivativeOrder formalAccuracy
  let minimumPairs = (derivativeOrder + 1) `div` 2
  if pairs < minimumPairs
    then Left (RadiusTooSmall pairs minimumPairs)
    else do
      let twiceOffsets = staggeredTwiceOffsets pairs
          highestMoment = derivativeOrder + formalAccuracy - 1
          momentOrders = [0 .. highestMoment]
          coefficients =
            [ [halfPower twiceOffset momentOrder | twiceOffset <- twiceOffsets]
            | momentOrder <- momentOrders
            ]
          targets =
            [ if momentOrder == derivativeOrder
                then fromInteger (factorial derivativeOrder)
                else 0
            | momentOrder <- momentOrders
            ]
      weights <-
        case solveUnique coefficients targets of
          Inconsistent ->
            Left (MomentSystemInconsistent derivativeOrder formalAccuracy pairs)
          NonUnique ->
            Left (MomentSystemNotUnique derivativeOrder formalAccuracy pairs)
          Unique solution -> Right solution
      let stencil = StaggeredStencil
            { staggeredDerivativeOrder = derivativeOrder
            , staggeredFormalAccuracy = formalAccuracy
            , staggeredPairCount = pairs
            , staggeredTwiceWeights = zip twiceOffsets weights
            }
      validateStaggeredTaylor stencil
      return stencil

-- | One boundary closure row.  The target sits 'sbpRowOffset' points inside
-- the boundary end; the weights sample storage offsets relative to that
-- target and the weighted sum is divided by h^order at lowering.
data SbpBoundaryRow = SbpBoundaryRow
  { sbpRowOffset :: Int
  , sbpRowWeights :: [(Int, Rational)]
  } deriving (Eq, Show)

-- | A staggered SBP pair on the bounded primal/dual grids: primal points
-- 0..N and dual points 1/2..N−1/2.  The primal-to-dual derivative keeps the
-- interior stage on every row; the dual-to-primal derivative replaces the
-- rows nearest each end with closure rows.  Together with the diagonal
-- norms (stored in h units, interior weight 1) and the dual-to-boundary
-- extrapolation vector, the pair satisfies the exact summation-by-parts
-- identity  H_d D⁺ + (H_p D⁻)ᵀ = d_N e_Nᵀ − d_0 e_0ᵀ.  The second-order
-- closure rows are the boundary rows of the exact composition D⁻ D⁺ for
-- integer-placed operands.
data SbpStaggeredPair = SbpStaggeredPair
  { sbpInteriorStage :: StaggeredStencil
  , sbpDualToPrimalLow :: [SbpBoundaryRow]
  , sbpDualToPrimalHigh :: [SbpBoundaryRow]
  , sbpSecondLow :: [SbpBoundaryRow]
  , sbpSecondHigh :: [SbpBoundaryRow]
  , sbpPrimalNorm :: [Rational]
  , sbpDualNorm :: [Rational]
  , sbpExtrapolate :: [(Int, Rational)]
  } deriving (Eq, Show)

-- | The staggered SBP pair with interior pair count k.  Only the classic
-- second-order pair (k = 1) is constructed: its primal-to-dual direction
-- needs no closure rows, the dual-to-primal direction gets one first-order
-- one-sided row per end, and the norms are the half-weighted trapezoid on
-- the primal grid and the identity on the dual grid.
sbpStaggeredPair :: Int -> Either StencilError SbpStaggeredPair
sbpStaggeredPair pairs
  | pairs /= 1 = Left (UnsupportedSbpInterior pairs)
  | otherwise = do
      stage <- staggeredTaylorAtPairs 1 2 1
      let pair = SbpStaggeredPair
            { sbpInteriorStage = stage
            , sbpDualToPrimalLow =
                [SbpBoundaryRow 0 [(0, -1), (1, 1)]]
            , sbpDualToPrimalHigh =
                [SbpBoundaryRow 0 [(-2, -1), (-1, 1)]]
            , sbpSecondLow =
                [SbpBoundaryRow 0 [(0, 1), (1, -2), (2, 1)]]
            , sbpSecondHigh =
                [SbpBoundaryRow 0 [(-2, 1), (-1, -2), (0, 1)]]
            , sbpPrimalNorm = [1 / 2]
            , sbpDualNorm = []
            , sbpExtrapolate = [(0, 3 / 2), (1, -1 / 2)]
            }
      validateSbpStaggeredPair pair 8
      validateSbpStaggeredPair pair 9
      return pair

-- | Recheck every invariant of a staggered SBP pair on the bounded grid
-- with N primal intervals: in-range samples, boundary-order accuracy of
-- all derivative rows, first-order extrapolation, positive norms, the
-- exact summation-by-parts identity, and agreement of the second-order
-- closure rows with the composition D⁻ D⁺.
validateSbpStaggeredPair
    :: SbpStaggeredPair -> Int -> Either StencilError ()
validateSbpStaggeredPair pair intervals = do
  let stage = sbpInteriorStage pair
      lowRows = length (sbpDualToPrimalLow pair)
      highRows = length (sbpDualToPrimalHigh pair)
      primalCount = intervals + 1
      dualCount = intervals
  if intervals >= 2 * (lowRows + highRows + 2)
    then return ()
    else Left (SbpGridTooSmall intervals (2 * (lowRows + highRows + 2)))
  primalToDual <- assemblePrimalToDual stage primalCount dualCount
  dualToPrimal <- assembleDualToPrimal pair primalCount dualCount
  let primalNorm = normDiagonal (sbpPrimalNorm pair) primalCount
      dualNorm = normDiagonal (sbpDualNorm pair) dualCount
      extrapolateLow = vectorAt (sbpExtrapolate pair) 0 dualCount
      extrapolateHigh = vectorAt
        [ (dualCount - 1 - offset, weight)
        | (offset, weight) <- sbpExtrapolate pair
        ]
        0 dualCount
  mapM_ (\(index, weight) ->
      if weight > 0
        then return ()
        else Left (SbpNormNotPositive index weight))
    (zip [0 ..] (primalNorm ++ dualNorm))
  checkExtrapolation extrapolateLow 0
  checkExtrapolation extrapolateHigh (fromIntegral intervals)
  mapM_ (checkDerivativeRow 1 dualToPrimal dualCoordinate primalCoordinate)
    [0 .. primalCount - 1]
  mapM_ (checkDerivativeRow 1 primalToDual primalCoordinate dualCoordinate)
    [0 .. dualCount - 1]
  checkSbpIdentity primalToDual dualToPrimal primalNorm dualNorm
    extrapolateLow extrapolateHigh primalCount dualCount
  checkSecondRows pair primalToDual dualToPrimal primalCount
  where
    primalCoordinate :: Int -> Rational
    primalCoordinate index = fromIntegral index

    dualCoordinate :: Int -> Rational
    dualCoordinate index = fromIntegral index + 1 / 2

    checkExtrapolation vector position = do
      let total = sum vector
          moment = sum
            [ weight * dualCoordinate index
            | (index, weight) <- zip [0 ..] vector
            ]
      if total == 1
        then return ()
        else Left (SbpExtrapolationMismatch 0 1 total)
      if moment == position
        then return ()
        else Left (SbpExtrapolationMismatch 1 position moment)

    checkDerivativeRow order matrix sampleCoordinate targetCoordinate row =
      mapM_ (checkMomentCondition order matrix sampleCoordinate
              targetCoordinate row)
        [0 .. order]

    checkMomentCondition order matrix sampleCoordinate targetCoordinate
        row power = do
      let actual = sum
            [ weight * sampleCoordinate column ^ power
            | (column, weight) <- zip [0 ..] (matrix !! row)
            ]
          expected
            | power < order = 0
            | otherwise =
                fromInteger (factorial power)
                * targetCoordinate row ^ (power - order)
      if actual == expected
        then return ()
        else Left (SbpAccuracyMismatch row power expected actual)

    checkSbpIdentity primalToDual dualToPrimal primalNorm dualNorm
        extrapolateLow extrapolateHigh primalCount dualCount =
      mapM_ (\(row, column) ->
          let combined =
                dualNorm !! row * (primalToDual !! row !! column)
                + primalNorm !! column * (dualToPrimal !! column !! row)
              expected =
                (if column == primalCount - 1
                   then extrapolateHigh !! row else 0)
                - (if column == 0 then extrapolateLow !! row else 0)
          in if combined == expected
               then return ()
               else Left (SbpIdentityMismatch row column expected combined))
        [ (row, column)
        | row <- [0 .. dualCount - 1]
        , column <- [0 .. primalCount - 1]
        ]

    checkSecondRows checked primalToDual dualToPrimal primalCount = do
      let composition =
            [ [ sum
                  [ (dualToPrimal !! row !! middle)
                    * (primalToDual !! middle !! column)
                  | middle <- [0 .. length primalToDual - 1]
                  ]
              | column <- [0 .. primalCount - 1]
              ]
            | row <- [0 .. primalCount - 1]
            ]
      composed <- assembleSecond checked primalCount
      mapM_ (\(row, column) ->
          let expected = composition !! row !! column
              actual = composed !! row !! column
          in if actual == expected
               then return ()
               else Left (SbpCompositionMismatch row column expected actual))
        [ (row, column)
        | row <- [0 .. primalCount - 1]
        , column <- [0 .. primalCount - 1]
        ]

assemblePrimalToDual
    :: StaggeredStencil -> Int -> Int -> Either StencilError [[Rational]]
assemblePrimalToDual stage primalCount dualCount =
  mapM buildRow [0 .. dualCount - 1]
  where
    buildRow row = do
      entries <- mapM (place row)
        [ ((twiceOffset + 1) `div` 2, weight)
        | (twiceOffset, weight) <- staggeredTwiceWeights stage
        ]
      return (rowVector entries primalCount)
    place row (offset, weight) =
      let column = row + offset
      in if column >= 0 && column < primalCount
           then Right (column, weight)
           else Left (SbpSampleOutOfRange row column)

assembleDualToPrimal
    :: SbpStaggeredPair -> Int -> Int -> Either StencilError [[Rational]]
assembleDualToPrimal pair primalCount dualCount =
  mapM buildRow [0 .. primalCount - 1]
  where
    lowRows = sbpDualToPrimalLow pair
    highRows = sbpDualToPrimalHigh pair
    stage = sbpInteriorStage pair

    buildRow row = do
      entries <- mapM (place row) (weightsFor row)
      return (rowVector entries dualCount)

    weightsFor row =
      case lookupRow row lowRows of
        Just weights -> weights
        Nothing ->
          case lookupRow (primalCount - 1 - row) highRows of
            Just weights -> weights
            Nothing ->
              [ ((twiceOffset - 1) `div` 2, weight)
              | (twiceOffset, weight) <- staggeredTwiceWeights stage
              ]

    lookupRow offset rows = lookup offset
      [(sbpRowOffset boundaryRow, sbpRowWeights boundaryRow)
      | boundaryRow <- rows]

    place row (offset, weight) =
      let column = row + offset
      in if column >= 0 && column < dualCount
           then Right (column, weight)
           else Left (SbpSampleOutOfRange row column)

assembleSecond
    :: SbpStaggeredPair -> Int -> Either StencilError [[Rational]]
assembleSecond pair primalCount = mapM buildRow [0 .. primalCount - 1]
  where
    buildRow row = do
      entries <- mapM (place row) (weightsFor row)
      return (rowVector entries primalCount)

    weightsFor row =
      case lookupRow row (sbpSecondLow pair) of
        Just weights -> weights
        Nothing ->
          case lookupRow (primalCount - 1 - row) (sbpSecondHigh pair) of
            Just weights -> weights
            Nothing -> [(-1, 1), (0, -2), (1, 1)]

    lookupRow offset rows = lookup offset
      [(sbpRowOffset boundaryRow, sbpRowWeights boundaryRow)
      | boundaryRow <- rows]

    place row (offset, weight) =
      let column = row + offset
      in if column >= 0 && column < primalCount
           then Right (column, weight)
           else Left (SbpSampleOutOfRange row column)

normDiagonal :: [Rational] -> Int -> [Rational]
normDiagonal edge count =
  [ weightAt index | index <- [0 .. count - 1] ]
  where
    weightAt index
      | index < length edge = edge !! index
      | count - 1 - index < length edge = edge !! (count - 1 - index)
      | otherwise = 1

vectorAt :: [(Int, Rational)] -> Rational -> Int -> [Rational]
vectorAt entries fill count =
  [ maybe fill id (lookup index entries) | index <- [0 .. count - 1] ]

rowVector :: [(Int, Rational)] -> Int -> [Rational]
rowVector entries count =
  [ sum [weight | (column, weight) <- entries, column == index]
  | index <- [0 .. count - 1]
  ]

-- | An n-fold self-composition of a half-offset stage: even fold counts
-- land back on the operand's sub-lattice, odd counts stay on the dual one.
data ComposedStencil
  = ComposedCentered CenteredStencil
  | ComposedStaggered StaggeredStencil
  deriving (Eq, Show)

-- | Compose an odd-order half-offset stage with itself n times.  The
-- stages alternate orientation across the two sub-lattices, so the result
-- is centered for even n and staggered for odd n, with derivative order
-- n·o and the staged formal accuracy: every stage shares the symbol
-- ∂^o·(1 + O(h^a)), so the first surviving error term of the product
-- annihilates polynomials up to degree n·o + a − 1.  The k = 1 pair
-- composes to [1, −2, 1] at n = 2, the four-point third derivative at
-- n = 3, and [1, −4, 6, −4, 1] at n = 4.
composeStages :: Int -> StaggeredStencil -> Either StencilError ComposedStencil
composeStages count stage = do
  validateStaggeredTaylor stage
  if count < 1
    then Left (InvalidDerivativeOrder count)
    else return ()
  let composedOrder = count * staggeredDerivativeOrder stage
      formalAccuracy = staggeredFormalAccuracy stage
      stageWeights = staggeredTwiceWeights stage
      folded = foldl convolve stageWeights
        (replicate (count - 1) stageWeights)
      reach = count * (2 * staggeredPairCount stage - 1)
      weightAt twiceOffset =
        sum [w | (o, w) <- folded, o == twiceOffset]
  if odd count
    then do
      let stencil = StaggeredStencil
            { staggeredDerivativeOrder = composedOrder
            , staggeredFormalAccuracy = formalAccuracy
            , staggeredPairCount = (reach + 1) `div` 2
            , staggeredTwiceWeights =
                [ (twiceOffset, weightAt twiceOffset)
                | twiceOffset <- [negate reach, negate reach + 2 .. reach]
                ]
            }
      validateStaggeredTaylor stencil
      return (ComposedStaggered stencil)
    else do
      let stencil = CenteredStencil
            { centeredDerivativeOrder = composedOrder
            , centeredFormalAccuracy = formalAccuracy
            , centeredRadius = reach `div` 2
            , centeredWeights =
                [ (twiceOffset `div` 2, weightAt twiceOffset)
                | twiceOffset <- [negate reach, negate reach + 2 .. reach]
                ]
            }
      validateCenteredTaylor stencil
      return (ComposedCentered stencil)
  where
    convolve accumulated next =
      [ (ta + tb, wa * wb)
      | (ta, wa) <- accumulated
      , (tb, wb) <- next
      ]

-- | Recheck all invariants required of a staggered Taylor stencil: canonical
-- doubled offsets, the full formal-accuracy moment range, antisymmetric
-- parity, and a nonzero coefficient on both halo edges.
validateStaggeredTaylor :: StaggeredStencil -> Either StencilError ()
validateStaggeredTaylor stencil = do
  validateStaggeredRequest derivativeOrder formalAccuracy
  let minimumPairs = (derivativeOrder + 1) `div` 2
  if pairs < minimumPairs
    then Left (RadiusTooSmall pairs minimumPairs)
    else return ()
  validateStaggeredOffsets stencil
  validateStaggeredMoments stencil
  validateStaggeredParity stencil
  validateStaggeredEdges stencil
  where
    derivativeOrder = staggeredDerivativeOrder stencil
    formalAccuracy = staggeredFormalAccuracy stencil
    pairs = staggeredPairCount stencil

validateStaggeredRequest :: Int -> Int -> Either StencilError ()
validateStaggeredRequest derivativeOrder formalAccuracy
  | derivativeOrder < 1 = Left (InvalidDerivativeOrder derivativeOrder)
  | even derivativeOrder = Left (StaggeredOrderMustBeOdd derivativeOrder)
  | formalAccuracy < 1 || odd formalAccuracy =
      Left (InvalidFormalAccuracy formalAccuracy)
  | otherwise = Right ()

staggeredTwiceOffsets :: Int -> [Int]
staggeredTwiceOffsets pairs =
  [negate (2 * pairs - 1), negate (2 * pairs - 3) .. 2 * pairs - 1]

validateStaggeredOffsets :: StaggeredStencil -> Either StencilError ()
validateStaggeredOffsets stencil
  | actual == expected = Right ()
  | otherwise = Left (InvalidOffsetLayout expected actual)
  where
    expected = staggeredTwiceOffsets (staggeredPairCount stencil)
    actual = map fst (staggeredTwiceWeights stencil)

validateStaggeredMoments :: StaggeredStencil -> Either StencilError ()
validateStaggeredMoments stencil = check [0 .. highestMoment]
  where
    derivativeOrder = staggeredDerivativeOrder stencil
    highestMoment = derivativeOrder + staggeredFormalAccuracy stencil - 1

    check [] = Right ()
    check (momentOrder : rest)
      | actual == expected = check rest
      | otherwise = Left (MomentMismatch momentOrder expected actual)
      where
        actual = staggeredMomentValue stencil momentOrder
        expected
          | momentOrder == derivativeOrder =
              fromInteger (factorial derivativeOrder)
          | otherwise = 0

validateStaggeredParity :: StaggeredStencil -> Either StencilError ()
validateStaggeredParity stencil =
  check [1, 3 .. 2 * staggeredPairCount stencil - 1]
  where
    weightAt twiceOffset =
      case lookup twiceOffset (staggeredTwiceWeights stencil) of
        Just weight -> weight
        Nothing -> 0

    check [] = Right ()
    check (twiceOffset : rest)
      | negativeWeight == negate positiveWeight = check rest
      | otherwise =
          Left (ParityMismatch twiceOffset
            (negate positiveWeight) negativeWeight)
      where
        positiveWeight = weightAt twiceOffset
        negativeWeight = weightAt (0 - twiceOffset)

validateStaggeredEdges :: StaggeredStencil -> Either StencilError ()
validateStaggeredEdges stencil = check [0 - edge, edge]
  where
    edge = 2 * staggeredPairCount stencil - 1

    check [] = Right ()
    check (twiceOffset : rest) =
      case lookup twiceOffset (staggeredTwiceWeights stencil) of
        Just coefficient
          | coefficient /= 0 -> check rest
        _ -> Left (ZeroEdgeCoefficient twiceOffset)

staggeredMomentValue :: StaggeredStencil -> Int -> Rational
staggeredMomentValue stencil momentOrder =
  sum
    [ coefficient * halfPower twiceOffset momentOrder
    | (twiceOffset, coefficient) <- staggeredTwiceWeights stencil
    ]

halfPower :: Int -> Int -> Rational
halfPower twiceOffset power =
  (fromIntegral twiceOffset / 2) ^ power

-- | The exact, unscaled q-th moment sum_s c_s s^q.
stencilMoment :: CenteredStencil -> Int -> Either StencilError Rational
stencilMoment stencil momentOrder
  | momentOrder < 0 = Left (InvalidMomentOrder momentOrder)
  | otherwise = Right (momentValue stencil momentOrder)

-- | Recheck all invariants required of a centered Taylor stencil: canonical
-- offsets, the full formal-accuracy moment range, centered parity, and a
-- nonzero coefficient on both halo edges.
validateCenteredTaylor :: CenteredStencil -> Either StencilError ()
validateCenteredTaylor stencil = do
  validateRequest derivativeOrder formalAccuracy
  let minimumRadius = minimumAdmissibleRadius derivativeOrder
  if radius < minimumRadius
    then Left (RadiusTooSmall radius minimumRadius)
    else return ()
  validateOffsets stencil
  validateMoments stencil
  validateParity stencil
  validateEdges stencil
  where
    derivativeOrder = centeredDerivativeOrder stencil
    formalAccuracy = centeredFormalAccuracy stencil
    radius = centeredRadius stencil

validateRequest :: Int -> Int -> Either StencilError ()
validateRequest derivativeOrder formalAccuracy
  | derivativeOrder < 1 = Left (InvalidDerivativeOrder derivativeOrder)
  | formalAccuracy < 1 || odd formalAccuracy =
      Left (InvalidFormalAccuracy formalAccuracy)
  | otherwise = Right ()

minimumAdmissibleRadius :: Int -> Int
minimumAdmissibleRadius derivativeOrder =
  max 1 ((derivativeOrder + 1) `div` 2)

validateOffsets :: CenteredStencil -> Either StencilError ()
validateOffsets stencil
  | actual == expected = Right ()
  | otherwise = Left (InvalidOffsetLayout expected actual)
  where
    radius = centeredRadius stencil
    expected = [-radius .. radius]
    actual = map fst (centeredWeights stencil)

validateMoments :: CenteredStencil -> Either StencilError ()
validateMoments stencil = check [0 .. highestMoment]
  where
    derivativeOrder = centeredDerivativeOrder stencil
    highestMoment = derivativeOrder + centeredFormalAccuracy stencil - 1

    check [] = Right ()
    check (momentOrder : rest)
      | actual == expected = check rest
      | otherwise = Left (MomentMismatch momentOrder expected actual)
      where
        actual = momentValue stencil momentOrder
        expected
          | momentOrder == derivativeOrder =
              fromInteger (factorial derivativeOrder)
          | otherwise = 0

validateParity :: CenteredStencil -> Either StencilError ()
validateParity stencil = check [0 .. centeredRadius stencil]
  where
    paritySign :: Rational
    paritySign = if even (centeredDerivativeOrder stencil) then 1 else -1

    weightAt offset =
      case lookup offset (centeredWeights stencil) of
        Just weight -> weight
        Nothing -> 0

    check [] = Right ()
    check (offset : rest)
      | negativeWeight == expectedNegative = check rest
      | otherwise =
          Left (ParityMismatch offset expectedNegative negativeWeight)
      where
        positiveWeight = weightAt offset
        negativeWeight = weightAt (0 - offset)
        expectedNegative = paritySign * positiveWeight

validateEdges :: CenteredStencil -> Either StencilError ()
validateEdges stencil = check [0 - radius, radius]
  where
    radius = centeredRadius stencil

    check [] = Right ()
    check (offset : rest) =
      case lookup offset (centeredWeights stencil) of
        Just coefficient
          | coefficient /= 0 -> check rest
        _ -> Left (ZeroEdgeCoefficient offset)

momentValue :: CenteredStencil -> Int -> Rational
momentValue stencil momentOrder =
  sum
    [ coefficient * integerPower offset momentOrder
    | (offset, coefficient) <- centeredWeights stencil
    ]

integerPower :: Int -> Int -> Rational
integerPower base power = fromInteger ((toInteger base) ^ power)

factorial :: Int -> Integer
factorial n = product [1 .. toInteger n]

data LinearSolution
  = Inconsistent
  | NonUnique
  | Unique [Rational]

-- Exact Gauss-Jordan elimination for an m-by-n coefficient matrix.  Rows may
-- outnumber columns; consistency and column rank are checked independently.
solveUnique :: [[Rational]] -> [Rational] -> LinearSolution
solveUnique [] _ = NonUnique
solveUnique coefficients@(firstRow : _) targets =
  let columnCount = length firstRow
      augmented = zipWith (\row target -> row ++ [target]) coefficients targets
      (reduced, pivots) = rref columnCount augmented
      inconsistent row =
        all (== 0) (take columnCount row) && last row /= 0
  in if any inconsistent reduced
       then Inconsistent
       else if length pivots /= columnCount
         then NonUnique
         else Unique
           [ last (reduced !! pivotRow)
           | column <- [0 .. columnCount - 1]
           , let pivotRow = pivotRowFor column pivots
           ]

pivotRowFor :: Int -> [(Int, Int)] -> Int
pivotRowFor column pivots =
  case lookup column pivots of
    Just row -> row
    Nothing -> error "internal error: full-rank RREF is missing a pivot column"

rref :: Int -> [[Rational]] -> ([[Rational]], [(Int, Int)])
rref columnCount rows0 = go 0 0 rows0 []
  where
    rowCount = length rows0

    go pivotRow column rows pivots
      | pivotRow >= rowCount || column >= columnCount = (rows, pivots)
      | otherwise =
          case findIndex (\row -> row !! column /= 0) (drop pivotRow rows) of
            Nothing -> go pivotRow (column + 1) rows pivots
            Just relativeRow ->
              let selectedRow = pivotRow + relativeRow
                  swapped = swapRows pivotRow selectedRow rows
                  pivot = (swapped !! pivotRow) !! column
                  normalizedPivot = map (/ pivot) (swapped !! pivotRow)
                  withPivot = replaceAt pivotRow normalizedPivot swapped
                  eliminated =
                    [ if rowIndex == pivotRow
                        then normalizedPivot
                        else eliminate column normalizedPivot row
                    | (rowIndex, row) <- zip [0 ..] withPivot
                    ]
              in go (pivotRow + 1) (column + 1) eliminated
                   (pivots ++ [(column, pivotRow)])

    eliminate column pivotRow row =
      let multiplier = row !! column
      in zipWith (-) row (map (* multiplier) pivotRow)

swapRows :: Int -> Int -> [a] -> [a]
swapRows first second rows
  | first == second = rows
  | otherwise =
      let firstRow = rows !! first
          secondRow = rows !! second
      in replaceAt second firstRow (replaceAt first secondRow rows)

replaceAt :: Int -> a -> [a] -> [a]
replaceAt index value values =
  take index values ++ [value] ++ drop (index + 1) values
