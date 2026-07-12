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
    "FormuraeInternalOrderedDerivative [| 1, 2 |] u" unit
  assertContains "absolute placement bits remain explicit"
    "FormuraeInternalResampleExplicit [| 1, 1 |] u" unit
  assertContains "same-typed tensor algebra supplies local metadata"
    "FormuraeInternalMaterialized (F + G)"
    unit
  assertContains "nested tensor materialization is parenthesized"
    "FormuraeInternalFluxConservativeDivergence (FormuraeInternalMaterialized (F + G))"
    unit
  assertContains "nested conservative divergence is parenthesized"
    "FormuraeInternalMaterialized (FormuraeInternalFluxConservativeDivergence F)"
    unit

  aliasModel <- parseModel "remaining-aliases.fme" "remaining-aliases"
    aliasSource
  aliasUnit <- requireRight =<< emitNormalizationUnit
    Primitives.primitiveManifestV1Id aliasModel
  assertContains "orderedDerivative alias"
    "FormuraeInternalOrderedDerivative [| 1 |] u" aliasUnit
  assertContains "interpolate alias"
    "FormuraeInternalResampleExplicit [| 1 |] u" aliasUnit
  assertContains "conservativeDiv alias"
    "FormuraeInternalFluxConservativeDivergence F" aliasUnit

  genericModel <- parseModel "generic-materialize.fme"
    "generic-materialize" genericSource
  genericUnit <- requireRight =<< emitNormalizationUnit
    Primitives.primitiveManifestV1Id genericModel
  assertContains "generic materialization definition has no static metadata"
    "FormuraeInternalMaterialized X" genericUnit
  assertNotContains "ambient primitive calls have no hidden context"
    "FormuraeInternalContext" genericUnit
  assertContains "upper-vector equation uses the indexed definition sugar"
    "def FormuraeInternalValue1~i : Tensor MathValue := stored X" genericUnit
  assertContains "indexed result is read back with its declared variance"
    "FormuraeInternalValue1~formuraeTensorIndex1" genericUnit
  assertContains "the same generic definition accepts a differential form"
    "def FormuraeInternalValue2 := stored A" genericUnit

  indexedModel <- parseModel "indexed-targets.fme" "indexed-targets"
    indexedTargetSource
  indexedUnit <- requireRight =<< emitNormalizationUnit
    Primitives.primitiveManifestV1Id indexedModel
  assertContains "indexed let scopes its LHS index over the RHS"
    "def FormuraeInternalValue1_i : Tensor MathValue := B_i" indexedUnit
  assertContains "indexed let alias keeps the same indexed contract"
    "def T_i := FormuraeInternalValue1_i" indexedUnit
  assertContains "indexed field equation scopes its LHS index over the RHS"
    "def FormuraeInternalValue2~i : Tensor MathValue := withSymbols [j] (g~i~j . T_j)"
    indexedUnit
  assertContains "field boundary reads the indexed equation as a whole tensor"
    "FormuraeInternalValue2~formuraeTensorIndex1" indexedUnit
  assertNotContains "equation boundary no longer mutates omitted indices"
    "Formurae.attachExplicitVariances variances value" indexedUnit

  completionModel <- parseModel "indexed-let-completion.fme"
    "indexed-let-completion" indexedLetCompletionSource
  completionUnit <- requireRight =<< emitNormalizationUnit
    Primitives.primitiveManifestV1Id completionModel
  assertContains "bare lower indexed let gets an anonymous lower use-site"
    "def FormuraeInternalValue3_i : Tensor MathValue := T_#" completionUnit
  assertContains "bare mixed indexed let preserves every declared variance"
    "def FormuraeInternalValue4~i_j : Tensor MathValue := U~#_#" completionUnit
  assertContains "explicit indexed let reference remains explicit"
    "def FormuraeInternalValue5_i : Tensor MathValue := T_i" completionUnit

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

indexedTargetSource :: String
indexedTargetSource = unlines
  [ "mode collocated"
  , "dimension 2"
  , "axes x, y"
  , "metric g"
  , "field B_i"
  , "field X~i"
  , "step:"
  , "  let T_i = B_i"
  , "  X'~i = withSymbols [j] (g~i~j . T_j)"
  ]

indexedLetCompletionSource :: String
indexedLetCompletionSource = unlines
  [ "mode collocated"
  , "dimension 2"
  , "axes x, y"
  , "field B_i"
  , "field M~i_j"
  , "field C_i"
  , "field N~i_j"
  , "field D_i"
  , "step:"
  , "  let T_i = B_i"
  , "  let U~i_j = M~i_j"
  , "  C'_i = T"
  , "  N'~i_j = U"
  , "  D'_i = T_i"
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

assertNotContains :: String -> String -> String -> IO ()
assertNotContains label needle haystack
  | needle `isInfixOf` haystack =
      fail (label ++ ": unexpected " ++ show needle)
  | otherwise = pure ()

assertLeft
    :: Show value
    => String -> (error -> Bool) -> Either error value -> IO ()
assertLeft label predicate result =
  case result of
    Left problem | predicate problem -> pure ()
    Left _ -> fail (label ++ ": unexpected error")
    Right value -> fail (label ++ ": expected Left, got " ++ show value)
