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
  , composedInteriorWeights
  , sbpMinimumIntervals
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
-- 0..N and dual points 1/2..N−1/2.  Both derivative directions keep the
-- interior stage away from the walls and replace the rows nearest each end
-- with closure rows (the primal-to-dual closure lists are empty exactly
-- when the interior stage never reaches outside, as at pair count one).
-- Together with the diagonal norms (stored in h units, interior weight 1)
-- and the dual-to-boundary extrapolation vector, the pair satisfies the
-- exact summation-by-parts identity
-- H_d D⁺ + (H_p D⁻)ᵀ = d_N e_Nᵀ − d_0 e_0ᵀ.  The second-order closure
-- rows are the boundary rows of the exact composition D⁻ D⁺ for
-- integer-placed operands.
data SbpStaggeredPair = SbpStaggeredPair
  { sbpInteriorStage :: StaggeredStencil
  , sbpPrimalToDualLow :: [SbpBoundaryRow]
  , sbpPrimalToDualHigh :: [SbpBoundaryRow]
  , sbpDualToPrimalLow :: [SbpBoundaryRow]
  , sbpDualToPrimalHigh :: [SbpBoundaryRow]
  , sbpSecondLow :: [SbpBoundaryRow]
  , sbpSecondHigh :: [SbpBoundaryRow]
  , sbpPrimalNorm :: [Rational]
  , sbpDualNorm :: [Rational]
  , sbpExtrapolate :: [(Int, Rational)]
  } deriving (Eq, Show)

