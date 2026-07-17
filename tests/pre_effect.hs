module Main where

import Data.List (isInfixOf)

import Formurae.FEIR.PrimitiveManifest
import Formurae.FEIR.Syntax (OpId(..))
import Formurae.Pre.Effect
import Formurae.Syntax
import Formurae.TensorExpr (parseTensorExpr)

main :: IO ()
main = do
  source <- readFile "spec/feir-primitives.sexp"
  manifest <- either (fail . show) pure (parsePrimitiveManifest source)

  -- Canonical Δ/δ on declared geometry are prelude macro expansions, so
  -- the effect layer never sees them there; discrete effects propagate
  -- through definitions from the grid operators themselves.
  summary <- either (fail . show) pure
    (inferModelEffects manifest baseModel
      { mDefs =
          [ definition "smooth" ["u"] "lap u"
          , definition "weighted" ["u"] "pd1r1_x u"
          , definition "nested" ["u"] "weighted u + smooth u"
          ]
      , mSteps = [step "u" "nested u"]
      })
  assertEqual "definition effect propagation"
    [ ("smooth", PureFunction)
    , ("weighted", DiscreteFunction [OpId "derivative.grid-whole"])
    , ("nested", DiscreteFunction [OpId "derivative.grid-whole"])
    ]
    (effectSummaryDefinitions summary)

  assertEqual "constant-geometry scalar Delta remains continuum-pure"
    (Right PureFunction)
    (expressionEffect manifest baseModel (EffectSummary [])
      "constant scalar Delta" (parseTensorExpr "Δ u"))
  assertEqual "the discrete exterior derivative is a grid-whole operation"
    (Right (DiscreteFunction [OpId "derivative.grid-whole"]))
    (expressionEffect manifest variableMetricModel (EffectSummary [])
      "discrete exterior derivative" (parseTensorExpr "dExterior u"))
  assertEqual "the adjoint flux divergence is a grid-whole operation"
    (Right (DiscreteFunction [OpId "derivative.grid-whole"]))
    (expressionEffect manifest variableMetricDecModel (EffectSummary [])
      "adjoint flux divergence" (parseTensorExpr "dFluxDiv u"))
  assertEqual "constant-geometry Hodge Laplacian remains continuum-pure"
    (Right PureFunction)
    (expressionEffect manifest decModel (EffectSummary [])
      "canonical Hodge Laplacian" (parseTensorExpr "ΔH u"))
  assertLeft "scalar Delta is collocated-only" isModeMismatch
    (expressionEffect manifest decModel (EffectSummary [])
      "wrong-mode scalar Delta" (parseTensorExpr "Δ u"))
  assertLeft "codifferential is DEC-only" isModeMismatch
    (expressionEffect manifest baseModel (EffectSummary [])
      "wrong-mode codifferential" (parseTensorExpr "δ u"))
  assertLeft "variable-metric Hodge Laplacian is explicitly unsupported"
    isVariableHodgeLaplacian
    (expressionEffect manifest variableMetricDecModel (EffectSummary [])
      "variable Hodge Laplacian" (parseTensorExpr "ΔH u"))
  assertEqual "constant-metric hodge-d-hodge remains continuum-pure"
    (Right PureFunction)
    (expressionEffect manifest decModel (EffectSummary [])
      "constant hodge composition"
      (parseTensorExpr "hodge (d (hodge u))"))
  assertLeft "variable-metric hodge-d-hodge requires canonical codifferential"
    isVariableHodgeComposition
    (expressionEffect manifest variableMetricDecModel (EffectSummary [])
      "variable hodge composition"
      (parseTensorExpr "hodge (d (hodge u))"))
  assertLeft "raw Egison cannot hide variable-metric hodge-d-hodge in a binder"
    isVariableHodgeComposition
    (inferModelEffects manifest variableMetricDecModel
      { mDefs =
          [definition "rawAdjoint" ["A"]
            "let B := hodge A in hodge (d B)"]
      })
  shadowedRawSummary <- either (fail . show) pure
    (inferModelEffects manifest variableMetricDecModel
      { mDefs =
          [ definition "hodge" ["A"] "A"
          , definition "d" ["A"] "A"
          , definition "rawAdjoint" ["A"]
              "let B := hodge A in hodge (d B)"
          ]
      })
  assertEqual "raw variable-metric guard respects user-shadowed canonical names"
    [ ("hodge", PureFunction)
    , ("d", PureFunction)
    , ("rawAdjoint", PureFunction)
    ]
    (effectSummaryDefinitions shadowedRawSummary)

  assertLeft "helper aliases cannot hide variable-metric hodge-d-hodge"
    isVariableHodgeComposition
    (inferModelEffects manifest variableMetricDecModel
      { mDefs =
          [ definition "hs" ["A"] "hodge A"
          , definition "ex" ["A"] "d A"
          , definition "bad" ["A"] "hs (ex (hs A))"
          ]
      })
  assertLeft "contractWith reducers retain variable-metric operator paths"
    isVariableHodgeComposition
    (inferModelEffects manifest variableMetricDecModel
      { mDefs =
          [definition "star" ["lhs", "rhs"] "hodge lhs"]
      , mSteps =
          [step "u" "hodge (d (contractWith star u))"]
      })
  assertLeft "user-defined dot retains variable-metric operator paths"
    isVariableHodgeComposition
    (inferModelEffects manifest variableMetricDecModel
      { mDefs =
          [definition "." ["lhs", "rhs"] "hodge lhs"]
      , mSteps =
          [step "u" "hodge (d (u . u))"]
      })
  assertLeft "raw helper aliases cannot hide variable-metric hodge-d-hodge"
    isVariableHodgeComposition
    (inferModelEffects manifest variableMetricDecModel
      { mDefs =
          [ definition "hs" ["A"] "hodge A"
          , definition "ex" ["A"] "d A"
          , definition "rawBad" ["A"]
              "let B := hs A in hs (ex B)"
          ]
      })
  assertLeft "step lets retain the variable-metric operator path"
    isVariableHodgeComposition
    (inferModelEffects manifest variableMetricDecModel
      { mSteps =
          [ valueStep KLet "starred" "hodge u"
          , valueStep KLet "exterior" "d starred"
          , step "u" "hodge exterior"
          ]
      })
  shadowedStructuredSummary <- either (fail . show) pure
    (inferModelEffects manifest variableMetricDecModel
      { mDefs =
          [ definition "hodge" ["A"] "A"
          , definition "d" ["A"] "A"
          , definition "hs" ["A"] "hodge A"
          , definition "ex" ["A"] "d A"
          , definition "safe" ["A"] "hs (ex (hs A))"
          ]
      })
  assertEqual "structured metric tags respect user-shadowed canonical names"
    [ ("hodge", PureFunction)
    , ("d", PureFunction)
    , ("hs", PureFunction)
    , ("ex", PureFunction)
    , ("safe", PureFunction)
    ]
    (effectSummaryDefinitions shadowedStructuredSummary)

  assertEqual "a user delta definition prevents scalar-identity fusion"
    (Right PureFunction)
    (expressionEffect manifest variableMetricModel
      (EffectSummary [("δ", PureFunction)]) "shadowed scalar identity"
      (parseTensorExpr "0 - δ (d u)"))
  assertLeft "a shadowed d prevents scalar-identity fusion"
    isModeMismatch
    (expressionEffect manifest variableMetricModel
      (EffectSummary [("d", PureFunction)]) "shadowed exterior derivative"
      (parseTensorExpr "0 - δ (d u)"))
  assertLeft "an algebraic near miss does not select scalar Delta"
    isModeMismatch
    (expressionEffect manifest variableMetricModel (EffectSummary [])
      "near-miss scalar identity" (parseTensorExpr "1 - δ (d u)"))
  mapM_ (\name -> assertEqual ("removed ASCII surface name is ordinary: " ++ name)
      (Right PureFunction)
      (expressionEffect manifest variableMetricModel (EffectSummary [])
        ("removed name " ++ name) (parseTensorExpr (name ++ " u"))))
    ["dForm", "delta", "codiff", "formLaplacian", "lb"]
  mapM_ (\expression -> assertEqual
      ("removed discrete surface spelling has no primitive effect: " ++ expression)
      (Right PureFunction)
      (expressionEffect manifest baseModel (EffectSummary [])
        ("removed discrete spelling " ++ expression)
        (parseTensorExpr expression)))
    [ "gridD_x u", "gridDerivative_x u"
    , "orderedD(u, x)", "orderedDerivative(u, x)"
    , "interpolate(u, 0)"
    , "fluxDiv u", "conservativeDiv u", "materialize u"
    ]
  assertEqual "indexed ASCII delta remains an ordinary Kronecker tensor"
    (Right PureFunction)
    (expressionEffect manifest variableMetricModel (EffectSummary [])
      "Kronecker delta" (parseTensorExpr "delta~i_j . X~j"))

  assertLeft "coordinate derivative rejects a direct discrete request"
    isGridDerivativeBarrier
    (inferModelEffects manifest variableMetricModel
      { mDefs = [definition "bad" ["u"] "pd1r1_x (d_x u)"] })

  assertLeft "analytic ∂/∂ rejects a discrete operand"
    isDerivativeBarrier
    (inferModelEffects manifest variableMetricModel
      { mDefs =
          [definition "bad" ["u"]
            "FormuraeInternalAnalyticDerivative (d_x u) x"]
      })

  assertLeft "coordinate derivative rejects a transitive discrete request"
    isGridDerivativeBarrier
    (inferModelEffects manifest variableMetricModel
      { mDefs =
          [ definition "weighted" ["u"] "d_x u"
          , definition "bad" ["u"] "pd1r1_x (weighted u)"
          ]
      })

  assertLeft "coordinate derivative rejects a discrete function-value alias"
    isGridDerivativeBarrier
    (inferModelEffects manifest variableMetricModel
      { mDefs =
          [ definition "weighted" ["u"] "d_x u"
          , definition "alias" ["ignored"] "weighted"
          , definition "bad" ["u"] "pd1r1_x (alias 0 u)"
          ]
      })

  assertLeft "coordinate derivative rejects a conditional discrete function value"
    isGridDerivativeBarrier
    (inferModelEffects manifest variableMetricModel
      { mDefs =
          [ definition "weighted" ["u"] "d_x u"
          , definition "choose" ["flag"] "if flag then weighted else lap"
          , definition "bad" ["u"] "pd1r1_x (choose 1 u)"
          ]
      })

  assertLeft "effectful higher-order arguments are explicit errors"
    isHigherOrderError
    (inferModelEffects manifest variableMetricModel
      { mDefs =
          [ definition "weighted" ["u"] "d_x u"
          , definition "bad" ["u"] "apply weighted u"
          ]
      })

  assertLeft "effectful contractWith reducers are explicit errors"
    isHigherOrderError
    (inferModelEffects manifest baseModel
      { mDefs =
          [ definition "shifted" ["lhs", "rhs"]
              "resample(lhs + rhs, 0, 0, 0)"
          ]
      , mSteps = [step "u" "contractWith shifted u"]
      })

  assertLeft "coordinate derivatives retain a user-defined dot effect"
    isGridDerivativeBarrier
    (inferModelEffects manifest baseModel
      { mDefs =
          [definition "." ["lhs", "rhs"]
            "resample(lhs + rhs, 0, 0, 0)"]
      , mSteps = [step "u" "d_x (u . u)"]
      })

  assertLeft "quoted derivatives retain a user-defined dot effect"
    isGridDerivativeBarrier
    (inferModelEffects manifest baseModel
      { mDefs =
          [definition "." ["lhs", "rhs"]
            "resample(lhs + rhs, 0, 0, 0)"]
      , mSteps = [step "u" "`(d_x (u . u))"]
      })

  pureReducerSummary <- either (fail . show) pure
    (inferModelEffects manifest baseModel
      { mDefs = [definition "combine" ["lhs", "rhs"] "lhs + rhs"]
      , mSteps = [step "u" "contractWith combine u"]
      })
  assertEqual "pure contractWith reducers remain accepted"
    [("combine", PureFunction)]
    (effectSummaryDefinitions pureReducerSummary)

  assertLeft "indexed wide derivative function values are higher-order errors"
    isHigherOrderError
    (expressionEffect manifest baseModel (EffectSummary [])
      "wide higher-order value" (parseTensorExpr "apply pd2r2_x u"))

  assertLeft "explicit resample function values are higher-order errors"
    isHigherOrderError
    (expressionEffect manifest baseModel (EffectSummary [])
      "resample tensorMap function" (parseTensorExpr "tensorMap resample u"))

  assertLeft "effectful function-value aliases are explicit higher-order errors"
    isHigherOrderError
    (inferModelEffects manifest variableMetricModel
      { mDefs =
          [ definition "weighted" ["u"] "d_x u"
          , definition "alias" ["ignored"] "weighted"
          , definition "bad" ["u"] "apply alias u"
          ]
      })

  assertLeft "conditional effectful function values are higher-order errors"
    isHigherOrderError
    (inferModelEffects manifest variableMetricModel
      { mDefs =
          [ definition "weighted" ["u"] "d_x u"
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
  assertEqual "removed surface names are ordinary user definitions and parameters"
    [ ("materialize", PureFunction)
    , ("applyShadow", PureFunction)
    ]
    (effectSummaryDefinitions shadowSummary)

  boundSummary <- either (fail . show) pure
    (inferModelEffects manifest baseModel
      { mDefs =
          [definition "applyShadow" ["materialize", "x"] "materialize x"]
      })
  assertEqual "a removed surface name is ordinary when used as a parameter"
    [("applyShadow", PureFunction)]
    (effectSummaryDefinitions boundSummary)

  removedSummary <- either (fail . show) pure
    (inferModelEffects manifest baseModel
      { mDefs = [definition "stored" ["x"] "materialize x"] })
  assertEqual "an undeclared removed surface name has no primitive effect"
    [("stored", PureFunction)]
    (effectSummaryDefinitions removedSummary)

  let parsedWide = parseTensorExpr "pd2r2_x u"
  assertEqual "explicit wide derivative is manifest-backed"
    (Right (DiscreteFunction
      [OpId "derivative.coordinate-wide"]))
    (expressionEffect manifest baseModel (EffectSummary []) "wide" parsedWide)

  assertEqual "unprimed coordinate derivative is a placement-directed grid request"
    (Right (DiscreteFunction
      [OpId "derivative.grid-whole"]))
    (expressionEffect manifest baseModel (EffectSummary [])
      "coordinate derivative"
      (parseTensorExpr "d_x (u * u / 2)"))
  assertEqual "ordered coordinate derivative is a centered explicit request"
    (Right (DiscreteFunction
      [OpId "derivative.coordinate-wide"]))
    (expressionEffect manifest baseModel (EffectSummary [])
      "second coordinate derivative"
      (parseTensorExpr "pd2r1_x u"))
  assertEqual "analytic ∂/∂ remains pure"
    (Right PureFunction)
    (expressionEffect manifest baseModel (EffectSummary [])
      "analytic coordinate derivative"
      (parseTensorExpr "FormuraeInternalAnalyticDerivative (u * u / 2) x"))
  assertEqual "analytic ∂/∂ by the coordinates vector remains pure"
    (Right PureFunction)
    (expressionEffect manifest baseModel (EffectSummary [])
      "analytic tensor derivative"
      (parseTensorExpr "FormuraeInternalAnalyticDerivative u coordinates"))
  assertEqual "symbolic indexed derivative is a per-axis grid request"
    (Right (DiscreteFunction
      [OpId "derivative.grid-whole"]))
    (expressionEffect manifest baseModel (EffectSummary [])
      "indexed derivative"
      (parseTensorExpr "d_i (u * u)"))
  assertLeft "a single quoted derivative is rejected as redundant"
    isSingleQuotedDerivative
    (expressionEffect manifest baseModel (EffectSummary [])
      "single quoted derivative"
      (parseTensorExpr "`(d_x (u * u / 2))"))

  assertEqual "tensor literal merges effects from structured components"
    (Right (DiscreteFunction
      [OpId "derivative.grid-whole"]))
    (expressionEffect manifest baseModel (EffectSummary [])
      "coordinate derivatives in tensor literal"
      (parseTensorExpr
        "[| -kappa * d_x u, -kappa * d_x (u * u) |]_i"))

  let twoAxisModel = baseModel { mDim = 2, mAxes = ["x", "y"] }
  assertEqual "multi quoted derivative is one ordered request"
    (Right (DiscreteFunction
      [OpId "derivative.ordered"]))
    (expressionEffect manifest twoAxisModel (EffectSummary [])
      "multi quoted derivative"
      (parseTensorExpr "`(d_y (`(d_x (`(d_x u)))))"))

  assertLeft "coordinate derivative rejects a nested grid-whole request"
    isGridDerivativeBarrier
    (expressionEffect manifest baseModel (EffectSummary [])
      "grid request under a coordinate derivative"
      (parseTensorExpr "pd1r1_x (d_x (u * u / 2))"))

  assertLeft "coordinate derivative rejects a nested discrete derivative"
    isGridDerivativeBarrier
    (expressionEffect manifest baseModel (EffectSummary [])
      "nested coordinate derivative"
      (parseTensorExpr "d_x (d_x u)"))

  assertLeft "quoted derivative rejects an already-discrete operand"
    isGridDerivativeBarrier
    (expressionEffect manifest baseModel (EffectSummary [])
      "discrete request under quoted derivative"
      (parseTensorExpr "`(d_x (`(d_x (resample(u, 0)))))"))

  assertLeft "quoted derivative rejects a discrete step-let alias"
    isGridDerivativeBarrier
    (inferModelEffects manifest baseModel
      { mSteps =
          [ valueStep KLet "held" "d_x u"
          , step "u" "`(d_x (`(d_x held)))"
          ]
      })
  assertLeft "coordinate derivative rejects a discrete step-let alias"
    isGridDerivativeBarrier
    (inferModelEffects manifest baseModel
      { mSteps =
          [ valueStep KLet "held" "resample(u, 0)"
          , step "u" "d_x held"
          ]
      })
  assertRight "ordinary first-order use of a step-let value is allowed"
    (inferModelEffects manifest baseModel
      { mSteps =
          [ valueStep KLet "held" "d_x u"
          , step "u" "consume held"
          ]
      })
  assertRight "materialized local is a fresh first-order stored value"
    (inferModelEffects manifest baseModel
      { mSteps =
          [ valueStep KLocal "q" "d_x u"
          , step "u" "divg q"
          ]
      })
  assertRight "coordinate derivative may consume a materialized discrete local"
    (inferModelEffects manifest baseModel
      { mSteps =
          [ valueStep KLocal "sampled" "resample(u, 0)"
          , step "u" "d_x sampled"
          ]
      })
  assertLeft "a materialized local still checks its own discrete RHS"
    isGridDerivativeBarrier
    (inferModelEffects manifest baseModel
      { mSteps =
          [ valueStep KLocal "sampled" "d_x (resample(u, 0))"
          , step "u" "sampled"
          ]
      })

  genericQuoteSummary <- either (fail . show) pure
    (inferModelEffects manifest baseModel
      { mDefs = [definition "genericQuote" ["u"] "`(u * u)"] })
  assertEqual "a non-derivative quote remains a pure raw Egison definition"
    [("genericQuote", PureFunction)]
    (effectSummaryDefinitions genericQuoteSummary)

  putStrLn "pre-fec effect tests: ok"

isDerivativeBarrier :: EffectError -> Bool
isDerivativeBarrier problem =
  case effectErrorIssue problem of
    AnalyticDerivativeOfDiscrete _ -> True
    _ -> False

isSingleQuotedDerivative :: EffectError -> Bool
isSingleQuotedDerivative problem =
  case effectErrorIssue problem of
    InvalidEffectExpression message ->
      "single quoted derivative" `isInfixOf` message
    _ -> False

isGridDerivativeBarrier :: EffectError -> Bool
isGridDerivativeBarrier problem =
  case effectErrorIssue problem of
    GridDerivativeOfDiscrete _ -> True
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

isModeMismatch :: EffectError -> Bool
isModeMismatch problem =
  case effectErrorIssue problem of
    CanonicalOperatorModeMismatch _ -> True
    _ -> False

isVariableHodgeLaplacian :: EffectError -> Bool
isVariableHodgeLaplacian problem =
  case effectErrorIssue problem of
    VariableMetricHodgeLaplacianUnsupported -> True
    _ -> False

isVariableHodgeComposition :: EffectError -> Bool
isVariableHodgeComposition problem =
  case effectErrorIssue problem of
    VariableMetricHodgeCompositionUnsupported -> True
    _ -> False

definition :: String -> [String] -> String -> Def
definition name parameters body = Def name parameters body Nothing

step :: String -> String -> Step
step = valueStep KEq

valueStep :: SK -> String -> String -> Step
valueStep kind name expression =
  Step kind (IndexedTarget name []) localDeclaration expression sourceText
  where
    localDeclaration = case kind of
      KLocal -> Just (LocalDecl name Nothing Collocated Scalar 1)
      _ -> Nothing
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
  , mMetric = Nothing
  , mEmbed = Nothing
  , mDefs = []
  , mDiscretizationDecls = []
  }

variableMetricModel :: Model
variableMetricModel = baseModel { mMetric = Just ["1"] }

decModel :: Model
decModel = baseModel { mMode = Just DecMode }

variableMetricDecModel :: Model
variableMetricDecModel = variableMetricModel { mMode = Just DecMode }

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

assertRight :: Show error => String -> Either error value -> IO ()
assertRight _ (Right _) = pure ()
assertRight label (Left problem) =
  fail (label ++ ": expected success, got " ++ show problem)
