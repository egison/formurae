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
    Primitives.primitiveManifestId model
  assertContains "nested quoted-derivative axes become stable IDs"
    "FormuraeInternalOrderedDerivative [| 1, 2 |] u" unit
  assertContains "canonical resample keeps absolute placement bits explicit"
    "FormuraeInternalResampleExplicit [| 1, 1 |] u" unit
  assertContains "ordered derivative bridge uses ambient model metadata"
    "def FormuraeInternalOrderedDerivative axes value := Formurae.gridDerivativeChain axes value"
    unit
  assertContains "resample bridge uses ambient model metadata"
    "def FormuraeInternalResampleExplicit bits value := Formurae.resampleExplicit bits value"
    unit
  assertContains "typed indexed local scopes its index over the stored RHS"
    "def FormuraeInternalValue1_i : Tensor MathValue := F_i + G_i" unit
  assertContains "typed indexed local uses FEIR tensor materialization"
    "FormuraeInternalEncodeTensor [2] [\"down\"] 0 FormuraeInternalValue1"
    unit
  mapM_ (\removed -> assertNotContains
      "removed primitive bridge is absent" removed unit)
    [ "FormuraeInternalFluxConservativeDivergence"
    , "FormuraeInternalMaterialized"
    ]

  indexedModel <- parseModel "indexed-targets.fme" "indexed-targets"
    indexedTargetSource
  indexedUnit <- requireRight =<< emitNormalizationUnit
    Primitives.primitiveManifestId indexedModel
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
    Primitives.primitiveManifestId completionModel
  assertContains "bare lower indexed let gets an anonymous lower use-site"
    "def FormuraeInternalValue3_i : Tensor MathValue := T_#" completionUnit
  assertContains "bare mixed indexed let preserves every declared variance"
    "def FormuraeInternalValue4~i_j : Tensor MathValue := U~#_#" completionUnit
  assertContains "explicit indexed let reference remains explicit"
    "def FormuraeInternalValue5_i : Tensor MathValue := T_i" completionUnit

  localModel <- parseModel "tensor-locals.fme" "tensor-locals"
    tensorLocalSource
  localUnit <- requireRight =<< emitNormalizationUnit
    Primitives.primitiveManifestId localModel
  assertContains "indexed local scopes its LHS index over the RHS"
    "def FormuraeInternalValue1_i : Tensor MathValue := Q_i"
    localUnit
  assertContains "rank-two local keeps mixed variance metadata"
    "def FormuraeInternalValue2~i_j : Tensor MathValue := T~i_j"
    localUnit
  assertContains "form local keeps the mathematical form result"
    "def FormuraeInternalValue3 := FormuraeInternalD A" localUnit
  assertContains "vector local is encoded as a tensor materialization"
    "FormuraeInternalEncodeTensor [2] [\"down\"] 0 FormuraeInternalValue1"
    localUnit
  assertContains "rank-two local is encoded as a tensor materialization"
    "FormuraeInternalEncodeTensor [2,2] [\"up\",\"down\"] 0 FormuraeInternalValue2"
    localUnit
  assertContains "form local keeps its degree at the FEIR boundary"
    "FormuraeInternalEncodeTensor [2,2] [\"down\",\"down\"] 2 FormuraeInternalValue3"
    localUnit

  badBitsModel <- parseModel "bad-resample.fme" "bad-resample"
    badBitsSource
  badBits <- emitNormalizationUnit Primitives.primitiveManifestId badBitsModel
  assertLeft "resample requires dimension-many literal bits" isBadBits badBits
  putStrLn "pre-fec remaining primitive emitter tests: ok"

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

tensorLocalSource :: String
tensorLocalSource = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "field A : 1-form @ primal"
  , "field Q_i @ primal"
  , "field T~i_j @ dual"
  , "step:"
  , "  local q_i @ primal = Q_i"
  , "  local stress~i_j @ dual = T~i_j"
  , "  local omega : 2-form @ primal = d A"
  , "  A' = A"
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
