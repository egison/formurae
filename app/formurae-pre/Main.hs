module Main (main) where

import Data.List (find, intercalate, stripPrefix)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath (takeBaseName)
import System.IO (hPutStrLn, stderr)

import qualified Formurae.FEIR.PrimitiveBindings as Primitives
import Formurae.FEIR.PrimitiveManifest
import Formurae.FEIR.Syntax (OpId(..))
import Formurae.Pre.Effect
import Formurae.Pre.EmitEgison
import Formurae.Pre.Parse (parseModel)
import Formurae.Pre.TypeCheck
import qualified Formurae.Syntax as Surface
import Paths_formurae (getDataFileName)
import Text.Read (readMaybe)

main :: IO ()
main = do
  arguments <- getArgs
  path <- case arguments of
    [sourcePath] -> pure sourcePath
    _ -> failWith "usage: formurae-pre MODEL.fme"
  source <- readFile path
  model <- parseModel path (takeBaseName path) source
  manifestPath <- getDataFileName "spec/feir-primitives.sexp"
  manifestResult <- loadPrimitiveManifest manifestPath
  manifest <- either (failWith . show) pure manifestResult
  if primitiveManifestId manifest == Primitives.primitiveManifestId
    then pure ()
    else failWith "installed primitive manifest does not match generated bindings"
  _ <- either (failWith . renderEffectError model) pure
    (inferModelEffects manifest model)
  _ <- either (failWith . renderOperatorTypeError) pure
    (validateModelOperatorTypes model)
  emitted <- emitNormalizationUnit Primitives.primitiveManifestId model
  output <- either (failWith . renderEmitError) pure emitted
  putStr output

renderEffectError :: Surface.Model -> EffectError -> String
renderEffectError model problem =
  maybe contextPrefix ((++ ": ") . renderSourceStart) source
  ++ renderEffectIssue (effectErrorIssue problem)
  where
    source = effectContextSource model (effectErrorContext problem)
    contextPrefix = effectErrorContext problem ++ ": "

renderOperatorTypeError :: OperatorTypeError -> String
renderOperatorTypeError problem =
  maybe "" ((++ ": ") . renderSourceStart)
    (operatorTypeErrorSource problem)
  ++ operatorTypeErrorMessage problem

effectContextSource :: Surface.Model -> String -> Maybe Surface.SourceText
effectContextSource model context
  | Just name <- stripPrefix "definition " context =
      Surface.defSourceText =<< find ((== name) . Surface.defName)
        (Surface.mDefs model)
  | Just indexText <- stripPrefix "initializer " context
  , Just index <- readMaybe indexText =
      atOneBased index (Surface.mInitSourceTexts model)
  | Just rest <- stripPrefix "step action " context
  , Just index <- readMaybe (takeWhile (/= ' ') rest) =
      Surface.sSourceText <$> atOneBased index (Surface.mSteps model)
  | otherwise = Nothing

atOneBased :: Int -> [value] -> Maybe value
atOneBased index values
  | index > 0 = case drop (index - 1) values of
      value : _ -> Just value
      [] -> Nothing
  | otherwise = Nothing

renderEffectIssue :: EffectIssue -> String
renderEffectIssue issue =
  case issue of
    InvalidEffectExpression message ->
      "invalid effect expression: " ++ message
    ForwardDefinitionUse name ->
      "forward reference to user definition " ++ name
    MissingPrimitiveSignature name ->
      "primitive manifest has no signature for " ++ name
    AnalyticDerivativeOfDiscrete operations ->
      "analytic derivative contains discrete operation"
      ++ plural operations ++ ": " ++ renderOperations operations
    GridDerivativeOfDiscrete operations ->
      "grid derivative contains nested discrete operation"
      ++ plural operations ++ ": " ++ renderOperations operations
    EffectfulHigherOrderArgument consumer operations ->
      consumer ++ " receives discrete operation"
      ++ plural operations ++ " as a higher-order argument: "
      ++ renderOperations operations
    CanonicalOperatorModeMismatch message -> message
    VariableMetricHodgeLaplacianUnsupported ->
      "canonical Δ_H is not supported for variable metric geometry; "
      ++ "write its metric-dependent discretization explicitly"
    VariableMetricHodgeCompositionUnsupported ->
      "hodge (d (hodge A)) cannot be analytically expanded on variable "
      ++ "metric geometry; write canonical δ A so the compiler preserves "
      ++ "the weighted discrete adjoint"
  where
    plural [_] = ""
    plural _ = "s"

renderOperations :: [OpId] -> String
renderOperations = intercalate ", " . map operationText
  where
    operationText (OpId value) = value

renderEmitError :: EmitError -> String
renderEmitError problem =
  case problem of
    EmitAtSource source nested ->
      renderSourceStart source ++ ": " ++ renderEmitMessage nested
    _ -> renderEmitMessage problem

renderEmitMessage :: EmitError -> String
renderEmitMessage problem =
  case problem of
    EmitAtSource _ nested -> renderEmitMessage nested
    EmitRegistryError registryError ->
      "normalization registry error: " ++ show registryError
    EmitMissingField name -> "unknown logical field " ++ name
    EmitMissingInitializerOrigin index ->
      "missing initializer origin " ++ show index
    EmitMissingStepOrigin index -> "missing step origin " ++ show index
    EmitExpressionError message -> message
    EmitUnsupportedInitializer name ->
      "unsupported initializer for field " ++ name

renderSourceStart :: Surface.SourceText -> String
renderSourceStart source =
  Surface.sourcePath source ++ ":" ++ show line ++ ":" ++ show column
  where
    (line, column) = case Surface.sourcePositionMap source of
      position : _ ->
        (Surface.positionLine position, Surface.positionColumn position)
      [] -> (Surface.sourceLine source, Surface.sourceColumn source)

failWith :: String -> IO a
failWith message = do
  hPutStrLn stderr ("formurae-pre: error: " ++ message)
  exitFailure
