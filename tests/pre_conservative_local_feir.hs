module Main where

import Data.List (find, isPrefixOf, sort)

import Formurae.FEIR.Codec (parseFEProgram)
import Formurae.FEIR.Syntax

main :: IO ()
main = do
  input <- getContents
  encoded <- case reverse
      [line | line <- lines input, "(feir " `isPrefixOf` line] of
    line : _ -> pure line
    [] -> fail "Egison output did not contain canonical FEIR"
  program <- either (fail . show) pure (parseFEProgram encoded)
  q <- maybe (fail "missing q logical field") pure $ find
    ((== "q") . logicalFieldSourceName) (feProgramFields program)
  assertEqual "q is a Primal rank-one step-local field"
    ( PrimalPolicy
    , TensorType [2] [VarianceDown] 0
    , VectorLayout
    , [Just VarianceDown]
    , StepLocalLifetime
    )
    ( logicalFieldPolicy q
    , logicalFieldTensorType q
    , logicalFieldLayout q
    , logicalFieldDeclaredVariances q
    , logicalFieldLifetime q
    )

  let qId = logicalFieldId q
      actions = feProgramStepActions program
  case actions of
    [Materialize target (TensorValue tensor) _, UpdateField equation] -> do
      assertEqual "q is the materialization target" qId target
      assertEqual "q materializes both vector components"
        ([2], [VarianceDown], 0, [Basis [1], Basis [2]])
        ( tensorNFShape tensor
        , tensorNFVariances tensor
        , tensorNFDfOrder tensor
        , map fst (tensorNFComponents tensor)
        )
      assertEqual "the update differentiates the stored q components"
        [ (Basis [1], [(AxisId 1, 1)])
        , (Basis [2], [(AxisId 2, 1)])
        ]
        (sort
          [ (fieldJetBasis jet, fieldJetMultiIndex jet)
          | jet <- tensorFieldJets (feEquationRhs equation)
          , fieldJetFieldId jet == qId
          ])
    other -> fail
      ("expected q Materialize before one user update, got " ++ show other)

  let opaque = concatMap actionOpaqueCalls actions
      operationIds = map opaqueDiscreteOpId opaque
  assertEqual "two quoted component derivatives survive to FEIR"
    [ VersionedOpId "derivative.grid-whole@1"
    , VersionedOpId "derivative.grid-whole@1"
    ]
    (sort operationIds)
  assert "no conservative-divergence opaque primitive"
    (VersionedOpId "flux.conservative-divergence@1"
      `notElem` operationIds)
  assert "no materialized opaque primitive"
    (VersionedOpId "operator.materialized@1" `notElem` operationIds)
  putStrLn "pre-fec conservative local FEIR test: ok"

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
    Div numerator denominator ->
      scalarOpaqueCalls numerator ++ scalarOpaqueCalls denominator
    Pow base exponent -> scalarOpaqueCalls base ++ scalarOpaqueCalls exponent
    Intrinsic _ arguments -> concatMap scalarOpaqueCalls arguments
    AnalyticCall _ arguments -> concatMap scalarOpaqueCalls arguments
    Select _ yes no -> scalarOpaqueCalls yes ++ scalarOpaqueCalls no
    OpaqueDiscrete request ->
      request : concatMap valueOpaqueCalls (opaqueDiscreteOperands request)
    _ -> []

tensorFieldJets :: TensorNF -> [FieldJet]
tensorFieldJets tensor = concatMap
  (scalarFieldJets . snd) (tensorNFComponents tensor)

scalarFieldJets :: ScalarNF -> [FieldJet]
scalarFieldJets scalar =
  case scalar of
    FieldJet jet -> [jet]
    Add values -> concatMap scalarFieldJets values
    Mul values -> concatMap scalarFieldJets values
    Div numerator denominator ->
      scalarFieldJets numerator ++ scalarFieldJets denominator
    Pow base exponent -> scalarFieldJets base ++ scalarFieldJets exponent
    Intrinsic _ arguments -> concatMap scalarFieldJets arguments
    AnalyticCall _ arguments -> concatMap scalarFieldJets arguments
    Select _ yes no -> scalarFieldJets yes ++ scalarFieldJets no
    OpaqueDiscrete request -> concatMap valueFieldJets
      (opaqueDiscreteOperands request)
    _ -> []

valueFieldJets :: FEValue -> [FieldJet]
valueFieldJets value =
  case value of
    ScalarValue scalar -> scalarFieldJets scalar
    TensorValue tensor -> tensorFieldJets tensor

assert :: String -> Bool -> IO ()
assert _ True = pure ()
assert label False = fail label

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail (label ++ ": expected " ++ show expected
      ++ ", got " ++ show actual)
