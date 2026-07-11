{-# LANGUAGE PatternSynonyms #-}

module Main where

import Formurae.TensorExpr
import Formurae.Syntax

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

  let mapped = SourceText
        { sourcePath = "mapped.fme"
        , sourceLine = 10
        , sourceColumn = 5
        , sourceOriginal = "α + lb u"
        , sourceTranslated = "alpha + lb u"
        , sourcePositionMap = positions 10 5
            [1, 1, 1, 1, 1, 2, 3, 4, 5, 6, 7, 8]
        }
  case parseSourceTensorExpr mapped of
    Right (TEBinary "+" _ request) ->
      assertOrigin "pre-transliteration request" (10, 9, 10, 12) [] request
    result -> fail ("unexpected source-mapped AST: " ++ show result)

  let definitionSource = SourceText
        { sourcePath = "definitions.fme"
        , sourceLine = 4
        , sourceColumn = 12
        , sourceOriginal = "α + lb q"
        , sourceTranslated = "alpha + lb q"
        , sourcePositionMap = positions 4 12
            [1, 1, 1, 1, 1, 2, 3, 4, 5, 6, 7, 8]
        }
      callSource = SourceText
        { sourcePath = "model.fme"
        , sourceLine = 8
        , sourceColumn = 8
        , sourceOriginal = "op u"
        , sourceTranslated = "op u"
        , sourcePositionMap = positions 8 8 [1, 2, 3, 4]
        }
      operator = Def "op" ["q"] "alpha + lb q" (Just definitionSource)
  expanded <- expandDefsWithSource [operator] callSource
  case expanded of
    TEBinary "+" _ request ->
      assertOrigin "definition expansion" (4, 16, 4, 19)
        [("op", (4, 12, 4, 19), (8, 8, 8, 11))] request
    result -> fail ("unexpected expanded source-mapped AST: " ++ show result)

  let multiline = SourceText
        { sourcePath = "initializer.fme"
        , sourceLine = 8
        , sourceColumn = 12
        , sourceOriginal = "0,\nlb(v)"
        , sourceTranslated = "0, lb(v)"
        , sourcePositionMap =
            [ SourcePosition 8 12, SourcePosition 8 13
            , SourcePosition 9 10, SourcePosition 9 11
            , SourcePosition 9 12, SourcePosition 9 13
            , SourcePosition 9 14, SourcePosition 9 15
            ]
        }
  assertLocation "multiline source position"
    (9, 11, 9, 12) (sourceLocationForSpan multiline (SourceSpan 4 5))

  putStrLn "fec source span tests: ok"

assertSpan :: String -> (Int, Int) -> TensorExpr -> IO ()
assertSpan label (expectedStart, expectedEnd) expr =
  let actual = tensorExprSpan expr
  in if sourceStart actual == expectedStart && sourceEnd actual == expectedEnd
       then return ()
       else fail (label ++ ": expected " ++ show (expectedStart, expectedEnd)
                  ++ ", got " ++ show actual)

assertOrigin
  :: String
  -> (Int, Int, Int, Int)
  -> [(String, (Int, Int, Int, Int), (Int, Int, Int, Int))]
  -> TensorExpr
  -> IO ()
assertOrigin label expectedLocation expectedTrace expr =
  case tensorExprOrigin expr of
    Nothing -> fail (label ++ ": missing source origin")
    Just origin -> do
      assertLocation (label ++ " location") expectedLocation (originLocation origin)
      let actualTrace =
            [ (expansionName frame,
               locationTuple (expansionDefinition frame),
               locationTuple (expansionCall frame))
            | frame <- originTrace origin]
      if actualTrace == expectedTrace
        then return ()
        else fail (label ++ ": expected trace " ++ show expectedTrace
                   ++ ", got " ++ show actualTrace)

assertLocation :: String -> (Int, Int, Int, Int) -> SourceLocation -> IO ()
assertLocation label expected actual =
  if locationTuple actual == expected
    then return ()
    else fail (label ++ ": expected " ++ show expected
               ++ ", got " ++ show (locationTuple actual))

locationTuple :: SourceLocation -> (Int, Int, Int, Int)
locationTuple location =
  (locationLine location, locationStartColumn location,
   locationEndLine location,
   locationEndColumn location)

positions :: Int -> Int -> [Int] -> [SourcePosition]
positions lineNumber column offsets =
  [SourcePosition lineNumber (column + offset - 1) | offset <- offsets]
