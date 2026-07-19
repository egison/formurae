module Main where

import Control.Monad (unless)
import Data.List (find)
import System.Exit (exitFailure)

import qualified Formurae.FEIR.PrimitiveBindings as Bindings
import Formurae.FEIR.PrimitiveManifest
import Formurae.FEIR.SExpr (SExpr(..), parseSExpr, renderSExpr)
import Formurae.FEIR.Syntax (Fingerprint(..), PrimitiveManifestId(..), OpId(..))

main :: IO ()
main = do
  source <- readFile "spec/feir-primitives.sexp"
  manifest <- expectRight "parse canonical manifest" (parsePrimitiveManifest source)
  assertEqual "generated manifest matches the parsed source"
    manifest Bindings.primitiveManifest

  assertEqual
    "required operation IDs"
    (map OpId
      [ "boundary.sbp-trace"
      , "derivative.coordinate-wide"
      , "derivative.grid-whole"
      , "derivative.ordered"
      , "resample.explicit"
      ])
    (map primitiveSignatureOpId (primitiveManifestSignatures manifest))

  -- No v1 operation materializes any more, but the manifest grammar keeps
  -- the vocabulary; a synthetic entry checks placement, role parsing, and
  -- the canonical role order.
  materializing <- expectRight "parse materializing grammar"
    (parsePrimitiveManifest materializingManifest)
  synthetic <- expectJust "synthetic materializing signature"
    (find ((== OpId "test.materializing")
      . primitiveSignatureOpId)
      (primitiveManifestSignatures materializing))
  assertEqual "materializing placement" ConservativeCellPlacement
    (primitiveSignaturePlacement synthetic)
  assertEqual
    "materialization roles are canonically ordered"
    (NeedsMaterialization
      [CoefficientRole, FluxRole, ResultRole, VolumeRole])
    (primitiveSignatureEffect synthetic)
  assertEqual "declared-commutative semantics" DeclaredCommutative
    (primitiveSignatureCommutation synthetic)

  gridWhole <- expectJust "grid-whole derivative signature"
    (find ((== OpId "derivative.grid-whole")
      . primitiveSignatureOpId)
      (primitiveManifestSignatures manifest))
  assertEqual "grid-whole scalar input"
    [ScalarCategory]
    (primitiveSignatureInputs gridWhole)
  assertEqual "grid-whole scalar output"
    ScalarCategory
    (primitiveSignatureOutput gridWhole)
  assertEqual "grid-whole derivative target placement"
    DerivativeTargetPlacement
    (primitiveSignaturePlacement gridWhole)
  assertEqual "grid-whole local effect"
    PureLocal
    (primitiveSignatureEffect gridWhole)
  assertEqual "grid-whole ordered semantics"
    Ordered
    (primitiveSignatureCommutation gridWhole)

  let canonical = canonicalPrimitiveManifest manifest
  assertEqual
    "canonical round trip"
    (Right manifest)
    (parsePrimitiveManifest (renderSExpr canonical))

  reordered <- expectRight "parse source for reordering" (parseSExpr source)
  let reorderedSource = renderSExpr (reversePrimitiveEntries reordered)
  reorderedManifest <- expectRight
    "declaration order is not semantic"
    (parsePrimitiveManifest reorderedSource)
  assertEqual "canonical declaration order" manifest reorderedManifest
  assertEqual
    "declaration order fingerprint"
    (primitiveManifestFingerprint manifest)
    (primitiveManifestFingerprint reorderedManifest)

  assertEqual
    "canonical fingerprint"
    (Fingerprint
      "sha256:0ee432464c88e9939507b33379103bdddb344f032bbfef930eda05467060d009")
    (primitiveManifestFingerprint manifest)
  assertEqual
    "manifest ID is its fingerprint"
    (case primitiveManifestFingerprint manifest of
       Fingerprint value -> PrimitiveManifestId value)
    (primitiveManifestId manifest)

  assertLeft "unknown category"
    (parsePrimitiveManifest (singlePrimitive "(inputs mystery)" validEffects))
  assertLeft "unknown field"
    (parsePrimitiveManifest
      (singlePrimitiveWithExtra "(mystery unsupported)"))
  assertLeft "duplicate field"
    (parsePrimitiveManifest
      (singlePrimitiveWithExtra "(output scalar)"))
  assertLeft "op declaration takes exactly one name"
    (parsePrimitiveManifest
      (singlePrimitiveWithOp "(op test.invalid 0)"))
  assertLeft "duplicate operation"
    (parsePrimitiveManifest
      (manifestEnvelope (validPrimitive ++ validPrimitive)))
  assertLeft "empty materialization roles"
    (parsePrimitiveManifest
      (singlePrimitive "(inputs scalar)" "(effects needs-materialization)"))
  assertLeft "duplicate materialization role"
    (parsePrimitiveManifest
      (singlePrimitive "(inputs scalar)"
        "(effects needs-materialization flux flux)"))
  assertLeft "unknown placement"
    (parsePrimitiveManifest
      (replacePlacement "(placement nowhere)"))
  assertLeft "placement and output category must agree"
    (parsePrimitiveManifest (manifestEnvelope (unlines
      [ "  (primitive"
      , "    (op test.invalid-placement)"
      , "    (inputs scalar)"
      , "    (output tensor)"
      , "    (placement derivative-target)"
      , "    (effects pure-local)"
      , "    (commutation ordered))"
      ])))
  assertLeft "schema declaration takes no version"
    (parsePrimitiveManifest
      "(primitive-manifest (schema formurae-feir-primitives 2))")

  putStrLn "FEIR primitive manifest tests: ok"

