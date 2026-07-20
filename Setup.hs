module Main (main) where

import Distribution.Simple
import System.Exit (ExitCode(..), exitWith)
import System.Process (rawSystem)

main :: IO ()
main = defaultMainWithHooks hooks

hooks :: UserHooks
hooks = simpleUserHooks
  { preBuild = \arguments flags -> do
      -- Generated bindings are checked, not repaired, so a build never hides
      -- an unreviewed manifest change in the working tree.
      status <- rawSystem "runghc"
        [ "-isrc"
        , "tools/generate-feir-primitives.hs"
        , "--check"
        ]
      case status of
        ExitSuccess -> preBuild simpleUserHooks arguments flags
        failure -> exitWith failure
  }
