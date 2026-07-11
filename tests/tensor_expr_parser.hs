{-# LANGUAGE PatternSynonyms #-}

module Main where

import Data.List (isInfixOf)

import Formurae.Pre.Parse (parseModel)
import Formurae.TensorExpr

main :: IO ()
main = do
  assertIdentifierSpans
  assertApplicationSpans
  assertPredicateSyntax
  assertRenderIsStable
  assertPreprocessing
  assertParseDiagnostic
  putStrLn "tensor expression parser tests: ok"

assertIdentifierSpans :: IO ()
assertIdentifierSpans =
  case parseTensorExprEither "A_i + A_i" of
    Right (TEBinary "+" lhs rhs) -> do
      assertSpan "first duplicate identifier" (1, 3) lhs
      assertSpan "second duplicate identifier" (7, 9) rhs
    result -> fail ("unexpected duplicate-identifier AST: " ++ show result)

assertApplicationSpans :: IO ()
assertApplicationSpans =
  case parseTensorExprEither "1 + lb (u + lb v)" of
    Right (TEBinary "+" _ outer@(TEApply _ [TEGroup (TEBinary "+" _ inner)])) -> do
      assertSpan "outer application" (5, 17) outer
      assertSpan "nested application" (13, 16) inner
    result -> fail ("unexpected nested-application AST: " ++ show result)

assertPredicateSyntax :: IO ()
assertPredicateSyntax = do
  negated <- requireRight (parseTensorExprEither "!(x < threshold)")
  case negated of
    TEUnary "!" (TEGroup (TEBinary "<" _ _)) -> pure ()
    result -> fail ("unexpected symbolic-not AST: " ++ show result)
  combined <- requireRight (parseTensorExprEither
    "x < threshold && u >= 0 || False")
  case combined of
    TEBinary "||" (TEBinary "&&" _ _) (TEIdent "False" []) -> pure ()
    result -> fail ("unexpected predicate-precedence AST: " ++ show result)

assertRenderIsStable :: IO ()
assertRenderIsStable = do
  parsed <- requireRight (parseTensorExprEither
    "if p then withSymbols [i] (d_i u~i) else gridD_x (u * u / 2)")
  let rendered = renderTensorExpr parsed
  reparsed <- requireRight (parseTensorExprEither rendered)
  assertEqual "canonical rendering is idempotent"
    rendered (renderTensorExpr reparsed)

assertPreprocessing :: IO ()
assertPreprocessing = do
  model <- parseModel "tensor-parser.fme" "tensor-parser" (unlines
    [ "mode collocated"
    , "dimension 1"
    , "axes r"
    , "field u : scalar"
    , "step:"
    , "  u' = u"
    ])
  coordinate <- preprocessTensorExpr model "pd2r2_r u"
  indexed <- preprocessTensorExpr model "d_r u"
  assertEqual "coordinate derivative axis normalization" "pd2r2_x u" coordinate
  assertEqual "indexed coordinate derivative lowering" "pd1r1_x u" indexed

assertParseDiagnostic :: IO ()
assertParseDiagnostic =
  case parseTensorExprEither "u + )" of
    Left message
      | "column" `isInfixOf` message -> pure ()
      | otherwise -> fail ("parse error has no source column: " ++ message)
    Right expression -> fail ("expected parse failure, got " ++ show expression)

assertSpan :: String -> (Int, Int) -> TensorExpr -> IO ()
assertSpan label (expectedStart, expectedEnd) expression =
  let actual = tensorExprSpan expression
      expected = SourceSpan expectedStart expectedEnd
  in assertEqual label expected actual

requireRight :: Show e => Either e a -> IO a
requireRight result =
  case result of
    Right value -> pure value
    Left problem -> fail (show problem)

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
