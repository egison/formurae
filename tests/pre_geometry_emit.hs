module Main where

import Data.List (isInfixOf)

import Formurae.FEIR.Syntax
import Formurae.Pre.EmitEgison
import Formurae.Pre.Parse (parseModel)
import Formurae.Pre.Registry

main :: IO ()
main = do
  scaleModel <- parseModel "scale.fme" "scale" scaleSource
  embeddedModel <- parseModel "embedded.fme" "embedded" embeddedSource
  scaleRegistry <- requireRegistry (buildRegistry scaleModel)
  embeddedRegistry <- requireRegistry (buildRegistry embeddedModel)
  scaleUnit <- requireEmit =<< emitNormalizationUnit manifestId scaleModel
  embeddedUnit <- requireEmit =<< emitNormalizationUnit manifestId embeddedModel

  assert "metric scale has the FEIR orthogonal kind" $
    case geometryDeclKind (preRegistryGeometry scaleRegistry) of
      OrthogonalScaleGeometry _ _ -> True
      _ -> False
  assert "embedding has the FEIR embedded kind" $
    case geometryDeclKind (preRegistryGeometry embeddedRegistry) of
      EmbeddedOrthogonalGeometry _ _ -> True
      _ -> False
  assertContains "scale metric is derived in Egison"
    "FE.diagonalMetricTensor feDimension feGeometryScaleRaw" scaleUnit
  assertContains "embedding metric is derived in Egison"
    "FE.inducedMetric feCoordinates feGeometryEmbedding" embeddedUnit
  assertContains "orthogonality gates serialization"
    "embedding/metric must be symbolically orthogonal" embeddedUnit
  assertContains "quotes are removed only at FEIR tensor boundary"
    "FEIR.unquoteTensor FormuraeInternalValue" embeddedUnit
  assertContains "quotes are removed only at FEIR scalar boundary"
    "FEIR.unquoteAll FormuraeInternalValue" embeddedUnit
  -- Canonical Delta on declared geometry expands through the prelude
  -- macros: the flux weights and adjoint divergence take the unquoted
  -- geometry values as arguments.
  assertContains "variable scalar Delta materializes the flux weights"
    "def FormuraeInternalDFluxWeights A := Formurae.dFluxWeightsWith (FEIR.unquoteAll feGeometryVolume) (FEIR.unquoteTensor feGeometryInverseMetric) A"
    embeddedUnit
  assertContains "variable scalar Delta closes with the adjoint divergence"
    "def FormuraeInternalDFluxDiv w := Formurae.dFluxDivWith (FEIR.unquoteAll feGeometryVolume) (FEIR.unquoteTensor feGeometryMetric) w"
    embeddedUnit
  assertAbsent "ambient operators do not construct a context"
    "Formurae.operatorContext" embeddedUnit
  assertAbsent "no eager whole-expression expansion" "expandAll" embeddedUnit
  putStrLn "pre-fec geometry emitter tests: ok"

manifestId :: PrimitiveManifestId
manifestId = PrimitiveManifestId
  "sha256:f4623af0a5cebbf8ce86d8871b52335ae8ae7db95eaa0f25224d9bad35512c3b"

scaleSource :: String
scaleSource = unlines
  [ "mode collocated"
  , "dimension 3"
  , "axes x, y, z"
  , "metric scale [1 / (1 + y), 1 / (1 + y), 1]"
  , "field u : scalar @ primal"
  , "init:"
  , "  u := exp (cos x - 1)"
  , "step:"
  , "  u' = u + Δ u"
  ]

embeddedSource :: String
embeddedSource = unlines
  [ "mode collocated"
  , "dimension 3"
  , "axes theta, phi, z"
  , "embedding [`(2 + cos theta) * cos phi, `(2 + cos theta) * sin phi, sin theta, z]"
  , "field u : scalar @ primal"
  , "init:"
  , "  u := exp (cos theta + cos phi - 2)"
  , "step:"
  , "  u' = u + Δ u"
  ]

requireRegistry :: Either RegistryError a -> IO a
requireRegistry (Right value) = pure value
requireRegistry (Left err) = fail (show err)

requireEmit :: Either EmitError a -> IO a
requireEmit (Right value) = pure value
requireEmit (Left err) = fail (show err)

assert :: String -> Bool -> IO ()
assert _ True = pure ()
assert label False = fail label

assertContains :: String -> String -> String -> IO ()
assertContains label needle haystack =
  assert (label ++ ": missing " ++ show needle) (needle `isInfixOf` haystack)

assertAbsent :: String -> String -> String -> IO ()
assertAbsent label needle haystack =
  assert (label ++ ": found " ++ show needle) (not (needle `isInfixOf` haystack))
