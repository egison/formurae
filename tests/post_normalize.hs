module Main where

import Formurae.FEIR.Syntax (NamedConstant(..))
import Formurae.Post.FMR
import Formurae.Post.Normalize

main :: IO ()
main = do
  let u = FGridReference "u" [GridIndex "i" 0]
      v = FGridReference "v" [GridIndex "i" 0]
  assertEqual "flatten and combine like terms"
    (FAdd [v, FMul [FExact 5 1, u]])
    (normalizeExpr (FAdd
      [ FMul [FExact 2 1, u]
      , FAdd [FMul [FExact 3 1, u], v]
      , FMul [FExact 0 1, v]
      ]))
  assertEqual "exact rational fold"
    (FExact 1 6)
    (normalizeExpr (FDiv (FExact 2 3) (FExact 4 1)))
  assertEqual "power fold"
    (FExact 1 8)
    (normalizeExpr (FPow (FExact 2 1) (FExact (-3) 1)))
  assertEqual "select equal branches"
    u (normalizeExpr (FSelect (FVariable "condition") u u))
  assertEqual "deterministic multiplication"
    (FMul [u, v]) (normalizeExpr (FMul [v, FExact 1 1, u]))
  assertEqual "named pi remains symbolic during rational normalization"
    (FDiv (FMul [FExact 19 1, FNamedConstant Pi]) (FExact 24 1))
    (normalizeExpr
      (FDiv (FMul [FExact 19 1, FNamedConstant Pi]) (FExact 24 1)))
  putStrLn "post normalize tests: ok"

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
