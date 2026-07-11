module Main (main) where

import Formurae.FEIR.PrimitiveBindingGenerator
import Formurae.FEIR.PrimitiveBindings
import Formurae.FEIR.PrimitiveManifest
import Formurae.FEIR.Syntax (PrimitiveManifestId(..), VersionedOpId(..))

main :: IO ()
main = do
  result <- checkGeneratedPrimitiveBindings
    (defaultGeneratedPrimitivePaths ".")
  either (fail . unlines) pure result
  source <- readFile "spec/feir-primitives-v1.sexp"
  parsed <- either (fail . show) pure (parsePrimitiveManifest source)
  assertEqual "generated full primitive manifest" parsed primitiveManifestV1
  assertEqual "generated full signature table"
    (primitiveManifestSignatures parsed) primitiveSignaturesV1
  assertEqual "generated manifest ID"
    (PrimitiveManifestId
      "sha256:f6294c222255af0cbc20d76a46e6eecb1858d3c4a370500f9c7c8b510a18010f")
    primitiveManifestV1Id
  assertEqual "all generated operation IDs"
    [ VersionedOpId "codiff.metric@1"
    , VersionedOpId "derivative.coordinate-wide@1"
    , VersionedOpId "derivative.grid-whole@1"
    , VersionedOpId "derivative.ordered@1"
    , VersionedOpId "flux.conservative-divergence@1"
    , VersionedOpId "lb.orthogonal@1"
    , VersionedOpId "operator.materialized@1"
    , VersionedOpId "resample.explicit@1"
    ]
    primitiveOperationIds
  mapM_ (assertLookup parsed) primitiveOperationIds
  putStrLn "FEIR generated primitive binding tests: ok"

assertLookup :: PrimitiveManifest -> VersionedOpId -> IO ()
assertLookup manifest operationId =
  assertEqual ("generated signature lookup " ++ show operationId)
    [ signature
    | signature <- primitiveManifestSignatures manifest
    , primitiveSignatureOpId signature == operationId
    ]
    (case lookupPrimitiveSignatureV1 operationId of
      Just signature -> [signature]
      Nothing -> [])

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
