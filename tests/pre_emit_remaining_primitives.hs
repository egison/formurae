module Main where

import Data.List (isInfixOf)

import qualified Formurae.FEIR.PrimitiveBindings as Primitives
import Formurae.Pre.EmitEgison
import Formurae.Pre.Parse (parseModel)

main :: IO ()
main = do
  source <- readFile "tests/fixtures/pre_fec_remaining_primitives.fme"
  model <- parseModel "tests/fixtures/pre_fec_remaining_primitives.fme"
    "remaining-primitives" source
  unit <- requireRight =<< emitNormalizationUnit
    Primitives.primitiveManifestV1Id model
  assertContains "ordered axes become stable IDs"
    "Formurae.orderedDerivative feOperatorContext [| 1, 2 |] u" unit
  assertContains "absolute placement bits remain explicit"
    "Formurae.resampleExplicit feOperatorContext [| 1, 1 |] u" unit
  assertContains "same-typed tensor algebra supplies local metadata"
    "Formurae.materialized feOperatorContext (F + G)"
    unit
  assertContains "nested tensor materialization is parenthesized"
    "Formurae.fluxConservativeDivergence feOperatorContext (Formurae.materialized feOperatorContext (F + G))"
    unit
  assertContains "nested conservative divergence is parenthesized"
    "Formurae.materialized feOperatorContext (Formurae.fluxConservativeDivergence feOperatorContext F)"
    unit

  aliasModel <- parseModel "remaining-aliases.fme" "remaining-aliases"
    aliasSource
  aliasUnit <- requireRight =<< emitNormalizationUnit
    Primitives.primitiveManifestV1Id aliasModel
  assertContains "orderedDerivative alias"
    "Formurae.orderedDerivative feOperatorContext [| 1 |] u" aliasUnit
  assertContains "interpolate alias"
    "Formurae.resampleExplicit feOperatorContext [| 1 |] u" aliasUnit
  assertContains "conservativeDiv alias"
    "Formurae.fluxConservativeDivergence feOperatorContext F" aliasUnit

  genericModel <- parseModel "generic-materialize.fme"
    "generic-materialize" genericSource
  genericUnit <- requireRight =<< emitNormalizationUnit
    Primitives.primitiveManifestV1Id genericModel
  assertContains "generic materialization definition has no static metadata"
    "Formurae.materialized FormuraeInternalContext X" genericUnit
  assertContains "one generic definition accepts an upper vector"
    "def FormuraeInternalValue1 := stored X" genericUnit
  assertContains "the same generic definition accepts a differential form"
    "def FormuraeInternalValue2 := stored A" genericUnit

  badBitsModel <- parseModel "bad-resample.fme" "bad-resample"
    badBitsSource
  badBits <- emitNormalizationUnit Primitives.primitiveManifestV1Id badBitsModel
  assertLeft "resample requires dimension-many literal bits" isBadBits badBits
  putStrLn "pre-fec remaining primitive emitter tests: ok"

aliasSource :: String
aliasSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "field v : scalar @ dual"
  , "field F_i @ primal"
  , "step:"
  , "  u' = orderedDerivative(u, x) + conservativeDiv(F)"
  , "  v' = interpolate(u, 1)"
  , "  F'_i = F_i"
  ]

genericSource :: String
genericSource = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "field X~i @ primal"
  , "field A : 1-form @ primal"
  , "def stored X = materialize(X)"
  , "step:"
  , "  X'~i = stored X"
  , "  A' = stored A"
  ]

badBitsSource :: String
badBitsSource = unlines
  [ "mode collocated"
  , "dimension 2"
  , "axes x, y"
  , "field u : scalar"
  , "step:"
  , "  u' = resample(u, 1)"
  ]

requireRight :: Either EmitError value -> IO value
requireRight (Right value) = pure value
requireRight (Left problem) = fail (show problem)

isBadBits :: EmitError -> Bool
isBadBits problem = case problem of
  EmitAtSource _ nested -> isBadBits nested
  EmitExpressionError message ->
    "needs exactly 2 absolute placement bits" `isInfixOf` message
  _ -> False

assertContains :: String -> String -> String -> IO ()
assertContains label needle haystack
  | needle `isInfixOf` haystack = pure ()
  | otherwise = fail (label ++ ": missing " ++ show needle)

assertLeft
    :: Show value
    => String -> (error -> Bool) -> Either error value -> IO ()
assertLeft label predicate result =
  case result of
    Left problem | predicate problem -> pure ()
    Left _ -> fail (label ++ ": unexpected error")
    Right value -> fail (label ++ ": expected Left, got " ++ show value)
