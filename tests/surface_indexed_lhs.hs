module Main where

import Data.List (find)

import Formurae.Index
import Formurae.Pre.Parse (parseModel)
import Formurae.Syntax

main :: IO ()
main = do
  assertTargetParser
  assertIndexedSurfaceAst
  assertLocalSurfaceAst
  assertTargetContract
  assertBindingNameSafety
  putStrLn "surface indexed LHS tests: ok"

assertTargetParser :: IO ()
assertTargetParser = do
  assertEqual "primed indexed target keeps multi-character index names"
    (Just
      (IndexedTarget "X" [IxPart VUp "row", IxPart VDown "column"],
       " = rhs"))
    (parsePrimedIndexedTargetPrefix "X'~row_column = rhs")
  assertEqual "ordinary indexed binding target uses the same parser"
    (Just (IndexedTarget "T" [IxPart VDown "i", IxPart VUp "j"],
           " = rhs"))
    (parseIndexedTargetPrefix "T_i~j = rhs")

assertIndexedSurfaceAst :: IO ()
assertIndexedSurfaceAst = do
  model <- parseModel "indexed-lhs.fme" "indexed-lhs" source
  field <- requireJust "field X" $ find ((== "X") . fdName) (mFieldDecls model)
  assertEqual "field declaration retains its upper-index contract"
    (Just [IxPart VUp "i"]) (fieldIndexParts field)
  case mSteps model of
    [step] -> do
      assertEqual "step target is one indexed AST node"
        (IndexedTarget "X" [IxPart VUp "i"]) (sTarget step)
      assertEqual "Egison-style RHS is preserved"
        "withSymbols [j] (g~i~j . A_j)" (sEx step)
    steps -> fail ("expected one indexed step, got " ++ show steps)
  where
    source = unlines
      [ "mode collocated"
      , "dimension 2"
      , "axes x, y"
      , "metric g"
      , "field A_j"
      , "field X~i"
      , "step:"
      , "  X'~i = withSymbols [j] (g~i~j . A_j)"
      ]

assertLocalSurfaceAst :: IO ()
assertLocalSurfaceAst = do
  model <- parseModel "local-lhs.fme" "local-lhs" source
  case mSteps model of
    [vectorLocal, tensorLocal, formLocal] -> do
      assertEqual "indexed local retains its target"
        (IndexedTarget "q" [IxPart VDown "i"])
        (sTarget vectorLocal)
      assertEqual "indexed local retains its declared policy and vector kind"
        (Just (LocalDecl "q"
          (Just (FieldIndex (Plain [IxPart VDown "i"])))
          Primal Vector 6))
        (sLocalDecl vectorLocal)
      assertEqual "rank-two local retains mixed variance and dual policy"
        (Just (LocalDecl "A"
          (Just (FieldIndex
            (Plain [IxPart VUp "i", IxPart VDown "j"])))
          Dual Tensor2 7))
        (sLocalDecl tensorLocal)
      assertEqual "form local is a whole-tensor target"
        (IndexedTarget "omega" []) (sTarget formLocal)
      assertEqual "omitted local form policy defaults to collocated"
        (Just (LocalDecl "omega" Nothing Collocated (Form 2) 8))
        (sLocalDecl formLocal)
    steps -> fail ("expected three local steps, got " ++ show steps)
  where
    source = unlines
      [ "mode dec"
      , "dimension 3"
      , "axes x, y, z"
      , "field u : scalar"
      , "step:"
      , "  local q_i @ primal = [| 1, 2, 3 |]_i"
      , "  local A~i_j @ dual = [| [| 1, 2, 3 |], [| 4, 5, 6 |], [| 7, 8, 9 |] |]~i_j"
      , "  local omega : 2-form = d q"
      ]

assertTargetContract :: IO ()
assertTargetContract = do
  assertEqual "matching upper LHS is accepted"
    (Right ())
    (validateFieldTarget upperVector
      (IndexedTarget "X" [IxPart VUp "k"]))
  assertEqual "whole-tensor assignment remains available"
    (Right ())
    (validateFieldTarget upperVector (IndexedTarget "X" []))
  assertEqual "LHS variance must match field declaration"
    (Left (IndexedTargetVarianceMismatch 1 VUp VDown))
    (validateFieldTarget upperVector
      (IndexedTarget "X" [IxPart VDown "i"]))
  assertEqual "LHS rank must match field declaration"
    (Left (IndexedTargetRankMismatch 1 2))
    (validateFieldTarget upperVector
      (IndexedTarget "X" [IxPart VUp "i", IxPart VUp "j"]))
  where
    upperVector = FieldDecl "X"
      (Just (FieldIndex (Plain [IxPart VUp "i"])))
      Collocated Vector 1

assertBindingNameSafety :: IO ()
assertBindingNameSafety = do
  assertEqual "duplicate free LHS index is rejected"
    (Left (DuplicateTargetIndex "i"))
    (validateBindingIndices [] [IxPart VUp "i", IxPart VDown "i"])
  assertEqual "coordinate cannot be shadowed by implicit withSymbols"
    (Left (TargetIndexNameConflict "x"))
    (validateBindingIndices ["x", "feCoordinates"] [IxPart VUp "x"])
  assertEqual "generated value cannot be shadowed by implicit withSymbols"
    (Left (TargetIndexNameConflict "feCoordinates"))
    (validateBindingIndices ["x", "feCoordinates"]
      [IxPart VUp "feCoordinates"])
  assertEqual "ordinary symbolic index remains available"
    (Right ())
    (validateBindingIndices ["x", "feCoordinates"] [IxPart VUp "i"])

requireJust :: String -> Maybe a -> IO a
requireJust _ (Just value) = pure value
requireJust label Nothing = fail ("missing " ++ label)

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
