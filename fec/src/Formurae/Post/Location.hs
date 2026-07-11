module Formurae.Post.Location
  ( HalfBit(..)
  , Placement(..)
  , Capability(..)
  , LocationError(..)
  , latticeClassOfPolicy
  , componentPlacement
  , togglePlacement
  , derivativePlacement
  , derivativePlacementForPolicy
  , relativePlacement
  , fieldJetPlacements
  , joinCapability
  , demandCapability
  ) where

import Data.List (find)
import Numeric.Natural (Natural)

import Formurae.FEIR.Syntax

data HalfBit
  = IntegerPoint
  | HalfPoint
  deriving (Eq, Ord, Show)

newtype Placement = Placement { placementBits :: [HalfBit] }
  deriving (Eq, Ord, Show)

data Capability
  = ConstantCapability
  | SampleableCapability
  | LocatedCapability Placement
  deriving (Eq, Ord, Show)

data LocationError
  = InvalidLocationDimension Int
  | InvalidBasisAxis Int Int
  | InvalidDerivativeAxis AxisId Int
  | ZeroDerivativeMultiplicity AxisId
  | PlacementDimensionMismatch Int Int
  | UnknownLocationField FieldId
  | FieldJetBasisMismatch FieldId Basis
  | LocatedPlacementMismatch Placement Placement
  | AmbiguousSampleableDemand
  deriving (Eq, Ord, Show)

latticeClassOfPolicy :: GridPolicy -> LatticeClass
latticeClassOfPolicy CollocatedPolicy = CollocatedLattice
latticeClassOfPolicy PrimalPolicy = StaggeredLattice
latticeClassOfPolicy DualPolicy = StaggeredLattice

componentPlacement
    :: Int -> GridPolicy -> Basis -> Either LocationError Placement
componentPlacement dimension policy (Basis componentAxes)
  | dimension < 0 = Left (InvalidLocationDimension dimension)
  | otherwise = do
      mapM_ validateAxis componentAxes
      Right (Placement [bitFor axis | axis <- [1 .. dimension]])
  where
    validateAxis axis
      | axis >= 1 && axis <= dimension = Right ()
      | otherwise = Left (InvalidBasisAxis axis dimension)

    bitFor axis =
      case policy of
        CollocatedPolicy -> IntegerPoint
        PrimalPolicy -> if odd (count axis componentAxes) then HalfPoint else IntegerPoint
        DualPolicy -> if odd (count axis componentAxes) then IntegerPoint else HalfPoint

togglePlacement :: AxisId -> Placement -> Either LocationError Placement
togglePlacement axisId@(AxisId axis) (Placement bits)
  | axis < 1 || axis > length bits =
      Left (InvalidDerivativeAxis axisId (length bits))
  | otherwise =
      Right (Placement (zipWith toggleAt [1 ..] bits))
  where
    toggleAt current bit
      | current == axis = toggle bit
      | otherwise = bit
    toggle IntegerPoint = HalfPoint
    toggle HalfPoint = IntegerPoint

derivativePlacement
    :: [(AxisId, Natural)] -> Placement -> Either LocationError Placement
derivativePlacement multiIndex source = foldl step (Right source) multiIndex
  where
    step result (axis, multiplicity)
      | multiplicity == 0 = Left (ZeroDerivativeMultiplicity axis)
      | even multiplicity = result
      | otherwise = result >>= togglePlacement axis

-- | Natural derivative placement for a logical field policy.  Collocated
-- centered differences stay at the source point for every derivative order;
-- only the staggered Primal/Dual lattice toggles an axis on odd order.  The
-- generic 'derivativePlacement' operation remains the staggered bit transform
-- used by Yee and DEC contracts.
derivativePlacementForPolicy
    :: GridPolicy
    -> [(AxisId, Natural)]
    -> Placement
    -> Either LocationError Placement
derivativePlacementForPolicy policy multiIndex source =
  case policy of
    CollocatedPolicy -> derivativePlacement multiIndex source >> Right source
    PrimalPolicy -> derivativePlacement multiIndex source
    DualPolicy -> derivativePlacement multiIndex source

relativePlacement
    :: Placement -> Placement -> Either LocationError [Rational]
relativePlacement (Placement target) (Placement source)
  | length target /= length source =
      Left (PlacementDimensionMismatch (length target) (length source))
  | otherwise = Right (zipWith difference target source)
  where
    coordinate IntegerPoint = 0
    coordinate HalfPoint = 1 / 2
    difference targetBit sourceBit = coordinate targetBit - coordinate sourceBit

fieldJetPlacements
    :: Int
    -> [LogicalFieldDecl]
    -> FieldJet
    -> Either LocationError (Placement, Placement)
fieldJetPlacements dimension fields jet = do
  field <-
    case find ((== fieldJetFieldId jet) . logicalFieldId) fields of
      Just value -> Right value
      Nothing -> Left (UnknownLocationField (fieldJetFieldId jet))
  let basis = fieldJetBasis jet
  if basisFitsType basis (logicalFieldTensorType field)
    then do
      source <- componentPlacement dimension (logicalFieldPolicy field) basis
      target <- derivativePlacementForPolicy (logicalFieldPolicy field)
        (fieldJetMultiIndex jet) source
      Right (source, target)
    else Left (FieldJetBasisMismatch (logicalFieldId field) basis)

joinCapability :: Capability -> Capability -> Either LocationError Capability
joinCapability ConstantCapability capability = Right capability
joinCapability capability ConstantCapability = Right capability
joinCapability SampleableCapability SampleableCapability = Right SampleableCapability
joinCapability SampleableCapability located@(LocatedCapability _) = Right located
joinCapability located@(LocatedCapability _) SampleableCapability = Right located
joinCapability lhs@(LocatedCapability left) (LocatedCapability right)
  | left == right = Right lhs
  | otherwise = Left (LocatedPlacementMismatch left right)

demandCapability
    :: Placement -> Capability -> Either LocationError Placement
demandCapability target ConstantCapability = Right target
demandCapability target SampleableCapability = Right target
demandCapability target (LocatedCapability actual)
  | target == actual = Right actual
  | otherwise = Left (LocatedPlacementMismatch target actual)

count :: Eq a => a -> [a] -> Int
count needle = length . filter (== needle)

basisFitsType :: Basis -> TensorType -> Bool
basisFitsType (Basis axes) tensorType =
  length axes == length (tensorTypeShape tensorType)
  && and (zipWith within axes (tensorTypeShape tensorType))
  where
    within axis extent = axis >= 1 && axis <= extent
