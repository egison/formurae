module Main (main) where

import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Formurae.FEIR.PrimitiveBindingGenerator

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    [] -> writeBindings "."
    ["--write"] -> writeBindings "."
    ["--write", "--root", root] -> writeBindings root
    ["--check"] -> checkBindings "."
    ["--check", "--root", root] -> checkBindings root
    _ -> failWith
      "usage: generate-feir-primitives.hs [--write|--check] [--root DIR]"

writeBindings :: FilePath -> IO ()
writeBindings root = do
  result <- writeGeneratedPrimitiveBindings
    (defaultGeneratedPrimitivePaths root)
  either failWith pure result

checkBindings :: FilePath -> IO ()
checkBindings root = do
  result <- checkGeneratedPrimitiveBindings
    (defaultGeneratedPrimitivePaths root)
  case result of
    Right () -> pure ()
    Left differences -> failWith (unlines
      ( "generated FEIR primitive bindings are stale:"
      : map ("  " ++) differences
      ++ ["run tools/generate-feir-primitives.hs without --check"] ))

failWith :: String -> IO a
failWith message = do
  hPutStrLn stderr message
  exitFailure
