-- | Backend-side basis and placement contracts for differential forms.
--
-- Egison evaluates the actual tensor algebra before FEIR is emitted.  This
-- module therefore does not reimplement @d@, Hodge star, or the
-- codifferential.  It records the small amount of geometry that post-fec must
-- still know in order to check component placement and to project a whole
-- form to storage.
module Formurae.Post.Geometry
  ( GeometryError(..)
  , ExteriorDerivativeTerm(..)
  , HodgeComponent(..)
  , exteriorDerivativeTerms
  , hodgeComponent
  , codifferentialSign
  , positiveScalarLaplacianSign
  ) where

import Data.List (nub, sort)

import Formurae.FEIR.Syntax
import Formurae.Post.Location

data GeometryError
  = InvalidFormDimension Int
  | InvalidFormBasis Int Basis
  | NonCanonicalFormBasis Basis
  | InvalidFormDegree Int Int
  | GeometryLocationError LocationError
  | ExteriorDerivativePlacementMismatch
      GridPolicy Basis ExteriorDerivativeTerm Placement Placement
  | HodgePlacementMismatch
      GridPolicy Basis Basis Placement Placement
  deriving (Eq, Ord, Show)

-- | One nonzero component term in the exterior derivative.
--
-- For a canonical target basis @[i1,..,ik]@, term @r@ differentiates the
-- source basis with @ir@ removed and has sign @(-1)^(r-1)@.  This fixes the
-- convention
--
-- > (d A)_ij = partial_i A_j - partial_j A_i.
data ExteriorDerivativeTerm = ExteriorDerivativeTerm
  { exteriorTermSign :: Integer
  , exteriorTermAxis :: AxisId
  , exteriorTermSourceBasis :: Basis
  } deriving (Eq, Ord, Show)

-- | The source component and orientation sign used by one Hodge-star output
-- component.  The target policy is the primal/dual flip of the source policy.
data HodgeComponent = HodgeComponent
  { hodgeSourceBasis :: Basis
  , hodgeTargetBasis :: Basis
  , hodgeOrientationSign :: Integer
  , hodgeTargetPolicy :: GridPolicy
  } deriving (Eq, Ord, Show)

-- | Describe the component expansion of @d@ and verify that every analytic
-- derivative naturally lands on the target component placement.
exteriorDerivativeTerms
    :: Int
    -> GridPolicy
    -> Basis
    -> Either GeometryError [ExteriorDerivativeTerm]
exteriorDerivativeTerms dimension policy targetBasis@(Basis targetAxes) = do
  validateDimension dimension
  validateCanonicalBasis dimension targetBasis
  let terms =
        [ ExteriorDerivativeTerm
            { exteriorTermSign = if odd position then 1 else -1
            , exteriorTermAxis = AxisId axis
            , exteriorTermSourceBasis = Basis
                (take (position - 1) targetAxes ++ drop position targetAxes)
            }
        | (position, axis) <- zip [1 ..] targetAxes
        ]
  targetPlacement <- mapLocation
    (componentPlacement dimension policy targetBasis)
  mapM_ (verifyTermPlacement targetPlacement) terms
  pure terms
  where
    verifyTermPlacement targetPlacement term = do
      sourcePlacement <- mapLocation
        (componentPlacement dimension policy
          (exteriorTermSourceBasis term))
      derivativeTarget <- mapLocation
        (derivativePlacementForPolicy policy
          [(exteriorTermAxis term, 1)] sourcePlacement)
      if derivativeTarget == targetPlacement
        then Right ()
        else Left (ExteriorDerivativePlacementMismatch
          policy targetBasis term targetPlacement derivativeTarget)

-- | Describe one Hodge-star output component and verify the DEC placement
-- identity.  If @I@ is the complement of target basis @J@, then
--
-- > (* A)_J = sign(I ++ J) * c_I * A_I
--
-- and a source component with primal/dual policy occupies the same physical
-- point as the complemented component with the flipped policy.
hodgeComponent
    :: Int
    -> GridPolicy
    -> Basis
    -> Either GeometryError HodgeComponent
hodgeComponent dimension sourcePolicy targetBasis@(Basis targetAxes) = do
  validateDimension dimension
  validateCanonicalBasis dimension targetBasis
  let sourceAxes = filter (`notElem` targetAxes) [1 .. dimension]
      sourceBasis = Basis sourceAxes
      targetPolicy = flipPolicy sourcePolicy
      component = HodgeComponent
        { hodgeSourceBasis = sourceBasis
        , hodgeTargetBasis = targetBasis
        , hodgeOrientationSign = permutationSign (sourceAxes ++ targetAxes)
        , hodgeTargetPolicy = targetPolicy
        }
  sourcePlacement <- mapLocation
    (componentPlacement dimension sourcePolicy sourceBasis)
  targetPlacement <- mapLocation
    (componentPlacement dimension targetPolicy targetBasis)
  if sourcePlacement == targetPlacement
    then Right component
    else Left (HodgePlacementMismatch sourcePolicy sourceBasis targetBasis
      sourcePlacement targetPlacement)

-- | Sign in
--
-- > delta A = (-1)^(n (k + 1) + 1) * (star . d . star) A
--
-- for an input @k@-form in dimension @n@.
codifferentialSign :: Int -> Int -> Either GeometryError Integer
codifferentialSign dimension degree = do
  validateDimension dimension
  if degree < 0 || degree > dimension
    then Left (InvalidFormDegree dimension degree)
    else pure (powerMinusOne (dimension * (degree + 1) + 1))

-- | Multiplicative sign relating the codifferential of @d u@ to the positive
-- Cartesian scalar Laplacian.  With the convention above this is always
-- minus one: @Delta u = -delta (d u)@.
positiveScalarLaplacianSign :: Int -> Either GeometryError Integer
positiveScalarLaplacianSign dimension = do
  validateDimension dimension
  pure (-1)

validateDimension :: Int -> Either GeometryError ()
validateDimension dimension
  | dimension < 1 = Left (InvalidFormDimension dimension)
  | otherwise = Right ()

validateCanonicalBasis :: Int -> Basis -> Either GeometryError ()
validateCanonicalBasis dimension basis@(Basis axes)
  | any (\axis -> axis < 1 || axis > dimension) axes =
      Left (InvalidFormBasis dimension basis)
  | axes /= sort axes || length axes /= length (nub axes) =
      Left (NonCanonicalFormBasis basis)
  | otherwise = Right ()

flipPolicy :: GridPolicy -> GridPolicy
flipPolicy CollocatedPolicy = CollocatedPolicy
flipPolicy PrimalPolicy = DualPolicy
flipPolicy DualPolicy = PrimalPolicy

permutationSign :: [Int] -> Integer
permutationSign values =
  powerMinusOne (length
    [ ()
    | (leftPosition, left) <- zip [0 :: Int ..] values
    , (rightPosition, right) <- zip [0 :: Int ..] values
    , leftPosition < rightPosition
    , left > right
    ])

powerMinusOne :: Int -> Integer
powerMinusOne power
  | even power = 1
  | otherwise = -1

mapLocation :: Either LocationError a -> Either GeometryError a
mapLocation = either (Left . GeometryLocationError) Right
