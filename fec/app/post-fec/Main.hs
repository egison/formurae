module Main (main) where

import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Formurae.FEIR.Codec (parseFEProgram)
import qualified Formurae.FEIR.PrimitiveBindings as Primitives
import Formurae.FEIR.RegistryFingerprint (computeRegistryId)
import Formurae.FEIR.Validate
import Formurae.Post.Compile (PostError(PostFMRError), compileProgram)
import Formurae.Post.Diagnostic (renderPostError, renderValidationError)
import Formurae.Post.FMR (renderProgram)

main :: IO ()
main = do
  arguments <- getArgs
  source <-
    case arguments of
      ["-"] -> getContents
      [path] -> readFile path
      _ -> failWith "usage: post-fec MODEL.feir (or - for stdin)"
  program <- either (failWith . show) pure (parseFEProgram source)
  let validationConfig = ValidationConfig
        { validationExpectedRegistryId = Just (computeRegistryId program)
        , validationExpectedPrimitiveManifestId =
            Just Primitives.primitiveManifestV1Id
        , validationPrimitiveSignatures =
            Primitives.primitiveSignaturesV1
        }
  either (failWith . unlines . map (renderValidationError program)) pure
    (validateFEProgram validationConfig program)
  lowered <- either (failWith . renderPostError program) pure
    (compileProgram program)
  output <- either
    (failWith . renderPostError program . PostFMRError) pure
    (renderProgram lowered)
  putStr output

failWith :: String -> IO a
failWith message = do
  hPutStrLn stderr ("post-fec: error: " ++ message)
  exitFailure
