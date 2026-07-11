module Main where

import Formurae.FEIR.PrimitiveManifest
import Formurae.FEIR.Syntax (VersionedOpId(..))
import Formurae.Pre.Effect
import Formurae.Syntax
import Formurae.TensorExpr (parseTensorExpr)

main :: IO ()
main = do
  source <- readFile "spec/feir-primitives-v1.sexp"
  manifest <- either (fail . show) pure (parsePrimitiveManifest source)

  summary <- either (fail . show) pure
    (inferModelEffects manifest baseModel
      { mDefs =
          [ definition "smooth" ["u"] "lap u"
          , definition "weighted" ["u"] "lb u"
          , definition "nested" ["u"] "weighted u + smooth u"
          ]
      , mSteps = [step "u" "nested u"]
      })
  assertEqual "definition effect propagation"
    [ ("smooth", PureFunction)
    , ("weighted", DiscreteFunction [VersionedOpId "lb.orthogonal@1"])
    , ("nested", DiscreteFunction [VersionedOpId "lb.orthogonal@1"])
    ]
    (effectSummaryDefinitions summary)

  assertLeft "analytic derivative rejects a direct discrete request"
    isDerivativeBarrier
    (inferModelEffects manifest baseModel
      { mDefs = [definition "bad" ["u"] "pd1r1_x (lb u)"] })

  assertLeft "analytic derivative rejects a transitive discrete request"
    isDerivativeBarrier
    (inferModelEffects manifest baseModel
      { mDefs =
          [ definition "weighted" ["u"] "lb u"
          , definition "bad" ["u"] "pd1r1_x (weighted u)"
          ]
      })

  assertLeft "analytic derivative rejects a discrete function-value alias"
    isDerivativeBarrier
    (inferModelEffects manifest baseModel
      { mDefs =
          [ definition "weighted" ["u"] "lb u"
          , definition "alias" ["ignored"] "weighted"
          , definition "bad" ["u"] "pd1r1_x (alias 0 u)"
          ]
      })

  assertLeft "analytic derivative rejects a conditional discrete function value"
    isDerivativeBarrier
    (inferModelEffects manifest baseModel
      { mDefs =
          [ definition "weighted" ["u"] "lb u"
          , definition "choose" ["flag"] "if flag then weighted else lap"
          , definition "bad" ["u"] "pd1r1_x (choose 1 u)"
          ]
      })

  assertLeft "effectful higher-order arguments are explicit errors"
    isHigherOrderError
    (inferModelEffects manifest baseModel
      { mDefs =
          [ definition "weighted" ["u"] "lb u"
          , definition "bad" ["u"] "apply weighted u"
          ]
      })

  assertLeft "indexed wide derivative function values are higher-order errors"
    isHigherOrderError
    (expressionEffect manifest baseModel (EffectSummary [])
      "wide higher-order value" (parseTensorExpr "apply pd2r2_x u"))

  assertLeft "indexed grid derivative tensorMap functions are higher-order errors"
    isHigherOrderError
    (expressionEffect manifest baseModel (EffectSummary [])
      "grid tensorMap function" (parseTensorExpr "tensorMap gridD_x u"))

  assertLeft "effectful function-value aliases are explicit higher-order errors"
    isHigherOrderError
    (inferModelEffects manifest baseModel
      { mDefs =
          [ definition "weighted" ["u"] "lb u"
          , definition "alias" ["ignored"] "weighted"
          , definition "bad" ["u"] "apply alias u"
          ]
      })

  assertLeft "conditional effectful function values are higher-order errors"
    isHigherOrderError
    (inferModelEffects manifest baseModel
      { mDefs =
          [ definition "weighted" ["u"] "lb u"
          , definition "bad" ["flag", "u"]
              "apply (if flag then weighted else lap) u"
          ]
      })

  assertLeft "forward definition use is rejected"
    isForwardUse
    (inferModelEffects manifest baseModel
      { mDefs =
          [ definition "first" ["u"] "second u"
          , definition "second" ["u"] "lap u"
          ]
      })

  shadowSummary <- either (fail . show) pure
    (inferModelEffects manifest baseModel
      { mDefs =
          [ definition "materialize" ["x"] "x + 1"
          , definition "applyShadow" ["materialize", "x"] "materialize x"
          ]
      , mSteps = [step "u" "applyShadow materialize u"]
      })
  assertEqual "user definitions and bound parameters shadow explicit primitives"
    [ ("materialize", PureFunction)
    , ("applyShadow", PureFunction)
    ]
    (effectSummaryDefinitions shadowSummary)

  boundSummary <- either (fail . show) pure
    (inferModelEffects manifest baseModel
      { mDefs =
          [definition "applyShadow" ["materialize", "x"] "materialize x"]
      })
  assertEqual "bound parameter alone shadows an explicit primitive"
    [("applyShadow", PureFunction)]
    (effectSummaryDefinitions boundSummary)

  primitiveSummary <- either (fail . show) pure
    (inferModelEffects manifest baseModel
      { mDefs = [definition "stored" ["x"] "materialize x"] })
  assertEqual "unshadowed explicit primitives keep their discrete effect"
    [("stored", DiscreteFunction
      [VersionedOpId "operator.materialized@1"])]
    (effectSummaryDefinitions primitiveSummary)

  let parsedWide = parseTensorExpr "pd2r2_x u"
  assertEqual "explicit wide derivative is manifest-backed"
    (Right (DiscreteFunction
      [VersionedOpId "derivative.coordinate-wide@1"]))
    (expressionEffect manifest baseModel (EffectSummary []) "wide" parsedWide)

  let parsedGridWhole = parseTensorExpr "gridD_x (u * u / 2)"
  assertEqual "analytic derivative remains pure"
    (Right PureFunction)
    (expressionEffect manifest baseModel (EffectSummary [])
      "analytic derivative" (parseTensorExpr "pd1r1_x (u * u / 2)"))
  assertEqual "grid-whole derivative is manifest-backed"
    (Right (DiscreteFunction
      [VersionedOpId "derivative.grid-whole@1"]))
    (expressionEffect manifest baseModel (EffectSummary [])
      "grid whole" parsedGridWhole)

  assertEqual "gridDerivative alias is manifest-backed"
    (Right (DiscreteFunction
      [VersionedOpId "derivative.grid-whole@1"]))
    (expressionEffect manifest baseModel (EffectSummary [])
      "grid whole alias" (parseTensorExpr "gridDerivative_x u"))

  assertLeft "analytic derivative rejects a grid-whole request"
    isDerivativeBarrier
    (expressionEffect manifest baseModel (EffectSummary [])
      "grid whole under analytic derivative"
      (parseTensorExpr "pd1r1_x (gridD_x (u * u / 2))"))

  putStrLn "pre-fec effect tests: ok"

