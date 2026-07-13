module Main where

import Data.List (isPrefixOf, sortOn)

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
  let fields = feProgramFields program
      localFields = sortOn logicalFieldSourceName
        [ field
        | field <- feProgramFields program
        , logicalFieldLifetime field == StepLocalLifetime
        ]
      materializations =
        [ (fieldId, value)
        | Materialize fieldId value _ <- feProgramStepActions program
        ]
  assertEqual "two typed local fields"
    ["storedA", "storedX"] (map logicalFieldSourceName localFields)
  assertEqual "local field metadata survives in the registry"
    [ TensorType [2] [VarianceUp] 0
    , TensorType [2] [VarianceDown] 1
    ]
    (sortOn tensorTypeDfOrder (map logicalFieldTensorType localFields))
  assertEqual "two source-ordered FEIR Materialize actions"
    ["storedX", "storedA"]
    [ logicalFieldSourceName (fieldNamed fields fieldId)
    | (fieldId, _) <- materializations
    ]
  mapM_ (checkMaterialization fields) materializations
  putStrLn "pre-fec typed-local metadata FEIR test: ok"

checkMaterialization
    :: [LogicalFieldDecl]
    -> (FieldId, FEValue)
    -> IO ()
checkMaterialization fields (fieldId, value) = do
  let field = fieldNamed fields fieldId
  tensor <- case value of
    TensorValue result -> pure result
    ScalarValue scalar -> fail
      ("typed tensor local encoded as scalar: " ++ show scalar)
  assertEqual ("materialized value metadata for "
      ++ logicalFieldSourceName field)
    (logicalFieldTensorType field)
    TensorType
      { tensorTypeShape = tensorNFShape tensor
      , tensorTypeVariances = tensorNFVariances tensor
      , tensorTypeDfOrder = tensorNFDfOrder tensor
      }

fieldNamed :: [LogicalFieldDecl] -> FieldId -> LogicalFieldDecl
fieldNamed fields identifier =
  case [field | field <- fields, logicalFieldId field == identifier] of
    [field] -> field
    values -> error ("expected one local field, got " ++ show values)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail (label ++ ": expected " ++ show expected
      ++ ", got " ++ show actual)
