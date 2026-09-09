module Main (main) where

import Control.Monad (filterM, unless)
import Data.List (isPrefixOf, isSuffixOf)
import Data.Version (showVersion)
import System.Directory
  ( doesFileExist
  , copyFile
  , createDirectoryIfMissing
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
import System.Process (CreateProcess(cwd), callProcess, proc, readCreateProcessWithExitCode)

import Paths_formurae (getDataFileName, version)

data Command = Lower | Compile | Run [String]

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["--version"] -> putStrLn (showVersion version)
    [model] -> runPipeline Compile model
    ["compile", model] -> runPipeline Compile model
    ["lower", model] -> runPipeline Lower model
    "run" : model : options -> runPipeline (Run options) model
    _ -> failWith usage

usage :: String
usage = unlines
  [ "usage: formurae [compile] MODEL.fme"
  , "       formurae lower MODEL.fme"
  , "       formurae run MODEL.fme [--grid NX NY] [--steps N] [--every N] [--dt DT] [--output DIRECTORY]"
  , "       formurae --version"
  , ""
  , "compile generates C; staged models also produce a standalone executable."
  , "run compiles and executes a model with stage and runtime declarations."
  , "lower writes the discretized Formura representation (one file per stage)."
  ]

runPipeline :: Command -> FilePath -> IO ()
runPipeline command inputPath = do
  sourcePath <- makeAbsolute inputPath
  exists <- doesFileExist sourcePath
  unless exists (failWith ("input file does not exist: " ++ inputPath))
  unless (takeExtension sourcePath == ".fme")
    (failWith ("expected a .fme input file: " ++ inputPath))
  source <- readFile sourcePath
  if any ("stage " `isPrefixOf`) (lines source)
    then runNativePipeline command sourcePath
    else runOrdinaryPipeline command sourcePath

runOrdinaryPipeline :: Command -> FilePath -> IO ()
runOrdinaryPipeline (Run _) _ = failWith "run requires a model with stage and runtime declarations"
runOrdinaryPipeline command sourcePath = do

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

-- A staged model uses exactly the same installed preprocessor, normalization
-- libraries and checked finite-difference lowering as an ordinary model.
-- The user supplies one .fme file; all C and runtime plumbing is generated.
runNativePipeline :: Command -> FilePath -> IO ()
runNativePipeline command sourcePath = do
  let hint = "install all Formurae executables with: cabal install all:exes"
      folder = replaceExtension sourcePath "native"
  pre <- requireTool "FORMURAE_PRE" "formurae-pre" hint
  native <- requireTool "FORMURAE_NATIVE" "formurae-native" hint
  egison <- requireTool "EGISON" "egison" "install Egison with: cabal install egison-5.1.0"
  libraries <- normalizationLibraries
  createDirectoryIfMissing True folder
  stages <- lines <$> runChecked "formurae-native" native ["prepare",sourcePath,folder] Nothing ""
  mapM_ (\name -> do
    let stage = folder </> name
    hPutStrLn stderr ("normalizing stage " ++ name)
    unit <- runChecked "formurae-pre" pre [stage ++ ".fme"] Nothing ""
    writeFile (stage ++ ".egi") unit
    normalized <- runEgison egison libraries (stage ++ ".egi")
    writeFile (stage ++ ".feir") normalized) stages
  _ <- runChecked "formurae-native" native ["emit",sourcePath,folder] Nothing ""
  runtime <- getDataFileName "runtime/formurae_native.h"
  copyFile runtime (folder </> "formurae_native.h")
  case command of
    Lower -> putStrLn ("wrote checked stages in " ++ folder)
    _ -> do
      compiler <- maybe "cc" id <$> lookupEnv "CC"
      let executable = folder </> "simulate"
      _ <- runChecked "C compiler" compiler ["-O2","-std=c11",folder </> "model.c","-lm","-o",executable] Nothing ""
      case command of
        Run options -> callProcess executable (["--output",folder </> "output"] ++ options)
        _ -> putStrLn ("wrote " ++ executable)

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