validPrimitive :: String
validPrimitive = unlines
  [ "  (primitive"
  , "    (op test.valid)"
  , "    (inputs scalar)"
  , "    (output scalar)"
  , "    (placement preserve-source)"
  , "    (effects pure-local)"
  , "    (commutation ordered))"
  ]

materializingManifest :: String
materializingManifest = manifestEnvelope (unlines
  [ "  (primitive"
  , "    (op test.materializing)"
  , "    (inputs scalar)"
  , "    (output scalar)"
  , "    (placement conservative-cell)"
  , "    (effects needs-materialization volume coefficient result flux)"
  , "    (commutation declared-commutative))"
  ])

validEffects :: String
validEffects = "(effects pure-local)"

singlePrimitive :: String -> String -> String
singlePrimitive inputs effects = manifestEnvelope (unlines
  [ "  (primitive"
  , "    (op test.valid)"
  , "    " ++ inputs
  , "    (output scalar)"
  , "    (placement preserve-source)"
  , "    " ++ effects
  , "    (commutation ordered))"
  ])

singlePrimitiveWithExtra :: String -> String
singlePrimitiveWithExtra extra = manifestEnvelope (unlines
  [ "  (primitive"
  , "    (op test.valid)"
  , "    (inputs scalar)"
  , "    (output scalar)"
  , "    (placement preserve-source)"
  , "    (effects pure-local)"
  , "    (commutation ordered)"
  , "    " ++ extra ++ ")"
  ])

singlePrimitiveWithOp :: String -> String
singlePrimitiveWithOp op = manifestEnvelope (unlines
  [ "  (primitive"
  , "    " ++ op
  , "    (inputs scalar)"
  , "    (output scalar)"
  , "    (placement preserve-source)"
  , "    (effects pure-local)"
  , "    (commutation ordered))"
  ])

replacePlacement :: String -> String
replacePlacement placement = manifestEnvelope (unlines
  [ "  (primitive"
  , "    (op test.valid)"
  , "    (inputs scalar)"
  , "    (output scalar)"
  , "    " ++ placement
  , "    (effects pure-local)"
  , "    (commutation ordered))"
  ])

manifestEnvelope :: String -> String
manifestEnvelope body =
  "(primitive-manifest\n"
  ++ "  (schema formurae-feir-primitives)\n"
  ++ body
  ++ ")\n"

reversePrimitiveEntries :: SExpr -> SExpr
reversePrimitiveEntries
  (List [Atom "primitive-manifest", schema]) =
    List [Atom "primitive-manifest", schema]
reversePrimitiveEntries
  (List (Atom "primitive-manifest" : schema : primitives)) =
    List (Atom "primitive-manifest" : schema : reverse primitives)
reversePrimitiveEntries value = value

expectRight :: Show e => String -> Either e a -> IO a
expectRight label result =
  case result of
    Right value -> pure value
    Left err -> failTest (label ++ ": " ++ show err)

expectJust :: String -> Maybe a -> IO a
expectJust label value =
  case value of
    Just result -> pure result
    Nothing -> failTest (label ++ ": missing value")

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual =
  unless (expected == actual) $
    failTest
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)

assertLeft :: Show a => String -> Either e a -> IO ()
assertLeft label result =
  case result of
    Left _ -> pure ()
    Right value -> failTest (label ++ ": unexpectedly accepted " ++ show value)

failTest :: String -> IO a
failTest message = do
  putStrLn message
  exitFailure
