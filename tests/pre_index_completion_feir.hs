module Main where

import Data.List (isPrefixOf)

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
  assertEquationType program "q"
    (TensorType [2] [VarianceDown] 0)
  assertEquationType program "D"
    (TensorType [2] [VarianceDown] 1)
  assertEquationType program "H"
    (TensorType [2] [VarianceDown] 1)
  putStrLn "pre-fec structural index completion FEIR test: ok"

assertEquationType :: FEProgram -> String -> TensorType -> IO ()
assertEquationType program fieldName expected = do
  fieldId <- case
      [ logicalFieldId field
      | field <- feProgramFields program
      , logicalFieldSourceName field == fieldName
      ] of
    [identifier] -> pure identifier
    identifiers -> fail
      ("expected one field named " ++ show fieldName ++ ", got " ++ show identifiers)
  tensor <- case
      [ feEquationRhs equation
      | UpdateField equation <- feProgramStepActions program
      , targetField (feEquationTarget equation) == fieldId
      ] of
    [value] -> pure value
    values -> fail
      ("expected one equation for " ++ show fieldName ++ ", got " ++ show values)
  let actual = TensorType
        (tensorNFShape tensor)
        (tensorNFVariances tensor)
        (tensorNFDfOrder tensor)
  assertEqual (fieldName ++ " equation tensor metadata") expected actual

targetField :: FieldTarget -> FieldId
targetField target = case target of
  WholeFieldTarget fieldId _ -> fieldId
  FieldComponentTarget fieldId _ _ -> fieldId

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
