module Main where

import Control.Monad (unless)
import Data.List (isInfixOf)
import System.Directory (createDirectoryIfMissing)
import System.Process (callProcess)
import Formurae.Native
import Formurae.Post.FMR

main :: IO ()
main = do
  source <- either fail pure (parseNativeSource input)
  selected <- case stageSources source of (_,body):_->pure body; []->fail "missing stage"
  unless (lines selected !! 5 == "step:" && lines selected !! 6 == "  u' = u+1")
    (fail "stage extraction changed the source line numbers")
  case parseNativeSource (input ++ "\nstage forward:\n  u' = u\n") of
    Left _ -> pure ()
    Right _ -> fail "duplicate stage accepted"
  case renderNative source [("forward",program{fProgramAxes=["x"]})] of
    Left _ -> pure ()
    Right _ -> fail "unsupported dimensionality accepted"
  case renderNative source [("forward",program{fProgramParameters=[("p","system(1)")]})] of
    Left _ -> pure ()
    Right _ -> fail "raw expression escaped the arithmetic grammar"
  c <- either fail pure (renderNative source [("forward",program)])
  unless ("pow(2.0,3.0)" `isInfixOf` c) (fail "raw power not translated")
  precedence <- either fail pure (renderNative source [("forward",program{fProgramParameters=[("p","-2^2")]})])
  unless ("(-pow(2.0,2.0))" `isInfixOf` precedence) (fail "unary minus has wrong precedence")
  createDirectoryIfMissing True ".build/native-tests"
  writeFile ".build/native-tests/model.c" c
  writeFile ".build/native-tests/check.c" $ unlines
    [ "#define FORMURAE_NATIVE_NO_MAIN"
    , "#include \"model.c\""
    , "int main(void){NState *s=n_create(&n_model,9,8);model_advance(s);"
    , "for(int i=2;i<9;i++)for(int j=0;j<8;j++){size_t p=i*8+j;"
    , "assert(s->field[N_u][p]==i+2*j+2);assert(s->field[N_v][p]==2*(i+2*j)+4);}"
    , "n_destroy(s);return 0;}" ]
  callProcess "cc" ["-std=c11","-O1","-fsanitize=undefined","-Iruntime",
    ".build/native-tests/check.c","-lm","-o",".build/native-tests/check"]
  callProcess ".build/native-tests/check" []
  putStrLn "native parser and generated sequential C execution: ok"

input :: String
input = unlines
  [ "dimension 2", "axes x, y", "field u", "field v", ""
  , "stage forward:", "  u' = u+1"
  , "runtime:", "  grid 9 8", "  extent 1 1", "  halo 1"
  , "  time u", "  timestep v", "  steps 2", "  every 1"
  , "  output u v", "  monitor value max u 1"
  , "advance:", "  call forward", "  call forward" ]

program :: FProgram
program = FProgram 2 ["x","y"] [("p","2^3")] [] ["u","v"]
  [FAssignment (InitialTarget "u" ["i","j"]) (FRawExpr "i+2*j"),
   FAssignment (InitialTarget "v" ["i","j"]) (FExact 0 1)]
  [FAssignment (StepUpdateTarget "u") (FAdd [ref "u" 0,FExact 1 1]),
   FAssignment (StepBindingTarget "nextNeighbor") (ref "u'" 1),
   FAssignment (StepUpdateTarget "v") (FAdd [ref "nextNeighbor" 0,ref "u" 0])]
  where ref n offset=FGridReference n [GridIndex "i" offset,GridIndex "j" 0]
