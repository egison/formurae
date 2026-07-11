module Main where

import Data.List (groupBy, isPrefixOf, sortOn)

import Formurae.FEIR.Codec (parseFEProgram)
import qualified Formurae.FEIR.PrimitiveBindings as Primitives
import Formurae.FEIR.Syntax

main :: IO ()
main = do
  input <- getContents
  encoded <- case reverse
      [line | line <- lines input, "(feir " `isPrefixOf` line] of
    line : _ -> pure line
    [] -> fail "Egison output did not contain canonical FEIR"
  program <- either (fail . show) pure (parseFEProgram encoded)
  let calls = sortOn opaqueDiscreteRequestGroup
        [ opaque
        | opaque <- concatMap actionOpaqueCalls (feProgramStepActions program)
        , opaqueDiscreteOpId opaque == Primitives.operatorMaterializedV1OpId
        ]
      groups = groupBy
        (\lhs rhs -> opaqueDiscreteRequestGroup lhs
          == opaqueDiscreteRequestGroup rhs) calls
  assertEqual "two materialized tensor groups" 2 (length groups)
  metadata <- mapM checkGroup groups
  assertEqual "variance and differential-form metadata survive the payload"
    [ TensorType [2] [VarianceUp] 0
    , TensorType [2] [VarianceDown] 1
    ]
    (sortOn tensorTypeDfOrder metadata)
  putStrLn "pre-fec materialized metadata FEIR test: ok"

checkGroup :: [OpaqueDiscrete] -> IO TensorType
checkGroup calls = do
  assertEqual "one scalar opaque result per tensor component" 2 (length calls)
  assertEqual "materialized result bases"
    [Basis [1], Basis [2]]
    (map opaqueDiscreteResultBasis (sortOn opaqueDiscreteResultBasis calls))
  tensors <- mapM operand calls
  case tensors of
    first : rest -> do
      assertEqual "request group repeats one complete typed operand"
        [first] (unique tensors)
      pure TensorType
        { tensorTypeShape = tensorNFShape first
        , tensorTypeVariances = tensorNFVariances first
        , tensorTypeDfOrder = tensorNFDfOrder first
        }
    [] -> fail "materialized request group is empty"
  where
    operand opaque = case opaqueDiscreteOperands opaque of
      [TensorValue tensor] -> pure tensor
      value -> fail ("expected one TensorValue operand, got " ++ show value)

actionOpaqueCalls :: FEAction -> [OpaqueDiscrete]
actionOpaqueCalls action =
  case action of
    BindValue _ value _ -> valueOpaqueCalls value
    Materialize _ value _ -> valueOpaqueCalls value
    UpdateField equation -> tensorOpaqueCalls (feEquationRhs equation)

valueOpaqueCalls :: FEValue -> [OpaqueDiscrete]
valueOpaqueCalls value =
  case value of
    ScalarValue scalar -> scalarOpaqueCalls scalar
    TensorValue tensor -> tensorOpaqueCalls tensor

tensorOpaqueCalls :: TensorNF -> [OpaqueDiscrete]
tensorOpaqueCalls tensor = concatMap
  (scalarOpaqueCalls . snd) (tensorNFComponents tensor)

scalarOpaqueCalls :: ScalarNF -> [OpaqueDiscrete]
scalarOpaqueCalls scalar =
  case scalar of
    Add values -> concatMap scalarOpaqueCalls values
    Mul values -> concatMap scalarOpaqueCalls values
    Div lhs rhs -> scalarOpaqueCalls lhs ++ scalarOpaqueCalls rhs
    Pow lhs rhs -> scalarOpaqueCalls lhs ++ scalarOpaqueCalls rhs
    Intrinsic _ values -> concatMap scalarOpaqueCalls values
    AnalyticCall _ values -> concatMap scalarOpaqueCalls values
    Select _ yes no -> scalarOpaqueCalls yes ++ scalarOpaqueCalls no
    OpaqueDiscrete opaque ->
      opaque : concatMap valueOpaqueCalls (opaqueDiscreteOperands opaque)
    _ -> []

unique :: Eq value => [value] -> [value]
unique = foldl add []
  where
    add values value
      | value `elem` values = values
      | otherwise = values ++ [value]

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail (label ++ ": expected " ++ show expected
      ++ ", got " ++ show actual)
