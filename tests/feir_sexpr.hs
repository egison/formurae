module Main where

import Control.Monad (unless)
import System.Exit (exitFailure)

import Formurae.FEIR.SExpr

main :: IO ()
main = do
  let fixture =
        List
          [ Atom "feir"
          , Atom "1"
          , List [Atom "name", StringAtom "Maxwell — E・B"]
          , List [Atom "exact", Atom "-1", Atom "12"]
          , List [Atom "escaped", StringAtom "a\n\"b\\c"]
          ]
      encoded = renderSExpr fixture
  assertEqual "round trip" (Right fixture) (parseSExpr encoded)
  assertEqual
    "comments and Unicode escape"
    (Right (List [Atom "x", StringAtom "A"] ))
    (parseSExpr "; header\n(x \"\\u{41}\")")
  assertLeft "trailing form" (parseSExpr "(x) (y)")
  assertLeft "unterminated list" (parseSExpr "(x")
  assertLeft "unexpected close" (parseSExpr ")")
  assertLeft "invalid escape" (parseSExpr "\"\\q\"")
  putStrLn "FEIR S-expression tests: ok"

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual =
  unless (expected == actual) $ do
    putStrLn (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
    exitFailure

assertLeft :: Show a => String -> Either e a -> IO ()
assertLeft label result =
  case result of
    Left _ -> pure ()
    Right value -> do
      putStrLn (label ++ ": unexpectedly parsed " ++ show value)
      exitFailure
