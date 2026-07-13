-- | Typed FEIR v1 contracts for explicit discrete primitives.
--
-- These parsers are deliberately independent of FMR lowering.  Both effect
-- planning and expression lowering must reject the same malformed metadata;
-- neither side is allowed to infer missing axes, placements, or operand
-- shapes from a consumer.
--
-- The generated primitive manifest validates the common operation identity,
-- value-category, placement, effect, and commutation contract.  Attribute
-- names and schemas are operation-specific, so they remain explicit here and
-- in the matching versioned Egison encoder.
module Formurae.Post.PrimitiveContract
  ( PrimitiveContractError(..)
  , OrderedDerivativeRequest(..)
  , ResampleRequest(..)
  , parseOrderedDerivativeRequest
  , parseResampleRequest
  ) where

import Data.List (find, nub)
import Numeric.Natural (Natural)

import qualified Formurae.FEIR.PrimitiveBindings as Primitives
import Formurae.FEIR.Syntax

data PrimitiveContractError
  = ContractWrongOperation VersionedOpId VersionedOpId
  | ContractMissingAttribute AttributeId
  | ContractDuplicateAttribute AttributeId
  | ContractUnknownAttribute AttributeId
  | ContractInvalidAttribute AttributeId AttributeValue
  | ContractInvalidResultBasis Basis
  | ContractInvalidOperands String
  | ContractAxisOutOfRange AxisId Int
  | ContractOrderDoesNotMatchAxes Int Int
  | ContractRadiusMustBeOne Int
  deriving (Eq, Ord, Show)

data OrderedDerivativeRequest = OrderedDerivativeRequest
  { orderedDerivativeOperand :: ScalarNF
  , orderedDerivativeAxes :: [AxisId]
  } deriving (Eq, Ord, Show)

data ResampleRequest = ResampleRequest
  { resampleOperand :: ScalarNF
  , resampleTargetBits :: [Bool]
  } deriving (Eq, Ord, Show)

parseOrderedDerivativeRequest
    :: Int -> OpaqueDiscrete
    -> Either PrimitiveContractError OrderedDerivativeRequest
parseOrderedDerivativeRequest dimension opaque = do
  requireOperation Primitives.derivativeOrderedV1OpId opaque
  requireScalarResult opaque
  operand <- requireScalarOperand
    "derivative.ordered@1 expects exactly one scalar operand" opaque
  requireAttributeSet [orderAttribute, orderedAxesAttribute, radiusAttribute]
    (opaqueDiscreteAttributes opaque)
  orderValue <- requireAttribute orderAttribute opaque
  order <- positiveNatural orderAttribute orderValue
  axesValue <- requireAttribute orderedAxesAttribute opaque
  axes <- case axesValue of
    AttributeValues values -> mapM axisValue values
    _ -> Left (ContractInvalidAttribute orderedAxesAttribute axesValue)
  if null axes
    then Left (ContractInvalidAttribute orderedAxesAttribute axesValue)
    else Right ()
  mapM_ (validAxis dimension) axes
  if order == length axes
    then Right ()
    else Left (ContractOrderDoesNotMatchAxes order (length axes))
  radiusValue <- requireAttribute radiusAttribute opaque
  radius <- positiveNatural radiusAttribute radiusValue
  if radius == 1
    then Right ()
    else Left (ContractRadiusMustBeOne radius)
  Right OrderedDerivativeRequest
    { orderedDerivativeOperand = operand
    , orderedDerivativeAxes = axes
    }

parseResampleRequest
    :: Int -> OpaqueDiscrete
    -> Either PrimitiveContractError ResampleRequest
parseResampleRequest dimension opaque = do
  requireOperation Primitives.resampleExplicitV1OpId opaque
  requireScalarResult opaque
  operand <- requireScalarOperand
    "resample.explicit@1 expects exactly one scalar operand" opaque
  requireAttributeSet [targetPlacementAttribute]
    (opaqueDiscreteAttributes opaque)
  placementValue <- requireAttribute targetPlacementAttribute opaque
  bits <- case placementValue of
    AttributeValues values -> mapM placementBit values
    _ -> Left (ContractInvalidAttribute targetPlacementAttribute placementValue)
  if length bits == dimension
    then Right ResampleRequest
      { resampleOperand = operand
      , resampleTargetBits = bits
      }
    else Left (ContractInvalidAttribute targetPlacementAttribute placementValue)

