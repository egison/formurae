module Main where

import Data.List (isInfixOf)

import Formurae.FEIR.PrimitiveManifest
import qualified Formurae.FEIR.Syntax as FEIR
import Formurae.Pre.Effect
import Formurae.Pre.Registry
import Formurae.Syntax

main :: IO ()
main = do
  manifestSource <- readFile "spec/feir-primitives-v1.sexp"
  manifest <- either (fail . show) pure
    (parsePrimitiveManifest manifestSource)

  summary <- requireRight "pure raw effect" $
    inferModelEffects manifest (baseModel
      [ definition 5 "prior" ["x"] "lap x"
      , definition 6 "raw" ["x"] "let y := prior x in y"
      ])
  assertEqual "raw Egison admits prior pure definitions"
    [("prior", PureFunction), ("raw", PureFunction)]
    (effectSummaryDefinitions summary)

  assertLeft "raw Egison rejects direct canonical resample requests" isRawDiscrete $
    inferModelEffects manifest (baseModel
      [definition 5 "raw" ["x"] "let y := resample(x, 1) in y"])

  assertLeft "raw Egison rejects qualified normalization namespace calls" isReservedConstructor $
    inferModelEffects manifest (baseModel
      [definition 5 "raw" ["x"]
        "let y := Formurae.resampleExplicit [| 1 |] x in y"])

  assertLeft "raw Egison rejects the opaque barrier" isReservedConstructor $
    inferModelEffects manifest (baseModel
      [definition 5 "raw" ["x"]
        "let y := formuraeOpaqueBarrier x in y"])

  assertLeft "raw Egison rejects FunctionData construction" isReservedConstructor $
    inferModelEffects manifest (baseModel
      [definition 5 "raw" ["x"]
        "let request := functionSymbol \"FormuraeInternalOpaqueGridWholeV1\" [x, 1] in request"])

  assertLeft "raw Egison rejects generated-internal identifiers" isReservedConstructor $
    inferModelEffects manifest (baseModel
      [definition 5 "raw" ["x"]
        "let y := FormuraeInternalGridWholeDerivative 1 x in y"])

  assertLeft "structured definitions cannot call an internal bridge" isReservedConstructor $
    inferModelEffects manifest (baseModel
      [definition 5 "raw" ["x"]
        "FormuraeInternalGridWholeDerivative 1 x"])

  nearMissSummary <- requireRight "reserved names inside a string are data" $
    inferModelEffects manifest (baseModel
      [definition 5 "raw" ["x"]
        "let diagnostic := \"formuraeOpaqueBarrier functionSymbol FormuraeInternalOpaqueGridWholeV1\" in x"])
  assertEqual "diagnostic strings do not trip the reserved constructor gate"
    [("raw", PureFunction)] (effectSummaryDefinitions nearMissSummary)

  assertLeft "raw Egison rejects transitive discrete operations" isRawDiscrete $
    inferModelEffects manifest (baseModel
      [ definition 5 "shifted" ["x"] "resample(x, 1)"
      , definition 6 "raw" ["x"] "let y := shifted x in y"
      ])

  assertLeft "raw Egison keeps forward-reference rejection" isForward $
    inferModelEffects manifest (baseModel
      [ definition 5 "raw" ["x"] "let y := later x in y"
      , definition 6 "later" ["x"] "lap x"
      ])

  boundSummary <- requireRight "bound canonical-name parameter" $
    inferModelEffects manifest (baseModel
      [definition 5 "raw" ["resample", "x"]
        "let y := resample x in y"])
  assertEqual "formal parameters shadow the canonical resample name"
    [("raw", PureFunction)] (effectSummaryDefinitions boundSummary)

  registry <- requireRight "raw trace registry" $
    buildRegistry ((baseModel
      [ definition 5 "inner" ["x"] "lap x"
      , definition 6 "outer" ["x"] "let y := inner x in y"
      ]) { mSteps = [step 8 "u" "outer u"] })
  let [stepOriginId] = preRegistryStepOrigins registry
      stepOrigin = lookupOrigin stepOriginId (preRegistryOrigins registry)
  assertEqual "step retains its direct raw-definition frame"
    ["outer"]
    [FEIR.expansionFrameName frame
    | frame <- FEIR.sourceOriginTrace stepOrigin]

  putStrLn "pre-fec raw Egison fallback tests: ok"

definition :: Int -> String -> [String] -> String -> Def
definition line name parameters body =
  Def name parameters body (Just (source line 15 body))

step :: Int -> String -> String -> Step
step line name body =
  Step KEq (IndexedTarget name []) Nothing body (source line 8 body)

source :: Int -> Int -> String -> SourceText
source line column body = SourceText
  { sourcePath = "raw.fme"
  , sourceLine = line
  , sourceColumn = column
  , sourceOriginal = body
  , sourceTranslated = body
  , sourcePositionMap =
      [SourcePosition line position
      | position <- [column .. column + length body - 1]]
  }

baseModel :: [Def] -> Model
baseModel definitions = Model
  { mName = "raw"
  , mSourcePath = "raw.fme"
  , mDim = 1
  , mAxes = ["x"]
  , mAxesSourceLine = Just 2
  , mMode = Just CollocatedMode
  , mMetricName = Nothing
  , mParams = []
  , mParamSourceLines = []
  , mHelp = []
  , mHelpKinds = []
  , mHelpSourceLines = []
  , mFieldDecls = [FieldDecl "u" Nothing Collocated Scalar 4]
  , mInits = []
  , mInitSourceTexts = []
  , mSteps = []
  , mDd = Nothing
  , mMetric = Nothing
  , mEmbed = Nothing
  , mDefs = definitions
  , mDiscretizationDecls = []
  }

lookupOrigin :: FEIR.OriginId -> FEIR.OriginTable -> FEIR.SourceOrigin
lookupOrigin originId (FEIR.OriginTable origins) =
  case lookup originId origins of
    Just origin -> origin
    Nothing -> error "missing test origin"

isRawDiscrete :: EffectError -> Bool
isRawDiscrete problem =
  case effectErrorIssue problem of
    InvalidEffectExpression message ->
      "direct Egison definition must be continuum-pure" `isInfixOf` message
    _ -> False

isReservedConstructor :: EffectError -> Bool
isReservedConstructor problem =
  case effectErrorIssue problem of
    InvalidEffectExpression message ->
      "cannot access reserved normalization capability" `isInfixOf` message
    _ -> False

isForward :: EffectError -> Bool
isForward problem =
  effectErrorIssue problem == ForwardDefinitionUse "later"

requireRight :: Show error => String -> Either error value -> IO value
requireRight _ (Right value) = pure value
requireRight label (Left problem) = fail (label ++ ": " ++ show problem)

assertLeft :: Show value
  => String -> (error -> Bool) -> Either error value -> IO ()
assertLeft label predicate result =
  case result of
    Left problem | predicate problem -> pure ()
    Left _ -> fail (label ++ ": wrong error")
    Right value -> fail (label ++ ": expected failure, got " ++ show value)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
