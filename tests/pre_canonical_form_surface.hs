{-# LANGUAGE PatternSynonyms #-}

module Main where

import Data.List (find)

import Formurae.Index (ixName)
import Formurae.Pre.FormOperator
import Formurae.Pre.Parse (parseModel)
import Formurae.Syntax
import Formurae.TensorExpr

main :: IO ()
main = do
  model <- parseModel "canonical-form.fme" "canonical-form" source
  codifferential <- definitionNamed "co" model
  hodgeLaplacian <- definitionNamed "hodgeLap" model
  kronecker <- definitionNamed "identity" model

  assertEqual "unindexed Unicode delta stays distinct from ASCII delta"
    "δ A" (defBody codifferential)
  case parseTensorExprEither (defBody codifferential) of
    Right (TEApply (TEIdent "δ" []) [TEIdent "A" []]) -> pure ()
    result -> fail ("unexpected codifferential AST: " ++ show result)

  assertEqual "Delta-sub-H has one atomic internal spelling"
    "ΔH A" (defBody hodgeLaplacian)
  case parseTensorExprEither (defBody hodgeLaplacian) of
    Right (TEApply (TEIdent "ΔH" []) [TEIdent "A" []]) -> pure ()
    result -> fail ("unexpected Hodge-Laplacian AST: " ++ show result)

  sourceText <- requireJust "Hodge-Laplacian source map"
    (defSourceText hodgeLaplacian)
  assertEqual "source spelling remains mathematical"
    "Δ_H A" (sourceOriginal sourceText)
  assertEqual "translated spelling is atomic"
    "ΔH A" (sourceTranslated sourceText)
  let start = sourceColumn sourceText
  assertEqual "atomic spelling maps across the source underscore"
    [ SourcePosition 8 start
    , SourcePosition 8 (start + 2)
    ]
    (take 2 (sourcePositionMap sourceText))

  assertEqual "marked Unicode delta keeps the Kronecker runtime spelling"
    "withSymbols [i, j] (FormuraeInternalKroneckerDelta~i_j . X~j)"
    (defBody kronecker)
  case parseTensorExprEither (defBody kronecker) of
    Right (TEWithSymbols _ (TEGroup (TEDot
      [TEIdent "FormuraeInternalKroneckerDelta" parts, TEIdent "X" _]))) ->
        assertEqual "Kronecker indices survive transliteration"
          ["i", "j"] (map ixName parts)
    result -> fail ("unexpected Kronecker AST: " ++ show result)

  asciiModel <- parseModel "ascii-shadow.fme" "ascii-shadow" asciiSource
  assertEqual "removed ASCII names remain available to user definitions"
    ["dForm", "delta", "codiff", "formLaplacian", "lb"]
    (map defName (mDefs asciiModel))

  let visible = OperatorScope []
      shadowedDelta = OperatorScope ["δ"]
      exactDelta = parseTensorExpr "0 - δ (d u)"
  assertEqual "exact unshadowed scalar identity is recognized"
    (Just "u") (identifierName <$> matchScalarDeltaExpression visible exactDelta)
  assertEqual "a shadowed codifferential prevents scalar fusion"
    Nothing (matchScalarDeltaExpression shadowedDelta exactDelta)
  assertEqual "an algebraic near miss is not scalar fusion"
    Nothing (matchScalarDeltaExpression visible
      (parseTensorExpr "1 - δ (d u)"))
  assertEqual "explicit hodge-d-hodge composition is recognized structurally"
    (Just "A") (identifierName <$> matchHodgeExteriorHodge visible
      (parseTensorExpr "hodge (d (hodge A))"))
  assertEqual "shadowed hodge is not treated as the canonical adjoint"
    Nothing (matchHodgeExteriorHodge (OperatorScope ["hodge"])
      (parseTensorExpr "hodge (d (hodge A))"))
  assertEqual "scalar Delta is collocated-only"
    (Just "canonical scalar Δ requires mode collocated; use Δ_H for differential forms")
    (canonicalOperatorModeError DecMode CanonicalScalarLaplacian)
  assertEqual "codifferential is DEC-only"
    (Just "canonical δ requires mode dec")
    (canonicalOperatorModeError CollocatedMode CanonicalCodifferential)

  putStrLn "pre-fec canonical form surface parser tests: ok"

source :: String
source = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "field A : 1-form"
  , "def delta x = 0"
  , "def co A = δ A"
  , "def identity X = withSymbols [i, j] (δ~i_j . X~j)"
  , "def hodgeLap A = Δ_H A"
  , "step:"
  , "  A' = A"
  ]

asciiSource :: String
asciiSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "def dForm x = x"
  , "def delta x = dForm x"
  , "def codiff x = delta x"
  , "def formLaplacian x = codiff x"
  , "def lb x = formLaplacian x"
  , "step:"
  , "  u' = lb u"
  ]

definitionNamed :: String -> Model -> IO Def
definitionNamed name model = requireJust ("definition " ++ name)
  (find ((== name) . defName) (mDefs model))

requireJust :: String -> Maybe value -> IO value
requireJust _ (Just value) = pure value
requireJust label Nothing = fail (label ++ ": missing")

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)

identifierName :: TensorExpr -> String
identifierName (TEIdent name []) = name
identifierName expression = error ("expected identifier, got " ++ show expression)