requireOperation
    :: VersionedOpId -> OpaqueDiscrete -> Either PrimitiveContractError ()
requireOperation expected opaque
  | opaqueDiscreteOpId opaque == expected = Right ()
  | otherwise = Left (ContractWrongOperation expected
      (opaqueDiscreteOpId opaque))

requireScalarResult
    :: OpaqueDiscrete -> Either PrimitiveContractError ()
requireScalarResult opaque
  | opaqueDiscreteResultBasis opaque == Basis [] = Right ()
  | otherwise = Left
      (ContractInvalidResultBasis (opaqueDiscreteResultBasis opaque))

requireScalarOperand
    :: String -> OpaqueDiscrete -> Either PrimitiveContractError ScalarNF
requireScalarOperand message opaque =
  case opaqueDiscreteOperands opaque of
    [ScalarValue scalar] -> Right scalar
    _ -> Left (ContractInvalidOperands message)

requireAttributeSet
    :: [AttributeId] -> [Attribute] -> Either PrimitiveContractError ()
requireAttributeSet expected attributes = do
  case firstDuplicate (map attributeId attributes) of
    Just identifier -> Left (ContractDuplicateAttribute identifier)
    Nothing -> Right ()
  case find (`notElem` expected) (map attributeId attributes) of
    Just identifier -> Left (ContractUnknownAttribute identifier)
    Nothing -> Right ()
  case find (`notElem` map attributeId attributes) expected of
    Just identifier -> Left (ContractMissingAttribute identifier)
    Nothing -> Right ()

requireAttribute
    :: AttributeId -> OpaqueDiscrete
    -> Either PrimitiveContractError AttributeValue
requireAttribute identifier opaque =
  case [attributeValue attribute
       | attribute <- opaqueDiscreteAttributes opaque
       , attributeId attribute == identifier] of
    [value] -> Right value
    [] -> Left (ContractMissingAttribute identifier)
    _ -> Left (ContractDuplicateAttribute identifier)

positiveNatural
    :: AttributeId -> AttributeValue
    -> Either PrimitiveContractError Int
positiveNatural identifier value =
  case value of
    AttributeNatural natural
      | integer > 0
      , integer <= toInteger (maxBound :: Int) -> Right (fromInteger integer)
      where integer = naturalInteger natural
    _ -> Left (ContractInvalidAttribute identifier value)

naturalInteger :: Natural -> Integer
naturalInteger = toInteger

axisValue :: AttributeValue -> Either PrimitiveContractError AxisId
axisValue value =
  case value of
    AttributeAxis axis -> Right axis
    _ -> Left (ContractInvalidAttribute orderedAxesAttribute value)

validAxis :: Int -> AxisId -> Either PrimitiveContractError ()
validAxis dimension axis@(AxisId value)
  | value >= 1 && value <= dimension = Right ()
  | otherwise = Left (ContractAxisOutOfRange axis dimension)

placementBit :: AttributeValue -> Either PrimitiveContractError Bool
placementBit value =
  case value of
    AttributeBoolean bit -> Right bit
    _ -> Left (ContractInvalidAttribute targetPlacementAttribute value)

firstDuplicate :: Eq value => [value] -> Maybe value
firstDuplicate values = find repeated (nub values)
  where
    repeated value = length (filter (== value) values) > 1

orderAttribute, orderedAxesAttribute, radiusAttribute :: AttributeId
orderAttribute = AttributeId "order"
orderedAxesAttribute = AttributeId "ordered-axes"
radiusAttribute = AttributeId "radius"

targetPlacementAttribute :: AttributeId
targetPlacementAttribute = AttributeId "target-placement"
