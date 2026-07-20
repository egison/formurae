module Main (main) where

import Control.Monad (filterM, unless)
import Data.List (isPrefixOf, isSuffixOf)
import Data.Version (showVersion)
import System.Directory
  ( doesFileExist
  , findExecutable
  , makeAbsolute
  )
import System.Environment (getArgs, getExecutablePath, lookupEnv)
import System.Exit (ExitCode(..), exitFailure)
import System.FilePath
  ( replaceExtension
  , takeDirectory
  , takeExtension
  , takeFileName
  , (</>)
  )
import System.IO (hPutStr, hPutStrLn, stderr)
import System.Process (CreateProcess(cwd), proc, readCreateProcessWithExitCode)

import Paths_formurae (getDataFileName, version)

data Command = Lower | Compile

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["--version"] -> putStrLn (showVersion version)
    [model] -> runPipeline Compile model
    ["compile", model] -> runPipeline Compile model
    ["lower", model] -> runPipeline Lower model
    _ -> failWith usage

usage :: String
usage = unlines
  [ "usage: formurae [compile] MODEL.fme"
  , "       formurae lower MODEL.fme"
  , "       formurae --version"
  , ""
  , "compile lowers through FEIR and invokes Formura to generate C code."
  , "lower stops after writing MODEL.fmr."
  ]

runPipeline :: Command -> FilePath -> IO ()
runPipeline command inputPath = do
  sourcePath <- makeAbsolute inputPath
  exists <- doesFileExist sourcePath
  unless exists (failWith ("input file does not exist: " ++ inputPath))
  unless (takeExtension sourcePath == ".fme")
    (failWith ("expected a .fme input file: " ++ inputPath))

  pre <- requireTool "FORMURAE_PRE" "formurae-pre"
    "install all Formurae executables with: cabal install all:exes"
  post <- requireTool "FORMURAE_POST" "formurae-post"
    "install all Formurae executables with: cabal install all:exes"
  egison <- requireTool "EGISON" "egison"
    "install Egison with: cabal install egison-5.1.0"

  let egisonPath = replaceExtension sourcePath "egi"
      feirPath = replaceExtension sourcePath "feir"
      fmrPath = replaceExtension sourcePath "fmr"

  normalizationUnit <- runChecked "formurae-pre" pre [sourcePath] Nothing ""
  writeFile egisonPath normalizationUnit

  libraries <- normalizationLibraries
  normalized <- runEgison egison libraries egisonPath
  writeFile feirPath normalized

  lowered <- runChecked "formurae-post" post [feirPath] Nothing ""
  writeFile fmrPath lowered

  case command of
    Lower -> putStrLn ("wrote " ++ fmrPath)
    Compile -> do
      formura <- requireTool "FORMURA" "formura"
        "install the validated Formura checkout with: cabal install exe:formura"
      let modelDirectory = takeDirectory fmrPath
      _ <- runChecked "formura" formura [takeFileName fmrPath]
        (Just modelDirectory) ""
      putStrLn ("wrote " ++ fmrPath ++ " and generated Formura C code")

normalizationLibraries :: IO [FilePath]
normalizationLibraries = do
  manifestPath <- getDataFileName "spec/egison-normalization.list"
  manifest <- lines <$> readFile manifestPath
  entries <- case manifest of
    "formurae-egison-normalization" : paths
      | length paths == 5 -> pure paths
    _ -> failWith
      ("installed normalization manifest is invalid: " ++ manifestPath)
  paths <- mapM getDataFileName entries
  missing <- filterM (fmap not . doesFileExist) paths
  unless (null missing) $ failWith
    ("installed normalization libraries are missing: " ++ unwords missing)
  pure paths

runEgison :: FilePath -> [FilePath] -> FilePath -> IO String
runEgison executable libraries unit = do
  let arguments =
        ["--type-check-strict"]
        ++ concatMap (\library -> ["-l", library]) libraries
        ++ ["-l", unit, "-c", "main []"]
  (status, stdoutText, stderrText) <-
    readCreateProcessWithExitCode (proc executable arguments) ""
  let machineOutput = stripOriginMarkers stdoutText
  case status of
    ExitFailure _ -> do
      hPutStr stderr stderrText
      hPutStr stderr machineOutput
      exitFailure
    ExitSuccess
      | containsDiagnostic (stdoutText ++ stderrText) -> do
          hPutStr stderr stderrText
          hPutStr stderr machineOutput
          exitFailure
      | otherwise -> do
          hPutStr stderr stderrText
          pure machineOutput

containsDiagnostic :: String -> Bool
containsDiagnostic output = any isDiagnosticLine (lines output)
  where
    isDiagnosticLine line = any (`isPrefixOf` line)
      [ "Type error:"
      , "Warning:"
      , "Parse error:"
      , "Parser error:"
      , "Evaluation error:"
      , "Desugar error:"
      , "Egison error:"
      , "Error:"
      , "Assertion failed:"
      ]

stripOriginMarkers :: String -> String
stripOriginMarkers = unlines . filter (not . isOriginMarker) . lines
  where
    isOriginMarker line =
      "@@FORMURAE_ACTIVE_ORIGIN:" `isPrefixOf` line && "@@" `isSuffixOf` line

runChecked
  :: String -> FilePath -> [String] -> Maybe FilePath -> String -> IO String
runChecked label executable arguments workingDirectory stdinText = do
  let process = (proc executable arguments) { cwd = workingDirectory }
  (status, stdoutText, stderrText) <-
    readCreateProcessWithExitCode process stdinText
  hPutStr stderr stderrText
  case status of
    ExitSuccess -> pure stdoutText
    ExitFailure code -> do
      hPutStr stderr stdoutText
      failWith (label ++ " exited with status " ++ show code)

requireTool :: String -> String -> String -> IO FilePath
requireTool environmentVariable executableName hint = do
  override <- lookupEnv environmentVariable
  case override of
    Just path -> requireExisting path
    Nothing -> do
      ownExecutable <- getExecutablePath
      let sibling = takeDirectory ownExecutable </> executableName
      siblingExists <- doesFileExist sibling
      if siblingExists
        then pure sibling
        else do
          found <- findExecutable executableName
          maybe (failWith (executableName ++ " was not found; " ++ hint)) pure found
  where
    requireExisting path = do
      exists <- doesFileExist path
      if exists
        then pure path
        else failWith
          (environmentVariable ++ " points to a missing executable: " ++ path)

failWith :: String -> IO a
failWith message = do
  hPutStrLn stderr ("formurae: error: " ++ message)
  exitFailure