isDerivativeBarrier :: EffectError -> Bool
isDerivativeBarrier problem =
  case effectErrorIssue problem of
    AnalyticDerivativeOfDiscrete _ -> True
    _ -> False

isHigherOrderError :: EffectError -> Bool
isHigherOrderError problem =
  case effectErrorIssue problem of
    EffectfulHigherOrderArgument _ _ -> True
    _ -> False

isForwardUse :: EffectError -> Bool
isForwardUse problem =
  case effectErrorIssue problem of
    ForwardDefinitionUse "second" -> True
    _ -> False

definition :: String -> [String] -> String -> Def
definition name parameters body = Def name parameters body Nothing

step :: String -> String -> Step
step name expression = Step KEq name [] expression sourceText
  where
    sourceText = SourceText "effect.fme" 1 1 expression expression
      [SourcePosition 1 column | column <- [1 .. length expression]]

baseModel :: Model
baseModel = Model
  { mName = "effect"
  , mSourcePath = "effect.fme"
  , mDim = 1
  , mAxes = ["x"]
  , mAxesSourceLine = Just 1
  , mMode = Just CollocatedMode
  , mMetricName = Nothing
  , mParams = []
  , mParamSourceLines = []
  , mHelp = []
  , mHelpKinds = []
  , mHelpSourceLines = []
  , mFieldDecls = [FieldDecl "u" Nothing Collocated Scalar 1]
  , mInits = []
  , mInitSourceTexts = []
  , mSteps = []
  , mDd = Nothing
  , mMetric = Nothing
  , mEmbed = Nothing
  , mDefs = []
  , mDiscretizationDecls = []
  }

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)

assertLeft :: Show a => String -> (e -> Bool) -> Either e a -> IO ()
assertLeft label predicate result =
  case result of
    Left problem | predicate problem -> pure ()
    Left _ -> fail (label ++ ": wrong error")
    Right value -> fail (label ++ ": expected failure, got " ++ show value)
