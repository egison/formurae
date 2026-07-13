{-# LANGUAGE PatternSynonyms #-}

module Main where

import Data.List (isInfixOf)

import Formurae.Index (ixName, ixVariance)
import Formurae.Pre.Parse (parseModel)
import Formurae.Syntax (Variance(..))
import Formurae.TensorExpr

main :: IO ()
main = do
  assertIdentifierSpans
  assertApplicationSpans
  assertPredicateSyntax
  assertQuotedDerivativeSyntax
  assertQuotedDerivativeNesting
  assertQuotedDerivativeSpans
  assertTensorLiteralSyntax
  assertTensorLiteralNesting
  assertTensorLiteralSpans
  assertRenderIsStable
  assertPreprocessing
  assertQuotedDerivativePreprocessing
  assertTensorLiteralPreprocessing
  assertGenericQuoteIsNotCaptured
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
  case parseTensorExprEither "1 + f (u + f v)" of
    Right (TEBinary "+" _ outer@(TEApply _ [TEGroup (TEBinary "+" _ inner)])) -> do
      assertSpan "outer application" (5, 15) outer
      assertSpan "nested application" (12, 14) inner
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

assertQuotedDerivativeSyntax :: IO ()
assertQuotedDerivativeSyntax = do
  quoted <- requireRight (parseTensorExprEither "`(∂_x (u * u))")
  case quoted of
    TEGridDerivativeChain axes (TEGroup (TEBinary "*" _ _)) ->
      assertEqual "quoted derivative axis" ["x"] (map ixName axes)
    result -> fail ("unexpected quoted-derivative AST: " ++ show result)

  ordinary <- requireRight (parseTensorExprEither "∂_x (u * u)")
  case ordinary of
    TEDerivative axes (TEGroup (TEBinary "*" _ _)) ->
      assertEqual "ordinary derivative remains analytic" ["x"] (map ixName axes)
    result -> fail ("ordinary derivative changed AST: " ++ show result)

assertQuotedDerivativeNesting :: IO ()
assertQuotedDerivativeNesting = do
  nested <- requireRight (parseTensorExprEither
    "`(∂_y (`(∂_x (`(∂_x u)))))")
  case nested of
    TEGridDerivativeChain axes (TEIdent "u" []) ->
      assertEqual "quoted axes are innermost-first and keep duplicates"
        ["x", "x", "y"] (map ixName axes)
    result -> fail ("unexpected nested quoted-derivative AST: " ++ show result)

  let rendered = renderTensorExpr nested
  assertEqual "quoted derivative canonical render"
    "`(d_y (`(d_x (`(d_x u)))))" rendered
  reparsed <- requireRight (parseTensorExprEither rendered)
  assertEqual "quoted derivative rendering is idempotent"
    rendered (renderTensorExpr reparsed)

assertQuotedDerivativeSpans :: IO ()
assertQuotedDerivativeSpans = do
  let source = "`(∂_x (u * u))"
  parsed <- requireRight (parseTensorExprEither source)
  assertSpan "quoted derivative covers backquote and outer group"
    (1, length source) parsed
  case parsed of
    TEGridDerivativeChain _ operand@(TEGroup productExpr) -> do
      assertSpan "quoted derivative operand group" (7, 13) operand
      assertSpan "quoted derivative operand expression" (8, 12) productExpr
    result -> fail ("unexpected quoted span AST: " ++ show result)

assertTensorLiteralSyntax :: IO ()
assertTensorLiteralSyntax = do
  literal <- requireRight (parseTensorExprEither
    "[| -kappa * `(∂_x u), -kappa * `(∂_y u) |]_i")
  case literal of
    TETensorLiteral [first, second] parts -> do
      assertEqual "literal result index" ["i"] (map ixName parts)
      assertEqual "literal result variance" [VDown] (map ixVariance parts)
      assertEqual "quoted derivative children stay structured"
        ["x", "y"] (map componentAxis [first, second])
    result -> fail ("unexpected tensor-literal AST: " ++ show result)
  where
    componentAxis (TEBinary "*" _ (TEGridDerivativeChain [axis] _)) =
      ixName axis
    componentAxis expression =
      error ("unexpected tensor-literal component: " ++ show expression)

assertTensorLiteralNesting :: IO ()
assertTensorLiteralNesting = do
  nested <- requireRight (parseTensorExprEither
    "[| [| 1, 2 |], [| 3, 4 |] |]~i_j")
  case nested of
    TETensorLiteral
        [TETensorLiteral [TENumber "1", TENumber "2"] [],
         TETensorLiteral [TENumber "3", TENumber "4"] []]
        parts -> do
      assertEqual "rank-two literal result indices"
        ["i", "j"] (map ixName parts)
      assertEqual "rank-two literal result variances"
        [VUp, VDown] (map ixVariance parts)
    result -> fail ("unexpected nested tensor-literal AST: " ++ show result)
  let rendered = renderTensorExpr nested
  assertEqual "nested tensor literal canonical render"
    "[| [| 1, 2 |], [| 3, 4 |] |]~i_j" rendered
  reparsed <- requireRight (parseTensorExprEither rendered)
  assertEqual "tensor literal rendering is idempotent"
    rendered (renderTensorExpr reparsed)

assertTensorLiteralSpans :: IO ()
assertTensorLiteralSpans = do
  let source = "[| a, [| b, c |]_j |]~i_j"
  parsed <- requireRight (parseTensorExprEither source)
  assertSpan "tensor literal includes its marked suffix"
    (1, length source) parsed
  case parsed of
    TETensorLiteral [first, nested@(TETensorLiteral [b, c] _)] _ -> do
      assertSpan "first literal component" (4, 4) first
      assertSpan "nested literal includes its suffix" (7, 18) nested
      assertSpan "nested literal first component" (10, 10) b
      assertSpan "nested literal second component" (13, 13) c
    result -> fail ("unexpected tensor-literal span AST: " ++ show result)

assertRenderIsStable :: IO ()
assertRenderIsStable = do
  parsed <- requireRight (parseTensorExprEither
    "if p then withSymbols [i] (d_i u~i) else `(d_x (u * u / 2))")
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

assertQuotedDerivativePreprocessing :: IO ()
assertQuotedDerivativePreprocessing = do
  model <- parseModel "tensor-parser-grid.fme" "tensor-parser-grid" (unlines
    [ "mode collocated"
    , "dimension 2"
    , "axes r, s"
    , "field u : scalar"
    , "step:"
    , "  u' = u"
    ])
  preprocessed <- preprocessTensorExpr model
    "`(d_s (`(d_r (`(d_r u)))))"
  assertEqual "quoted derivative preprocessing preserves axis order"
    "`(d_y (`(d_x (`(d_x u)))))" preprocessed

assertTensorLiteralPreprocessing :: IO ()
assertTensorLiteralPreprocessing = do
  model <- parseModel "tensor-parser-literal.fme" "tensor-parser-literal"
    (unlines
      [ "mode collocated"
      , "dimension 2"
      , "axes r, s"
      , "field u : scalar"
      , "step:"
      , "  u' = u"
      ])
  preprocessed <- preprocessTensorExpr model
    "[| `(d_r u), [| `(d_s u), r |]~i |]_j"
  assertEqual "tensor literal recursively preprocesses its children"
    "[| `(d_x u), [| `(d_y u), x |]~i |]_j" preprocessed

assertGenericQuoteIsNotCaptured :: IO ()
assertGenericQuoteIsNotCaptured =
  case parseTensorExprEither "`(u * u)" of
    Left _ -> pure ()
    Right expression ->
      fail ("generic quote was captured as structured TensorExpr: "
            ++ show expression)

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
