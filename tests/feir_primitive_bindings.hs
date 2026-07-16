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
      "sha256:15edbc55825f7b9ff02836c67d852b46635f34d7b94a0397d750243b555aa9fb")
    primitiveManifestV1Id
  assertEqual "all generated operation IDs"
    [ VersionedOpId "derivative.coordinate-wide@1"
    , VersionedOpId "derivative.grid-whole@1"
    , VersionedOpId "derivative.ordered@1"
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
