module Main where

import Formurae.FEIR.Codec (parseFEProgram)
import Formurae.FEIR.Syntax

main :: IO ()
main = do
  encoded <- getContents
  program <- either (fail . show) pure (parseFEProgram encoded)
  initializerOriginId <- case feProgramInitializers program of
    [AnalyticInitializer equation] -> pure (feEquationOrigin equation)
    values -> fail ("unexpected initializers: " ++ show values)
  (nodeId, actionOriginId) <- case feProgramStepActions program of
    BindValue node _ origin : _ -> pure (node, origin)
    values -> fail ("missing traced BindValue: " ++ show values)

  let initializerOrigin = findOrigin program initializerOriginId
      actionOrigin = findOrigin program actionOriginId
  assertTrace "initializer FEIR sidecar"
    [ ("outer", (7, 15), (9, 8))
    , ("inner", (6, 15), (7, 15))
    ] initializerOrigin
  assertTrace "action FEIR sidecar"
    [ ("outer", (7, 15), (11, 14))
    , ("inner", (6, 15), (7, 15))
    ] actionOrigin
  assertEqual "BindValue provenance points to its traced origin"
    [actionOriginId] (findProvenance program nodeId)
  putStrLn "pre-fec FEIR provenance sidecar tests: ok"

findOrigin :: FEProgram -> OriginId -> SourceOrigin
findOrigin program identifier =
  case lookup identifier entries of
    Just origin -> origin
    Nothing -> error ("missing origin " ++ show identifier)
  where
    OriginTable entries = feProgramOrigins program

findProvenance :: FEProgram -> NodeId -> [OriginId]
findProvenance program identifier =
  case lookup identifier entries of
    Just origins -> origins
    Nothing -> error ("missing provenance " ++ show identifier)
  where
    ProvenanceTable entries = feProgramProvenance program

assertTrace
  :: String
  -> [(String, (Int, Int), (Int, Int))]
  -> SourceOrigin
  -> IO ()
assertTrace label expected origin = assertEqual label expected
  [ ( expansionFrameName frame
    , locationStart (expansionFrameDefinition frame)
    , locationStart (expansionFrameCall frame)
    )
  | frame <- sourceOriginTrace origin
  ]

locationStart :: SourceLocation -> (Int, Int)
locationStart location =
  (sourceLocationLine location, sourceLocationStartColumn location)

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
