module Main (main) where
import Control.Monad (forM, forM_)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath ((</>))
import Formurae.Native
import Formurae.FEIR.Codec (parseFEProgram)
import qualified Formurae.FEIR.PrimitiveBindings as P
import Formurae.FEIR.RegistryFingerprint (computeRegistryId)
import Formurae.FEIR.Validate
import Formurae.Post.Compile (compileProgram)
import Formurae.Post.FMR (renderProgram)

main :: IO ()
main = do
 args<-getArgs
 case args of
  [mode,path,folder] | mode `elem` ["prepare","emit"] -> do
   raw<-readFile path
   source<-either die pure (parseNativeSource raw)
   createDirectoryIfMissing True folder
   if mode=="prepare" then forM_ (stageSources source) $ \(name,body)->do
      writeFile (folder </> name++".fme") body
      putStrLn name
    else do
      programs<-forM (stageSources source) $ \(name,_)->do
        text<-readFile (folder </> name++".feir")
        fe<-either (die.show) pure (parseFEProgram text)
        let config=ValidationConfig (Just(computeRegistryId fe)) (Just P.primitiveManifestId) P.primitiveSignatures
        either (die.show) pure (validateFEProgram config fe)
        program<-either (die.show) pure (compileProgram fe)
        fmr<-either (die.show) pure (renderProgram program)
        writeFile (folder </> name++".fmr") fmr
        pure (name,program)
      c<-either die pure (renderNative source programs)
      writeFile (folder </> "model.c") c
  _->die "usage: formurae-native (prepare|emit) MODEL.fme OUTPUT_DIRECTORY"
