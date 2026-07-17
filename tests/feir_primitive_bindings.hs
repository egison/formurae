module Main (main) where

import Formurae.FEIR.PrimitiveBindingGenerator
import Formurae.FEIR.PrimitiveBindings
import Formurae.FEIR.PrimitiveManifest hiding (primitiveManifestId)
import Formurae.FEIR.Syntax (PrimitiveManifestId(..), OpId(..))

main :: IO ()
main = do
  result <- checkGeneratedPrimitiveBindings
    (defaultGeneratedPrimitivePaths ".")
  either (fail . unlines) pure result
  source <- readFile "spec/feir-primitives.sexp"
  parsed <- either (fail . show) pure (parsePrimitiveManifest source)
  assertEqual "generated full primitive manifest" parsed primitiveManifest
  assertEqual "generated full signature table"
    (primitiveManifestSignatures parsed) primitiveSignatures
  assertEqual "generated manifest ID"
    (PrimitiveManifestId
      "sha256:b7a05af81f6418b2163bd3ef280d911d6409564da41c96d455b872e62d120098")
    primitiveManifestId
  assertEqual "all generated operation IDs"
    [ OpId "derivative.coordinate-wide"
    , OpId "derivative.grid-whole"
    , OpId "derivative.ordered"
    , OpId "resample.explicit"
    ]
    primitiveOperationIds
  mapM_ (assertLookup parsed) primitiveOperationIds
  putStrLn "FEIR generated primitive binding tests: ok"

assertLookup :: PrimitiveManifest -> OpId -> IO ()
assertLookup manifest operationId =
  assertEqual ("generated signature lookup " ++ show operationId)
    [ signature
    | signature <- primitiveManifestSignatures manifest
    , primitiveSignatureOpId signature == operationId
    ]
    (case lookupPrimitiveSignature operationId of
      Just signature -> [signature]
      Nothing -> [])

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
