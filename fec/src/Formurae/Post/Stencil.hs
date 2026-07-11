module Formurae.Post.Stencil
  ( CenteredStencil
  , StencilError(..)
  , centeredDerivativeOrder
  , centeredFormalAccuracy
  , centeredRadius
  , centeredWeights
  , centeredTaylor
  , centeredTaylorAtRadius
  , minimalCenteredRadius
  , stencilMoment
  , validateCenteredTaylor
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
  deriving (Eq, Show)

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
