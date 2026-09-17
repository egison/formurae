-- | Fixed FEIR v1 stencils for explicit ordered differentiation and
-- absolute-placement resampling.
--
-- Coefficients here are dimensionless.  The caller supplies one grid-step
-- denominator for every ordered derivative stage.
module Formurae.Post.ExplicitStencil
  ( ExplicitStencilError(..)
  , OrderedStencilPlan(..)
  , orderedFirstDerivativeStencil
  , resampleLinearStencil
  , sampleSideStencil
  ) where

import Formurae.FEIR.Syntax (AxisId(..))
import Formurae.Post.Location
import Formurae.Post.PrimitiveContract (SampleSide(..))

data ExplicitStencilError
  = ExplicitStencilLocationError LocationError
  | ExplicitStencilAxisOutOfRange AxisId Int
  | ExplicitStencilPlacementDimensionMismatch Int Int
  | ExplicitStencilTargetMismatch Placement Placement
  | ExplicitStencilSideNeedsOneChangedAxis Placement Placement
  | ExplicitStencilSideNeedsLocatedOperand
  deriving (Eq, Ord, Show)

data OrderedStencilPlan = OrderedStencilPlan
  { orderedStencilTarget :: Placement
  , orderedStencilSamples :: [([Int], Rational)]
  , orderedStencilDenominatorAxes :: [AxisId]
  } deriving (Eq, Ord, Show)

-- | Apply radius-one first-derivative stages in source order.  Collocated
-- stages use the centered pair at integer offsets.  Staggered stages use the
-- Yee pair selected by the placement before that stage and then toggle that
-- axis for the following stage.
orderedFirstDerivativeStencil
    :: Bool -> [AxisId] -> Placement
    -> Either ExplicitStencilError OrderedStencilPlan
orderedFirstDerivativeStencil staggered axes source = do
  (target, samples) <- foldl applyStage (Right (source, [(zeros, 1)])) axes
  Right OrderedStencilPlan
    { orderedStencilTarget = target
    , orderedStencilSamples = samples
    , orderedStencilDenominatorAxes = axes
    }
  where
    dimension = length (placementBits source)
    zeros = replicate dimension 0
    applyStage result axisId@(AxisId axis) = do
      (placement, accumulated) <- result
      if axis < 1 || axis > dimension
        then Left (ExplicitStencilAxisOutOfRange axisId dimension)
        else Right ()
      weights <- if staggered
        then yeeWeights placement axisId
        else Right [(-1, -1 / 2), (1, 1 / 2)]
      target <- if staggered
        then mapLocation (togglePlacement axisId placement)
        else Right placement
      Right (target, combine axis weights accumulated)

-- | Tensor-product linear interpolation from an absolute source placement
-- to an absolute target placement.  Equal axes contribute the identity;
-- integer-to-half uses samples 0/+1 and half-to-integer uses -1/0.
resampleLinearStencil
    :: Placement -> Placement
    -> Either ExplicitStencilError [([Int], Rational)]
resampleLinearStencil source target
  | sourceDimension /= targetDimension =
      Left (ExplicitStencilPlacementDimensionMismatch
        sourceDimension targetDimension)
  | otherwise = Right (foldl applyAxis [(zeros, 1)] axisWeights)
  where
    sourceBits = placementBits source
    targetBits = placementBits target
    sourceDimension = length sourceBits
    targetDimension = length targetBits
    zeros = replicate sourceDimension 0
    axisWeights = zipWith3 weights [1 ..] sourceBits targetBits
    applyAxis accumulated (axis, values) = combine axis values accumulated
    weights axis IntegerPoint IntegerPoint = (axis, [(0, 1)])
    weights axis HalfPoint HalfPoint = (axis, [(0, 1)])
    weights axis IntegerPoint HalfPoint =
      (axis, [(0, 1 / 2), (1, 1 / 2)])
    weights axis HalfPoint IntegerPoint =
      (axis, [(-1, 1 / 2), (0, 1 / 2)])

-- | Select exactly one source value adjacent to the target. The side is
-- defined by increasing computational coordinate, not physical orientation.
sampleSideStencil
    :: SampleSide -> Placement -> Placement
    -> Either ExplicitStencilError [([Int], Rational)]
sampleSideStencil side source target
  | length sourceBits /= length targetBits =
      Left (ExplicitStencilPlacementDimensionMismatch
        (length sourceBits) (length targetBits))
  | length changed /= 1 =
      Left (ExplicitStencilSideNeedsOneChangedAxis source target)
  | otherwise = Right [(zipWith offset sourceBits targetBits, 1)]
  where
    sourceBits = placementBits source
    targetBits = placementBits target
    changed = filter (uncurry (/=)) (zip sourceBits targetBits)
    offset a b
      | a == b = 0
      | a == IntegerPoint = if side == SampleLower then 0 else 1
      | otherwise = if side == SampleLower then -1 else 0

yeeWeights
    :: Placement -> AxisId
    -> Either ExplicitStencilError [(Int, Rational)]
yeeWeights placement axisId@(AxisId axis) =
  case drop (axis - 1) (placementBits placement) of
    IntegerPoint : _ -> Right [(0, -1), (1, 1)]
    HalfPoint : _ -> Right [(-1, -1), (0, 1)]
    [] -> Left (ExplicitStencilAxisOutOfRange axisId
      (length (placementBits placement)))

combine
    :: Int
    -> [(Int, Rational)]
    -> [([Int], Rational)]
    -> [([Int], Rational)]
combine axis weights accumulated =
  [ (adjust axis offset offsets, coefficient * weight)
  | (offsets, coefficient) <- accumulated
  , (offset, weight) <- weights
  ]

adjust :: Int -> Int -> [Int] -> [Int]
adjust axis delta offsets =
  [if current == axis then value + delta else value
  | (current, value) <- zip [1 ..] offsets]

mapLocation
    :: Either LocationError value -> Either ExplicitStencilError value
mapLocation = either (Left . ExplicitStencilLocationError) Right
