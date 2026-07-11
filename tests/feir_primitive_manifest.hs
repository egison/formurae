module Main where

import Control.Monad (unless)
import Data.List (find)
import System.Exit (exitFailure)

import qualified Formurae.FEIR.PrimitiveBindings as Bindings
import Formurae.FEIR.PrimitiveManifest
import Formurae.FEIR.SExpr (SExpr(..), parseSExpr, renderSExpr)
import Formurae.FEIR.Syntax (Fingerprint(..), PrimitiveManifestId(..), VersionedOpId(..))

main :: IO ()
main = do
  source <- readFile "spec/feir-primitives-v1.sexp"
  manifest <- expectRight "parse canonical manifest" (parsePrimitiveManifest source)
  assertEqual "generated manifest matches the parsed source"
    manifest Bindings.primitiveManifestV1

  assertEqual "schema version" 1 (primitiveManifestSchemaVersion manifest)
  assertEqual
    "required v1 operation IDs"
    (map VersionedOpId
      [ "codiff.metric@1"
      , "derivative.coordinate-wide@1"
      , "derivative.grid-whole@1"
      , "derivative.ordered@1"
      , "flux.conservative-divergence@1"
      , "lb.orthogonal@1"
      , "operator.materialized@1"
      , "resample.explicit@1"
      ])
    (map primitiveSignatureOpId (primitiveManifestSignatures manifest))

  lb <- expectJust "lb signature"
    (find ((== VersionedOpId "lb.orthogonal@1") . primitiveSignatureOpId)
      (primitiveManifestSignatures manifest))
  assertEqual "lb placement" ConservativeCellPlacement
    (primitiveSignaturePlacement lb)
  assertEqual
    "lb materialization roles"
    (NeedsMaterialization
      [CoefficientRole, FluxRole, ResultRole, VolumeRole])
    (primitiveSignatureEffect lb)

  gridWhole <- expectJust "grid-whole derivative signature"
    (find ((== VersionedOpId "derivative.grid-whole@1")
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
      "sha256:f6294c222255af0cbc20d76a46e6eecb1858d3c4a370500f9c7c8b510a18010f")
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
  assertLeft "invalid operation version"
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
      , "    (op test.invalid-placement 1)"
      , "    (inputs scalar)"
      , "    (output tensor)"
      , "    (placement derivative-target)"
      , "    (effects pure-local)"
      , "    (commutation ordered))"
      ])))
  assertLeft "unknown schema version"
    (parsePrimitiveManifest
      "(primitive-manifest (schema formurae-feir-primitives 2))")

  putStrLn "FEIR primitive manifest tests: ok"

validPrimitive :: String
validPrimitive = unlines
  [ "  (primitive"
  , "    (op test.valid 1)"
  , "    (inputs scalar)"
  , "    (output scalar)"
  , "    (placement preserve-source)"
  , "    (effects pure-local)"
  , "    (commutation ordered))"
  ]

validEffects :: String
validEffects = "(effects pure-local)"

singlePrimitive :: String -> String -> String
singlePrimitive inputs effects = manifestEnvelope (unlines
  [ "  (primitive"
  , "    (op test.valid 1)"
  , "    " ++ inputs
  , "    (output scalar)"
  , "    (placement preserve-source)"
  , "    " ++ effects
  , "    (commutation ordered))"
  ])

singlePrimitiveWithExtra :: String -> String
singlePrimitiveWithExtra extra = manifestEnvelope (unlines
  [ "  (primitive"
  , "    (op test.valid 1)"
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
  , "    (op test.valid 1)"
  , "    (inputs scalar)"
  , "    (output scalar)"
  , "    " ++ placement
  , "    (effects pure-local)"
  , "    (commutation ordered))"
  ])

manifestEnvelope :: String -> String
manifestEnvelope body =
  "(primitive-manifest\n"
  ++ "  (schema formurae-feir-primitives 1)\n"
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
