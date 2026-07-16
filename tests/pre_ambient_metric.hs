module Main where

import Data.List (isInfixOf)

import Formurae.FEIR.Syntax (PrimitiveManifestId(..))
import Formurae.Pre.EmitEgison
import Formurae.Pre.Parse (parseModel)

main :: IO ()
main = do
  euclidean <- emit "ambient-metric-euclidean.fme" euclideanSource
  scaled <- emit "ambient-metric-scaled.fme" scaledSource
  embedded <- emit "ambient-metric-embedded.fme" embeddedSource
  renamed <- emit "ambient-coordinate-string.fme" renamedCoordinateSource
  publicAliases <- emit "ambient-metric-public.fme" publicAliasSource

  -- Euclidean ambient values are quote-free by construction; variable
  -- geometry (scale/embedding) must strip rule-suppression quotes before
  -- user step expressions read these bindings.
  mapM_ (assertPublicEnvironment "") [euclidean, publicAliases]
  mapM_ (assertPublicEnvironment "FEIR.unquoteAll ") [scaled, embedded]
  mapM_ assertNamedMetric [euclidean, scaled, embedded]
  assertContains "indexed equations can use the reserved covariant metric"
    "metric_i_j . X~j" publicAliases
  assertContains "indexed equations can use the reserved inverse metric"
    "inverseMetric~i~j . A_j" publicAliases
  assertContains "user definitions can use the whole reserved metric"
    "metric_#_#" publicAliases
  assertContains "ambient epsilon follows the model dimension"
    "epsilon~i~j . A_i . A_j" publicAliases

  assertContains "Euclidean geometry publishes a covariant metric"
    "def feGeometryMetric" euclidean
  assertContains "Euclidean geometry publishes a contravariant inverse metric"
    "def feGeometryInverseMetric" euclidean

  assertContains "scale geometry derives the covariant metric"
    "FE.diagonalMetricTensor feDimension feGeometryScaleRaw" scaled
  assertContains "scale geometry derives the inverse metric"
    "FE.inverseDiagonalMetricTensor feDimension feGeometryScaleRaw" scaled

  assertContains "embedding geometry derives the covariant metric"
    "FE.inducedMetric feCoordinates feGeometryEmbedding" embedded
  assertContains "embedding geometry derives the inverse metric"
    "FE.inverseDiagonalMetricTensor feDimension feGeometryScaleRaw" embedded

  assertContains "raw coordinate identifiers are canonicalized"
    "sample := x" renamed
  assertContains "raw coordinate spelling inside strings is preserved"
    "label := \"~theta\"" renamed

  putStrLn "pre-fec ambient metric tests: ok"

emit :: FilePath -> String -> IO String
emit path source = do
  model <- parseModel path "ambient-metric" source
  requireRight =<< emitNormalizationUnit manifestId model

assertPublicEnvironment :: String -> String -> IO ()
assertPublicEnvironment unquote unit = do
  assertContains "dimension is a public ambient value"
    "def dimension : Integer := feDimension" unit
  assertContains "coordinates are a public ambient value"
    "def coordinates : Vector MathValue := feCoordinates" unit
  assertContains "the public metric is covariant"
    ("def metric_i_j := " ++ unquote ++ "feGeometryMetric_i_j") unit
  assertContains "the public inverse metric is contravariant"
    ("def inverseMetric~i~j := " ++ unquote ++ "feGeometryInverseMetric~i~j")
    unit
  assertContains "volume is a public ambient value"
    ("def volume := " ++ unquote ++ "feGeometryVolume") unit
  assertContains "epsilon is derived from the public dimension"
    "def epsilon : Tensor Integer := ε dimension" unit

assertNamedMetric :: String -> IO ()
assertNamedMetric unit = do
  assertContains "metric g publishes the covariant indexed definition"
    "def g_i_j := metric_i_j" unit
  assertContains "metric g publishes the contravariant indexed definition"
    "def g~i~j := inverseMetric~i~j" unit
  assertContains "indexed equations can read the covariant metric components"
    "g_i_j . X~j" unit
  assertContains "indexed equations can read the inverse metric components"
    "g~i~j . A_j" unit
  assertContains "user definitions can read the whole covariant metric"
    "g_#_#" unit
  assertContains "dimension-sized epsilon indices are accepted"
    "epsilon_i_j" unit

manifestId :: PrimitiveManifestId
manifestId = PrimitiveManifestId "sha256:test-manifest"

euclideanSource :: String
euclideanSource = modelSource []

scaledSource :: String
scaledSource = modelSource
  ["metric scale [1 + x, 2]"]

embeddedSource :: String
embeddedSource = modelSource
  ["embedding [x, exp y]"]

renamedCoordinateSource :: String
renamedCoordinateSource = unlines
  [ "mode collocated"
  , "dimension 2"
  , "axes theta, phi"
  , "field u : scalar"
  , "def rich u ="
  , "  let label := \"~theta\""
  , "      sample := theta"
  , "   in u + 0 * sample"
  , "step:"
  , "  u' = rich u"
  ]

publicAliasSource :: String
publicAliasSource = unlines
  [ "mode collocated"
  , "dimension 2"
  , "axes x, y"
  , "field X~i"
  , "field A_i"
  , "def wholeMetric unused = metric_#_#"
  , "def orientation A = withSymbols [i, j] (epsilon~i~j . A_i . A_j)"
  , "init:"
  , "  X~i = [| 0, 0 |]~i"
  , "  A_i = [| 0, 0 |]_i"
  , "step:"
  , "  X'~i = withSymbols [j] (inverseMetric~i~j . A_j)"
  , "  A'_i = withSymbols [j] (metric_i_j . X~j)"
  ]

modelSource :: [String] -> String
modelSource geometry = unlines $
  [ "mode collocated"
  , "dimension 2"
  , "axes x, y"
  ]
  ++ geometry
  ++ [ "metric g"
     , "field X~i"
     , "field A_i"
     , "def wholeCovariant unused = g_#_#"
     , "def orientation unused = epsilon_i_j"
     , "init:"
     , "  X~i = [| 0, 0 |]~i"
     , "  A_i = [| 0, 0 |]_i"
     , "step:"
     , "  X'~i = withSymbols [j] (g~i~j . A_j)"
     , "  A'_i = withSymbols [j] (g_i_j . X~j)"
     ]

requireRight :: Either EmitError value -> IO value
requireRight (Right value) = pure value
requireRight (Left problem) = fail (show problem)

assertContains :: String -> String -> String -> IO ()
assertContains label needle haystack
  | needle `isInfixOf` haystack = pure ()
  | otherwise = fail (label ++ ": missing " ++ show needle)
