{-# LANGUAGE PatternSynonyms #-}

module Main where

import Formurae.TensorExpr

main :: IO ()
main = do
  case parseTensorExprEither "A_i + A_i" of
    Right (TEBinary "+" lhs rhs) -> do
      assertSpan "first duplicate identifier" (1, 3) lhs
      assertSpan "second duplicate identifier" (7, 9) rhs
    result -> fail ("unexpected duplicate-identifier AST: " ++ show result)

  case parseTensorExprEither "lb u + lb u" of
    Right (TEBinary "+" lhs rhs) -> do
      assertSpan "first duplicate application" (1, 4) lhs
      assertSpan "second duplicate application" (8, 11) rhs
    result -> fail ("unexpected duplicate-application AST: " ++ show result)

  case parseTensorExprEither "1 + lb (u + lb v)" of
    Right (TEBinary "+" _ outer@(TEApply _ [TEGroup (TEBinary "+" _ inner)])) -> do
      assertSpan "outer nested lb application" (5, 17) outer
      assertSpan "inner nested lb application" (13, 16) inner
    result -> fail ("unexpected nested-application AST: " ++ show result)

  putStrLn "fec source span tests: ok"

assertSpan :: String -> (Int, Int) -> TensorExpr -> IO ()
assertSpan label (expectedStart, expectedEnd) expr =
  let actual = tensorExprSpan expr
  in if sourceStart actual == expectedStart && sourceEnd actual == expectedEnd
       then return ()
       else fail (label ++ ": expected " ++ show (expectedStart, expectedEnd)
                  ++ ", got " ++ show actual)
