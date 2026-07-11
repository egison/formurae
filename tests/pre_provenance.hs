module Main where

import Data.List (isInfixOf)

import Formurae.FEIR.Syntax
import Formurae.Post.Diagnostic (Diagnostic(..), renderDiagnostic)
import Formurae.Pre.EmitEgison (emitNormalizationUnit)
import Formurae.Pre.Parse (parseModel)
import Formurae.Pre.Registry

main :: IO ()
main = do
  model <- parseModel "trace.fme" "trace" source
  registry <- requireRight "registry" (buildRegistry model)
  rebuilt <- requireRight "rebuilt registry" (buildRegistry model)
  assertEqual "trace assignment is deterministic" registry rebuilt

  let [initializerId] = preRegistryInitializerOrigins registry
      [directId, nestedId] = preRegistryStepOrigins registry
      initializerOrigin = originFor registry initializerId
      directOrigin = originFor registry directId
      nestedOrigin = originFor registry nestedId

  assertLocation "multiline analytic initializer location"
    (8, 9, 8, 6) (sourceOriginLocation initializerOrigin)
  assertTrace "analytic initializer trace"
    [ ("outer", (6, 6, 15, 17), (8, 8, 8, 12))
    , ("phi", (5, 5, 11, 15), (6, 6, 15, 15))
    ] (sourceOriginTrace initializerOrigin)

  assertLocation "direct call expression location"
    (11, 11, 16, 18) (sourceOriginLocation directOrigin)
  assertTrace "direct unicode call maps to the original source column"
    [("phi", (5, 5, 11, 15), (11, 11, 16, 16))]
    (sourceOriginTrace directOrigin)

  assertLocation "nested call expression location"
    (12, 12, 8, 14) (sourceOriginLocation nestedOrigin)
  assertTrace "nested definition expansion is outer-to-inner"
    [ ("outer", (6, 6, 15, 17), (12, 12, 8, 12))
    , ("phi", (5, 5, 11, 15), (6, 6, 15, 15))
    ] (sourceOriginTrace nestedOrigin)

  let rendered = renderDiagnostic Diagnostic
        { diagnosticFallbackPath = "ignored.feir"
        , diagnosticOrigin = Just nestedOrigin
        , diagnosticMessage = "lowering failed"
        }
  assertEqual "post diagnostic renders the original expansion stack"
    (unlinesWithoutFinal
      [ "trace.fme:12:8: lowering failed"
      , "  expanded from outer at trace.fme:12:8 (defined at trace.fme:6:15)"
      , "  expanded from phi at trace.fme:6:15 (defined at trace.fme:5:11)"
      ]) rendered

  unit <- requireEmit =<< emitNormalizationUnit
    (PrimitiveManifestId "sha256:test-manifest") model
  assertContains "generated FEIR wire carries expansion frames"
    "FEIR.atom \"expansion-frame\"" unit
  assertContains "generated FEIR wire carries the nested definition name"
    "FEIR.string \"outer\"" unit
  putStrLn "pre-fec provenance tests: ok"

source :: String
source = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "def \966 q = lap q"
  , "def outer q = \966 q"
  , "init:"
  , "  u := outer("
  , "    u)"
  , "step:"
  , "  let direct = \966 u"
  , "  u' = outer u"
  ]

originFor :: PreRegistry -> OriginId -> SourceOrigin
originFor registry originId =
  case lookup originId entries of
    Just origin -> origin
    Nothing -> error ("missing origin " ++ show originId)
  where
    OriginTable entries = preRegistryOrigins registry

assertTrace
  :: String
  -> [(String, (Int, Int, Int, Int), (Int, Int, Int, Int))]
  -> [ExpansionFrame]
  -> IO ()
assertTrace label expected actual =
  assertEqual label expected
    [ ( expansionFrameName frame
      , locationTuple (expansionFrameDefinition frame)
      , locationTuple (expansionFrameCall frame)
      )
    | frame <- actual
    ]

assertLocation
  :: String -> (Int, Int, Int, Int) -> SourceLocation -> IO ()
assertLocation label expected =
  assertEqual label expected . locationTuple

locationTuple :: SourceLocation -> (Int, Int, Int, Int)
locationTuple location =
  ( sourceLocationLine location
  , sourceLocationEndLine location
  , sourceLocationStartColumn location
  , sourceLocationEndColumn location
  )

unlinesWithoutFinal :: [String] -> String
unlinesWithoutFinal [] = ""
unlinesWithoutFinal (line : rest) = foldl (\result next -> result ++ "\n" ++ next)
  line rest

requireRight :: String -> Either RegistryError a -> IO a
requireRight _ (Right value) = pure value
requireRight label (Left problem) = fail (label ++ ": " ++ show problem)

requireEmit :: Either a String -> IO String
requireEmit (Right value) = pure value
requireEmit (Left _) = fail "normalization emission failed"

assertContains :: String -> String -> String -> IO ()
assertContains label needle haystack
  | needle `isInfixOf` haystack = pure ()
  | otherwise = fail (label ++ ": missing " ++ show needle)

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
