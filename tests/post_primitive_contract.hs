module Main where

import qualified Formurae.FEIR.PrimitiveBindings as Primitives
import Formurae.FEIR.Syntax
import Formurae.Post.PrimitiveContract

main :: IO ()
main = do
  testOrdered
  testResample
  putStrLn "post primitive contract tests: ok"

testOrdered :: IO ()
testOrdered = do
  let request = opaque Primitives.derivativeOrderedOpId (Basis [])
        [ScalarValue source]
        [ Attribute (AttributeId "order") (AttributeNatural 3)
        , Attribute (AttributeId "ordered-axes")
            (AttributeValues
              [ AttributeAxis (AxisId 2)
              , AttributeAxis (AxisId 1)
              , AttributeAxis (AxisId 2)
              ])
        , Attribute (AttributeId "radius") (AttributeNatural 1)
        ]
  parsed <- assertRight "ordered request" (parseOrderedDerivativeRequest 2 request)
  assertEqual "ordered axes preserve order and repetition"
    [AxisId 2, AxisId 1, AxisId 2]
    (orderedDerivativeAxes parsed)
  assertLeft "ordered count is strict"
    (== ContractOrderDoesNotMatchAxes 2 3)
    (parseOrderedDerivativeRequest 2
      (replaceAttribute "order" (AttributeNatural 2) request))
  assertLeft "ordered axis is registered"
    (== ContractAxisOutOfRange (AxisId 3) 2)
    (parseOrderedDerivativeRequest 2
      (replaceAttribute "ordered-axes"
        (AttributeValues [AttributeAxis (AxisId 3)])
        (replaceAttribute "order" (AttributeNatural 1) request)))

testResample :: IO ()
testResample = do
  let request = opaque Primitives.resampleExplicitOpId (Basis [])
        [ScalarValue source]
        [Attribute (AttributeId "target-placement")
          (AttributeValues [AttributeBoolean False, AttributeBoolean True])]
  parsed <- assertRight "resample request" (parseResampleRequest 2 request)
  assertEqual "absolute placement bits" [False, True]
    (resampleTargetBits parsed)
  assertLeft "resample dimension is strict"
    isTargetPlacementError
    (parseResampleRequest 3 request)
  assertLeft "resample accepts only booleans"
    isTargetPlacementError
    (parseResampleRequest 2
      (replaceAttribute "target-placement"
        (AttributeValues [AttributeNatural 0, AttributeNatural 1]) request))
  where
    isTargetPlacementError problem =
      case problem of
        ContractInvalidAttribute (AttributeId "target-placement") _ -> True
        _ -> False

source :: ScalarNF
source = FieldJet (FieldJetValue (FieldId 1) CurrentTime (Basis [])
  [Coordinate (AxisId 1), Coordinate (AxisId 2)] [])

opaque
    :: OpId -> Basis -> [FEValue] -> [Attribute] -> OpaqueDiscrete
opaque operation basis operands attributes = OpaqueDiscreteCall
  operation (SemanticKey "key") (RequestGroupId "group")
  basis operands attributes

replaceAttribute :: String -> AttributeValue -> OpaqueDiscrete -> OpaqueDiscrete
replaceAttribute name value opaqueValue = opaqueValue
  { opaqueDiscreteAttributes =
      [ if attributeId attribute == AttributeId name
          then Attribute (AttributeId name) value
          else attribute
      | attribute <- opaqueDiscreteAttributes opaqueValue
      ]
  }

assertRight :: String -> Either error value -> IO value
assertRight _ (Right value) = pure value
assertRight label (Left _) = fail (label ++ ": expected Right")

assertLeft
    :: Show error => String -> (error -> Bool) -> Either error value -> IO ()
assertLeft label predicate result =
  case result of
    Left problem | predicate problem -> pure ()
    Left problem -> fail (label ++ ": unexpected error " ++ show problem)
    Right _ -> fail (label ++ ": expected Left")

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail (label ++ ": expected " ++ show expected
      ++ ", got " ++ show actual)