-- | The staggered SBP pair with interior pair count k.  The classic
-- second-order pair (k = 1) is written in closed form: its primal-to-dual
-- direction needs no closure rows, the dual-to-primal direction gets one
-- first-order one-sided row per end, and the norms are the half-weighted
-- trapezoid on the primal grid and the identity on the dual grid.  Wider
-- interiors are constructed by 'constructSbpStaggeredPair' as the exact
-- solution of the linear closure system.
sbpStaggeredPair :: Int -> Either StencilError SbpStaggeredPair
sbpStaggeredPair pairs
  | pairs < 1 = Left (UnsupportedSbpInterior pairs)
  | pairs == 1 = do
      stage <- staggeredTaylorAtPairs 1 2 1
      let pair = SbpStaggeredPair
            { sbpInteriorStage = stage
            , sbpPrimalToDualLow = []
            , sbpPrimalToDualHigh = []
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
  | otherwise = constructSbpStaggeredPair pairs

-- ------------------------------------------------ general closure system

-- | One unknown of the linear closure system.  The declaration order below
-- is the canonical column order of the solve: norms and the extrapolation
-- vector first, then the closure coefficients near-sample-first, so the
-- zeroed free parameters of 'solveFreeZero' land on the far coefficients.
data SbpUnknown
  = UnknownPrimalNorm Int
  | UnknownDualNorm Int
  | UnknownExtrapolation Int
  | UnknownDualToPrimal Int Int
  | UnknownPrimalToDual Int Int
  deriving (Eq, Ord, Show)

-- | Structural shape of one one-sided closure candidate: how many rows of
-- each direction deviate from the interior stage, the column support of
-- those rows, and the width of the boundary extrapolation vector.
data SbpStructure = SbpStructure
  { structurePrimalToDualRows :: Int
  , structureDualToPrimalRows :: Int
  , structurePrimalToDualWidth :: Int
  , structureDualToPrimalWidth :: Int
  , structureExtrapolationWidth :: Int
  } deriving (Eq, Show)

-- | A linear expression over the closure unknowns with an exact constant
-- part.  Every closure condition below is affine in these unknowns.
data SbpLinear = SbpLinear
  { linearConstant :: Rational
  , linearTerms :: [(SbpUnknown, Rational)]
  }

linearKnown :: Rational -> SbpLinear
linearKnown value = SbpLinear value []

linearUnknown :: SbpUnknown -> SbpLinear
linearUnknown unknown = SbpLinear 0 [(unknown, 1)]

linearScale :: Rational -> SbpLinear -> SbpLinear
linearScale factor (SbpLinear constant terms) =
  SbpLinear (factor * constant)
    [(unknown, factor * weight) | (unknown, weight) <- terms]

linearSum :: [SbpLinear] -> SbpLinear
linearSum expressions = SbpLinear
  (sum (map linearConstant expressions))
  (concatMap linearTerms expressions)

-- | Construct the pair with interior pair count k ≥ 2 as the exact
-- solution of the linear closure system.  With Q⁺ = H_d D⁺ and
-- Q⁻ = H_p D⁻ taken as the unknowns, the boundary-accuracy conditions,
-- the summation-by-parts identity, and the extrapolation-accuracy
-- conditions are all affine, so one exact reduction both decides
-- solvability and produces the canonical representative (free parameters
-- fixed to zero, far coefficients first).  Structures are searched from
-- the smallest: closure row counts grow together, then the row support,
-- then the extrapolation width.  The first candidate whose solution has
-- positive norms and passes the full finite-interval validation wins;
-- rational optimization families are deliberately not considered.
constructSbpStaggeredPair :: Int -> Either StencilError SbpStaggeredPair
constructSbpStaggeredPair pairs = do
  stage <- staggeredTaylorAtPairs 1 (2 * pairs) pairs
  search stage (candidateClosureStructures pairs)
  where
    search _ [] = Left (UnsupportedSbpInterior pairs)
    search stage (structure : rest) =
      case solveClosureStructure pairs stage structure of
        Just pair -> Right pair
        Nothing -> search stage rest

candidateClosureStructures :: Int -> [SbpStructure]
candidateClosureStructures pairs =
  [ SbpStructure
      { structurePrimalToDualRows = primalToDualRows
      , structureDualToPrimalRows = dualToPrimalRows
      , structurePrimalToDualWidth = primalToDualRows + pairs + widen
      , structureDualToPrimalWidth = dualToPrimalRows + pairs - 1 + widen
      , structureExtrapolationWidth = extrapolationWidth
      }
  | grow <- [0 .. 3]
  , widen <- [0 .. 2]
  , extrapolationWidth <- [pairs + 1 .. pairs + 3]
  , let primalToDualRows = pairs - 1 + grow
        dualToPrimalRows = pairs + grow
  ]

-- | Solve one closure structure exactly; Nothing rejects the candidate
-- (inconsistent system, an interior identity violation, a nonpositive
-- norm, or a failed finite-interval validation).
solveClosureStructure
    :: Int -> StaggeredStencil -> SbpStructure -> Maybe SbpStaggeredPair
solveClosureStructure pairs stage structure = do
  equations <- closureEquations pairs stage structure
  let unknowns = closureUnknowns structure
      matrix =
        [ [ maybe 0 id (lookup unknown collected)
          | unknown <- unknowns
          ]
        | SbpLinear _ terms <- equations
        , let collected = collectTerms terms
        ]
      targets = [negate constant | SbpLinear constant _ <- equations]
  solution <- solveFreeZero matrix targets
  let valueOf unknown =
        case lookup unknown (zip unknowns solution) of
          Just value -> value
          Nothing -> 0
      primalNorms =
        [ valueOf (UnknownPrimalNorm index)
        | index <- [0 .. structureDualToPrimalRows structure - 1]
        ]
      dualNorms =
        [ valueOf (UnknownDualNorm index)
        | index <- [0 .. structurePrimalToDualRows structure - 1]
        ]
      extrapolation =
        [ (index, value)
        | index <- [0 .. structureExtrapolationWidth structure - 1]
        , let value = valueOf (UnknownExtrapolation index)
        , value /= 0
        ]
      dualToPrimalRow row =
        SbpBoundaryRow row
          [ (column - row, valueOf (UnknownDualToPrimal row column)
              / (primalNorms !! row))
          | column <- [0 .. structureDualToPrimalWidth structure - 1]
          , valueOf (UnknownDualToPrimal row column) /= 0
          ]
      primalToDualRow row =
        SbpBoundaryRow row
          [ (column - row, valueOf (UnknownPrimalToDual row column)
              / (dualNorms !! row))
          | column <- [0 .. structurePrimalToDualWidth structure - 1]
          , valueOf (UnknownPrimalToDual row column) /= 0
          ]
  if all (> 0) (primalNorms ++ dualNorms)
    then Just ()
    else Nothing
  -- The canonical solution may reproduce the interior stage on a row whose
  -- samples already stay in range; such a row is a redundant guard, so it
  -- falls back to the interior mapping instead of becoming a closure row.
  let interiorDualToPrimal =
        [ ((twiceOffset - 1) `div` 2, weight)
        | (twiceOffset, weight) <- staggeredTwiceWeights stage
        ]
      interiorPrimalToDual =
        [ ((twiceOffset + 1) `div` 2, weight)
        | (twiceOffset, weight) <- staggeredTwiceWeights stage
        ]
      essentialRows interior rows =
        [row | row <- rows, sbpRowWeights row /= interior]
      dualToPrimalLow = essentialRows interiorDualToPrimal
        (map dualToPrimalRow
          [0 .. structureDualToPrimalRows structure - 1])
      primalToDualLow = essentialRows interiorPrimalToDual
        (map primalToDualRow
          [0 .. structurePrimalToDualRows structure - 1])
      withoutSecond = SbpStaggeredPair
        { sbpInteriorStage = stage
        , sbpPrimalToDualLow = primalToDualLow
        , sbpPrimalToDualHigh = map (mirrorOddRow 1) primalToDualLow
        , sbpDualToPrimalLow = dualToPrimalLow
        , sbpDualToPrimalHigh = map (mirrorOddRow (-1)) dualToPrimalLow
        , sbpSecondLow = []
        , sbpSecondHigh = []
        , sbpPrimalNorm = primalNorms
        , sbpDualNorm = dualNorms
        , sbpExtrapolate = extrapolation
        }
  secondLow <- deriveSecondClosureRows pairs withoutSecond
  let pair = withoutSecond
        { sbpSecondLow = secondLow
        , sbpSecondHigh = map mirrorEvenRow secondLow
        }
      intervals = sbpMinimumIntervals pair
  case validateSbpStaggeredPair pair intervals
         >> validateSbpStaggeredPair pair (intervals + 1) of
    Right () -> Just pair
    Left _ -> Nothing
  where
    collectTerms terms =
      [ (unknown, sum [weight | (candidate, weight) <- terms,
                                candidate == unknown])
      | unknown <- unique (map fst terms)
      ]
    unique = foldr (\value seen ->
      if value `elem` seen then seen else value : seen) []

-- | Mirror one closure row to the opposite end.  Odd (first-derivative)
-- rows flip sign; the sample of the low row at target offset o sits at
-- mirrored offset shift − o, where the shift is +1 for the primal-to-dual
-- orientation and −1 for the dual-to-primal one.  Even (second-derivative)
-- rows keep their weights with reflected offsets.
mirrorOddRow :: Int -> SbpBoundaryRow -> SbpBoundaryRow
mirrorOddRow shift (SbpBoundaryRow offset weights) =
  SbpBoundaryRow offset
    [(shift - column, negate weight) | (column, weight) <- weights]

mirrorEvenRow :: SbpBoundaryRow -> SbpBoundaryRow
mirrorEvenRow (SbpBoundaryRow offset weights) =
  SbpBoundaryRow offset
    [(negate column, weight) | (column, weight) <- weights]

closureUnknowns :: SbpStructure -> [SbpUnknown]
closureUnknowns structure =
  [ UnknownPrimalNorm index
  | index <- [0 .. structureDualToPrimalRows structure - 1]
  ]
  ++ [ UnknownDualNorm index
     | index <- [0 .. structurePrimalToDualRows structure - 1]
     ]
  ++ [ UnknownExtrapolation index
     | index <- [0 .. structureExtrapolationWidth structure - 1]
     ]
  ++ [ UnknownDualToPrimal row column
     | row <- [0 .. structureDualToPrimalRows structure - 1]
     , column <- [0 .. structureDualToPrimalWidth structure - 1]
     ]
  ++ [ UnknownPrimalToDual row column
     | row <- [0 .. structurePrimalToDualRows structure - 1]
     , column <- [0 .. structurePrimalToDualWidth structure - 1]
     ]

-- | All closure conditions of one structure as affine equations equal to
-- zero: boundary-row accuracy through the boundary order (the pair count),
-- the entrywise summation-by-parts identity over the affected corner, and
-- extrapolation accuracy of the boundary vector.  Corner entries that are
-- pure interior must satisfy the identity identically; a violation rejects
-- the structure.
closureEquations
    :: Int -> StaggeredStencil -> SbpStructure -> Maybe [SbpLinear]
closureEquations pairs stage structure = do
  identityRows <- mapM identityEquation
    [ (dualRow, primalColumn)
    | dualRow <- [0 .. zoneSize - 1]
    , primalColumn <- [0 .. zoneSize - 1]
    ]
  Just (accuracyPlus ++ accuracyMinus ++ concat identityRows
        ++ extrapolationAccuracy)
  where
    boundaryOrder = pairs
    zoneSize = maximum
      [ structurePrimalToDualWidth structure
      , structureDualToPrimalWidth structure
      , structureExtrapolationWidth structure
      , structurePrimalToDualRows structure
      , structureDualToPrimalRows structure
      ] + 2 * pairs + 2

    primalCoordinate column = fromIntegral column :: Rational
    dualCoordinate row = fromIntegral row + 1 / 2 :: Rational

    stageWeightAt twiceOffset =
      case lookup twiceOffset (staggeredTwiceWeights stage) of
        Just weight -> weight
        Nothing -> 0

    -- Q⁺ = H_d D⁺ entry at (dual row, primal column).
    quadraturePlus dualRow primalColumn
      | dualRow < structurePrimalToDualRows structure =
          if primalColumn < structurePrimalToDualWidth structure
            then linearUnknown (UnknownPrimalToDual dualRow primalColumn)
            else linearKnown 0
      | otherwise =
          linearKnown (stageWeightAt (2 * (primalColumn - dualRow) - 1))

    -- Q⁻ = H_p D⁻ entry at (primal row, dual column).
    quadratureMinus primalRow dualColumn
      | primalRow < structureDualToPrimalRows structure =
          if dualColumn < structureDualToPrimalWidth structure
            then linearUnknown (UnknownDualToPrimal primalRow dualColumn)
            else linearKnown 0
      | otherwise =
          linearKnown (stageWeightAt (2 * (dualColumn - primalRow) + 1))

    extrapolationEntry dualRow
      | dualRow < structureExtrapolationWidth structure =
          linearUnknown (UnknownExtrapolation dualRow)
      | otherwise = linearKnown 0

    powerOrZero base count
      | count < 0 = 0
      | otherwise = base ^ count

    accuracyPlus =
      [ linearSum
          ( [ linearScale (primalCoordinate column ^ power)
                (quadraturePlus row column)
            | column <- [0 .. structurePrimalToDualWidth structure - 1]
            ]
          ++ [ linearScale
                 (negate (fromIntegral power
                          * powerOrZero (dualCoordinate row) (power - 1)))
                 (linearUnknown (UnknownDualNorm row))
             | power >= 1
             ] )
      | row <- [0 .. structurePrimalToDualRows structure - 1]
      , power <- [0 .. boundaryOrder]
      ]

    accuracyMinus =
      [ linearSum
          ( [ linearScale (dualCoordinate column ^ power)
                (quadratureMinus row column)
            | column <- [0 .. structureDualToPrimalWidth structure - 1]
            ]
          ++ [ linearScale
                 (negate (fromIntegral power
                          * powerOrZero (primalCoordinate row) (power - 1)))
                 (linearUnknown (UnknownPrimalNorm row))
             | power >= 1
             ] )
      | row <- [0 .. structureDualToPrimalRows structure - 1]
      , power <- [0 .. boundaryOrder]
      ]

    identityEquation (dualRow, primalColumn) =
      let equation = linearSum
            ( [ quadraturePlus dualRow primalColumn
              , quadratureMinus primalColumn dualRow
              ]
            ++ [extrapolationEntry dualRow | primalColumn == 0] )
      in case linearTerms equation of
           [] | linearConstant equation == 0 -> Just []
              | otherwise -> Nothing
           _ -> Just [equation]

    extrapolationAccuracy =
      [ linearSum
          ( linearKnown (if power == 0 then -1 else 0)
          : [ linearScale (dualCoordinate row ^ power)
                (extrapolationEntry row)
            | row <- [0 .. structureExtrapolationWidth structure - 1]
            ] )
      | power <- [0 .. boundaryOrder]
      ]

-- | The second-derivative closure rows are read off the exact composition
-- D⁻ D⁺ on a segment long enough that the two ends cannot interact: the
-- deviating rows must form a contiguous prefix, and everything beyond it
-- must equal the composed interior stencil.
deriveSecondClosureRows :: Int -> SbpStaggeredPair -> Maybe [SbpBoundaryRow]
deriveSecondClosureRows pairs pair = do
  composed <- case composeStages 2 (sbpInteriorStage pair) of
    Right (ComposedCentered stencil) -> Just stencil
    _ -> Nothing
  let interiorRadius = centeredRadius composed
      rowBound = structureBound + interiorRadius + 1
      intervals = 2 * rowBound + 2 * interiorRadius + 4
      primalCount = intervals + 1
      dualCount = intervals
  primalToDual <- eitherToMaybe
    (assemblePrimalToDual pair primalCount dualCount)
  dualToPrimal <- eitherToMaybe
    (assembleDualToPrimal pair primalCount dualCount)
  let productRow row =
        [ sum
            [ (dualToPrimal !! row !! middle)
              * (primalToDual !! middle !! column)
            | middle <- [0 .. dualCount - 1]
            ]
        | column <- [0 .. primalCount - 1]
        ]
      interiorRow row = rowVector
        [ (row + offset, weight)
        | (offset, weight) <- centeredWeights composed
        ]
        primalCount
      matchesInterior row =
        row >= interiorRadius && productRow row == interiorRow row
      deviating = [row | row <- [0 .. rowBound], not (matchesInterior row)]
  if deviating == [0 .. length deviating - 1]
    then Just ()
    else Nothing
  Just
    [ SbpBoundaryRow row
        [ (column - row, weight)
        | (column, weight) <- zip [0 ..] (productRow row)
        , weight /= 0
        ]
    | row <- deviating
    ]
  where
    structureBound =
      length (sbpDualToPrimalLow pair)
      + length (sbpPrimalToDualLow pair) + 2 * pairs
    eitherToMaybe = either (const Nothing) Just

-- | The smallest interval count on which the two ends of the pair are
-- fully decoupled: closure rows of both ends plus the interior reach never
-- overlap, every boundary-row support fits, and the extrapolation vector
-- fits on the dual grid.
sbpMinimumIntervals :: SbpStaggeredPair -> Int
sbpMinimumIntervals pair = maximum
  ( 4
  : length (sbpDualToPrimalLow pair) + length (sbpDualToPrimalHigh pair)
      + 2 * stagePairs + 2
  : length (sbpPrimalToDualLow pair) + length (sbpPrimalToDualHigh pair)
      + 2 * stagePairs + 2
  : length (sbpSecondLow pair) + length (sbpSecondHigh pair)
      + 2 * (2 * stagePairs - 1) + 2
  : structureExtrapolationReach + 1
  : map lowRowReach (sbpDualToPrimalLow pair ++ sbpPrimalToDualLow pair
      ++ sbpSecondLow pair)
  )
  where
    stagePairs = staggeredPairCount (sbpInteriorStage pair)
    lowRowReach (SbpBoundaryRow offset weights) =
      offset + maximum (0 : map fst weights) + 2
    structureExtrapolationReach =
      maximum (0 : map fst (sbpExtrapolate pair))

-- | Recheck every invariant of a staggered SBP pair on the bounded grid
-- with N primal intervals: in-range samples, boundary-order accuracy of
-- all derivative rows, first-order extrapolation, positive norms, the
-- exact summation-by-parts identity, and agreement of the second-order
-- closure rows with the composition D⁻ D⁺.
validateSbpStaggeredPair
    :: SbpStaggeredPair -> Int -> Either StencilError ()
validateSbpStaggeredPair pair intervals = do
  let primalCount = intervals + 1
      dualCount = intervals
      minimumIntervals = sbpMinimumIntervals pair
  if intervals >= minimumIntervals
    then return ()
    else Left (SbpGridTooSmall intervals minimumIntervals)
  primalToDual <- assemblePrimalToDual pair primalCount dualCount
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
    :: SbpStaggeredPair -> Int -> Int -> Either StencilError [[Rational]]
assemblePrimalToDual pair primalCount dualCount =
  mapM buildRow [0 .. dualCount - 1]
  where
    lowRows = sbpPrimalToDualLow pair
    highRows = sbpPrimalToDualHigh pair
    stage = sbpInteriorStage pair

    buildRow row = do
      entries <- mapM (place row) (weightsFor row)
      return (rowVector entries primalCount)

    weightsFor row =
      case lookupRow row lowRows of
        Just weights -> weights
        Nothing ->
          case lookupRow (dualCount - 1 - row) highRows of
            Just weights -> weights
            Nothing ->
              [ ((twiceOffset + 1) `div` 2, weight)
              | (twiceOffset, weight) <- staggeredTwiceWeights stage
              ]

    lookupRow offset rows = lookup offset
      [(sbpRowOffset boundaryRow, sbpRowWeights boundaryRow)
      | boundaryRow <- rows]

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
assembleSecond pair primalCount = do
  interiorWeights <- composedInteriorWeights (sbpInteriorStage pair)
  mapM (buildRow interiorWeights) [0 .. primalCount - 1]
  where
    buildRow interiorWeights row = do
      entries <- mapM (place row) (weightsFor interiorWeights row)
      return (rowVector entries primalCount)

    weightsFor interiorWeights row =
      case lookupRow row (sbpSecondLow pair) of
        Just weights -> weights
        Nothing ->
          case lookupRow (primalCount - 1 - row) (sbpSecondHigh pair) of
            Just weights -> weights
            Nothing -> interiorWeights

    lookupRow offset rows = lookup offset
      [(sbpRowOffset boundaryRow, sbpRowWeights boundaryRow)
      | boundaryRow <- rows]

    place row (offset, weight) =
      let column = row + offset
      in if column >= 0 && column < primalCount
           then Right (column, weight)
           else Left (SbpSampleOutOfRange row column)

-- | The interior stencil of the composed second derivative: the exact
-- self-composition of the pair's first-derivative stage ([1, −2, 1] at
-- pair count one).
composedInteriorWeights
    :: StaggeredStencil -> Either StencilError [(Int, Rational)]
composedInteriorWeights stage = do
  composed <- composeStages 2 stage
  case composed of
    ComposedCentered stencil -> Right (centeredWeights stencil)
    ComposedStaggered _ ->
      error "internal error: an even composition must be centered"

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

-- | The canonical particular solution of a consistent system: every
-- non-pivot unknown is fixed to zero, so the column order of the caller
-- selects which free parameters vanish.  Nothing reports inconsistency.
solveFreeZero :: [[Rational]] -> [Rational] -> Maybe [Rational]
solveFreeZero [] _ = Nothing
solveFreeZero coefficients@(firstRow : _) targets =
  let columnCount = length firstRow
      augmented = zipWith (\row target -> row ++ [target]) coefficients targets
      (reduced, pivots) = rref columnCount augmented
      inconsistent row =
        all (== 0) (take columnCount row) && last row /= 0
  in if any inconsistent reduced
       then Nothing
       else Just
         [ case lookup column pivots of
             Just pivotRow -> last (reduced !! pivotRow)
             Nothing -> 0
         | column <- [0 .. columnCount - 1]
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
