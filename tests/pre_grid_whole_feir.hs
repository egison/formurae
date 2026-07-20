module Main where

import Data.List (isPrefixOf)

import Formurae.FEIR.Codec (parseFEProgram)
import Formurae.FEIR.Syntax

main :: IO ()
main = do
  input <- getContents
  encoded <- case reverse [line | line <- lines input, "(feir " `isPrefixOf` line] of
    line : _ -> pure line
    [] -> fail "Egison output did not contain a canonical FEIR value"
  program <- either (fail . show) pure (parseFEProgram encoded)
  let calls = concatMap actionOpaqueCalls (feProgramStepActions program)
      wide =
        [ call
        | call <- calls
        , opaqueDiscreteOpId call == OpId "derivative.coordinate-wide"
        ]
  assertEqual "the two ∂² occurrences are radius-one coordinate requests"
    2 (length wide)
  case [ call
       | call <- calls
       , opaqueDiscreteOpId call == OpId "derivative.grid-whole"
       ] of
    [opaque] -> checkGridWhole opaque
    others -> fail ("expected one grid-whole request, got " ++ show others)

checkGridWhole :: OpaqueDiscrete -> IO ()
checkGridWhole opaque = do
  assertEqual "operation"
    (OpId "derivative.grid-whole")
    (opaqueDiscreteOpId opaque)
  assertEqual "result basis" (Basis []) (opaqueDiscreteResultBasis opaque)
  assertEqual "one whole nonlinear operand"
    [ScalarValue expectedOperand]
    (opaqueDiscreteOperands opaque)
  assertEqual "axis/order/radius attributes"
    [ Attribute (AttributeId "order") (AttributeNatural 1)
    , Attribute (AttributeId "ordered-axes")
        (AttributeValues [AttributeAxis (AxisId 1)])
    , Attribute (AttributeId "radius") (AttributeNatural 1)
    ]
    (opaqueDiscreteAttributes opaque)
  putStrLn "formurae-pre grid-whole FEIR test: ok"

expectedOperand :: ScalarNF
expectedOperand = Mul
  [ Exact 1 2
  , Pow (FieldJet (FieldJetValue
      (FieldId 1)
      CurrentTime
      (Basis [])
      [Coordinate (AxisId 1), Coordinate (AxisId 2), Coordinate (AxisId 3)]
      []))
    (Exact 2 1)
  ]

actionOpaqueCalls :: FEAction -> [OpaqueDiscrete]
actionOpaqueCalls action =
  case action of
    BindValue _ value _ -> valueOpaqueCalls value
    Materialize _ value _ -> valueOpaqueCalls value
    UpdateField equation ->
      concatMap (scalarOpaqueCalls . snd)
        (tensorNFComponents (feEquationRhs equation))

valueOpaqueCalls :: FEValue -> [OpaqueDiscrete]
valueOpaqueCalls value =
  case value of
    ScalarValue scalar -> scalarOpaqueCalls scalar
    TensorValue tensor ->
      concatMap (scalarOpaqueCalls . snd) (tensorNFComponents tensor)

scalarOpaqueCalls :: ScalarNF -> [OpaqueDiscrete]
scalarOpaqueCalls scalar =
  case scalar of
    Add values -> concatMap scalarOpaqueCalls values
    Mul values -> concatMap scalarOpaqueCalls values
    Div numerator denominator ->
      scalarOpaqueCalls numerator ++ scalarOpaqueCalls denominator
    Pow base exponent -> scalarOpaqueCalls base ++ scalarOpaqueCalls exponent
    Intrinsic _ arguments -> concatMap scalarOpaqueCalls arguments
    AnalyticCall _ arguments -> concatMap scalarOpaqueCalls arguments
    Select _ yes no -> scalarOpaqueCalls yes ++ scalarOpaqueCalls no
    OpaqueDiscrete opaque ->
      opaque : concatMap valueOpaqueCalls (opaqueDiscreteOperands opaque)
    _ -> []

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
