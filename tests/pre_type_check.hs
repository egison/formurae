module Main where

import Formurae.Pre.Parse (parseModel)
import Formurae.Pre.TypeCheck
import Formurae.Syntax (Model)

main :: IO ()
main = do
  quotedTensor <- model "quoted-tensor" quotedTensorSource
  assertLeft "quoted derivative is scalar-only"
    "quoted derivative requires a scalar operand, but received ordinary tensor"
    (validateModelOperatorTypes quotedTensor)

  deltaTensor <- model "delta-tensor" deltaTensorSource
  assertLeft "scalar Delta does not componentwise-lift"
    "scalar Δ requires a scalar operand, but received ordinary tensor"
    (validateModelOperatorTypes deltaTensor)

  codiffTensor <- model "codiff-tensor" codiffTensorSource
  assertLeft "codifferential requires a differential form"
    "canonical δ requires a scalar or differential form, but received ordinary tensor"
    (validateModelOperatorTypes codiffTensor)

  topDegree <- model "top-degree" topDegreeSource
  assertLeft "exterior derivative rejects a top-degree form"
    "canonical d is undefined on a top-degree 2-form in dimension 2"
    (validateModelOperatorTypes topDegree)

  unknownDefinition <- model "unknown-definition" unknownDefinitionSource
  assertLeft "untyped helper parameters cannot hide a scalar-only boundary"
    "scalar Δ requires a statically known scalar operand; untyped definition parameters cannot cross this operator boundary"
    (validateModelOperatorTypes unknownDefinition)

  rawDefinition <- model "raw-definition" rawDefinitionSource
  assertLeft "raw Egison cannot bypass typed canonical operands"
    "canonical hodge cannot be used inside an untyped raw Egison definition; apply it to a declared field, typed local, or structured step expression"
    (validateModelOperatorTypes rawDefinition)

  shadowedIntrinsic <- model "shadowed-intrinsic" shadowedIntrinsicSource
  assertLeft "user-shadowed intrinsics do not retain builtin result kinds"
    "canonical δ requires a statically known scalar or differential form; untyped definition parameters cannot cross this operator boundary"
    (validateModelOperatorTypes shadowedIntrinsic)

  rankUnknownDivergence <- model "rank-unknown-divergence"
    rankUnknownDivergenceSource
  assertLeft "higher-rank divg cannot be assumed scalar"
    "canonical δ requires a statically known scalar or differential form; untyped definition parameters cannot cross this operator boundary"
    (validateModelOperatorTypes rankUnknownDivergence)

  wrongArity <- model "wrong-arity" wrongAritySource
  assertLeft "canonical operators are always unary"
    "canonical δ is unary, but received 2 operands"
    (validateModelOperatorTypes wrongArity)

  canonicalAlias <- model "canonical-alias" canonicalAliasSource
  assertLeft "canonical operators cannot escape as first-class aliases"
    "canonical δ cannot be used as a first-class value; apply it directly to one statically typed operand"
    (validateModelOperatorTypes canonicalAlias)

  computedCanonicalAlias <- model "computed-canonical-alias"
    computedCanonicalAliasSource
  assertLeft "computed function heads cannot hide canonical values"
    "canonical δ cannot be used as a first-class value; apply it directly to one statically typed operand"
    (validateModelOperatorTypes computedCanonicalAlias)

  rawShadow <- model "raw-shadow" rawShadowSource
  assertEqual "raw bodies respect user-definition canonical shadowing"
    (Right ()) (validateModelOperatorTypes rawShadow)

  formZeroScalarMix <- model "form-zero-scalar-mix" formZeroScalarMixSource
  assertLeft "0-form arithmetic does not erase form kind"
    "quoted derivative requires a scalar operand, but received 0-form"
    (validateModelOperatorTypes formZeroScalarMix)

  scalarDeltaIdentity <- model "scalar-delta-identity"
    scalarDeltaIdentitySource
  assertEqual "the exact collocated scalar Delta identity remains scalar"
    (Right ()) (validateModelOperatorTypes scalarDeltaIdentity)

  scalarLocalMismatch <- model "scalar-local-mismatch"
    scalarLocalMismatchSource
  assertLeft "scalar locals reject a known tensor RHS"
    "local q declares scalar, but its RHS has ordinary tensor kind"
    (validateModelOperatorTypes scalarLocalMismatch)

  formLocalMismatch <- model "form-local-mismatch" formLocalMismatchSource
  assertLeft "form locals reject a known ordinary tensor RHS"
    "local q declares 1-form, but its RHS has ordinary tensor kind"
    (validateModelOperatorTypes formLocalMismatch)

  dotShadow <- model "dot-shadow-kind" dotShadowKindSource
  assertLeft "a user-defined dot has no builtin contraction result kind"
    "canonical δ requires a statically known scalar or differential form; untyped definition parameters cannot cross this operator boundary"
    (validateModelOperatorTypes dotShadow)

  mapM_ (\(label, expression) -> do
      nested <- model label (nestedTraversalSource expression)
      assertLeft (label ++ " validates its body")
        "scalar Δ requires a scalar operand, but received ordinary tensor"
        (validateModelOperatorTypes nested))
    [ ("append-index-child", "(Δ V)..._i")
    , ("contract-with-child", "contractWith (+) (Δ V)")
    , ("tensor-map-child", "tensorMap sin (Δ V)")
    , ("subrefs-child", "subrefs (Δ V) [_i]")
    , ("transpose-child", "transpose [j, i] (Δ V)")
    ]

  mapM_ (\(label, expression) -> do
      higherOrder <- model label (canonicalFunctionTraversalSource expression)
      assertLeft (label ++ " validates its function operand")
        "canonical δ cannot be used as a first-class value; apply it directly to one statically typed operand"
        (validateModelOperatorTypes higherOrder))
    [ ("contract-with-reducer", "contractWith δ V")
    , ("tensor-map-function", "tensorMap δ V")
    ]

  updateKindMismatch <- model "update-kind-mismatch"
    updateKindMismatchSource
  assertLeft "field updates cannot wash a 0-form into a scalar"
    "field u declares scalar, but its RHS has 0-form kind"
    (validateModelOperatorTypes updateKindMismatch)

  initializerKindMismatch <- model "initializer-kind-mismatch"
    initializerKindMismatchSource
  assertLeft "CAS initializers cannot wash a 0-form into a scalar"
    "field u declares scalar, but its RHS has 0-form kind"
    (validateModelOperatorTypes initializerKindMismatch)

  formUpdateFromScalar <- model "form-update-from-scalar"
    formUpdateFromScalarSource
  assertEqual "a scalar may initialize a declared 0-form update"
    (Right ()) (validateModelOperatorTypes formUpdateFromScalar)

  metricKindMismatch <- model "metric-kind-mismatch"
    metricKindMismatchSource
  assertLeft "metric scale factors require scalar expressions"
    "metric scale expression requires a scalar value, but received ordinary tensor"
    (validateModelOperatorTypes metricKindMismatch)

  metricCanonicalOperand <- model "metric-canonical-operand"
    metricCanonicalOperandSource
  assertLeft "metric expressions traverse canonical operands"
    "scalar Δ requires a scalar operand, but received ordinary tensor"
    (validateModelOperatorTypes metricCanonicalOperand)

  genericGeometryQuote <- model "generic-geometry-quote"
    genericGeometryQuoteSource
  assertEqual "generic CAS quotes remain valid in geometry expressions"
    (Right ()) (validateModelOperatorTypes genericGeometryQuote)

  rawGeometryCanonical <- model "raw-geometry-canonical"
    rawGeometryCanonicalSource
  assertLeft "raw geometry fallback cannot hide a canonical operator"
    "canonical hodge cannot be used inside an untyped metric scale expression; rewrite it as a structured expression"
    (validateModelOperatorTypes rawGeometryCanonical)

  embeddingCanonicalValue <- model "embedding-canonical-value"
    embeddingCanonicalValueSource
  assertLeft "embedding expressions reject first-class canonical values"
    "canonical δ cannot be used as a first-class value; apply it directly to one statically typed operand"
    (validateModelOperatorTypes embeddingCanonicalValue)

  continuumDDKindMismatch <- model "continuum-dd-kind-mismatch"
    continuumDDKindMismatchSource
  assertLeft "assert-dd-zero checks the operand of its internal d(d value)"
    "assert-dd-zero internally applies canonical d and requires a scalar or differential form, but received ordinary tensor"
    (validateModelOperatorTypes continuumDDKindMismatch)

  continuumDDTopDegree <- model "continuum-dd-top-degree"
    continuumDDTopDegreeSource
  assertLeft "assert-dd-zero checks both internal exterior derivatives"
    "canonical d is undefined on a top-degree 2-form in dimension 2"
    (validateModelOperatorTypes continuumDDTopDegree)

  symbolicPi <- model "symbolic-pi" symbolicPiSource
  assertEqual "symbolic pi is a statically known scalar"
    (Right ()) (validateModelOperatorTypes symbolicPi)

  valid <- model "valid" validSource
  assertEqual "typed fields and prior scalar local aliases are accepted"
    (Right ()) (validateModelOperatorTypes valid)

  putStrLn "pre-fec canonical operator kind tests: ok"

model :: String -> String -> IO Model
model name = parseModel (name ++ ".fme") name

quotedTensorSource :: String
quotedTensorSource = unlines
  [ "mode collocated"
  , "dimension 2"
  , "axes x, y"
  , "field V_i"
  , "field u : scalar"
  , "step:"
  , "  u' = `(∂_x V)"
  , "  V'_i = V_i"
  ]

deltaTensorSource :: String
deltaTensorSource = unlines
  [ "mode collocated"
  , "dimension 2"
  , "axes x, y"
  , "field V_i"
  , "step:"
  , "  V'_i = Δ V"
  ]

codiffTensorSource :: String
codiffTensorSource = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "field V_i @ primal"
  , "step:"
  , "  V'_i = δ V"
  ]

topDegreeSource :: String
topDegreeSource = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "field A : 2-form @ primal"
  , "step:"
  , "  A' = d A"
  ]

unknownDefinitionSource :: String
unknownDefinitionSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "def hidden q = Δ q"
  , "step:"
  , "  u' = u"
  ]

rawDefinitionSource :: String
rawDefinitionSource = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "field A : 1-form"
  , "def hidden X ="
  , "  let Y := X"
  , "   in hodge Y"
  , "step:"
  , "  A' = A"
  ]

shadowedIntrinsicSource :: String
shadowedIntrinsicSource = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "field u : scalar"
  , "field V_i"
  , "field q : scalar"
  , "def sin x = V"
  , "step:"
  , "  q' = δ (sin u)"
  ]

rankUnknownDivergenceSource :: String
rankUnknownDivergenceSource = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "field T_i_j"
  , "field q : scalar"
  , "step:"
  , "  q' = δ (divg T)"
  ]

wrongAritySource :: String
wrongAritySource = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "field A : 1-form"
  , "step:"
  , "  A' = δ(A, A)"
  ]

canonicalAliasSource :: String
canonicalAliasSource = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "field V_i"
  , "field q : scalar"
  , "def alias ignored = δ"
  , "step:"
  , "  q' = alias 0 V"
  ]

computedCanonicalAliasSource :: String
computedCanonicalAliasSource = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "field V_i"
  , "field q : scalar"
  , "step:"
  , "  q' = (if True then δ else δ) V"
  ]

rawShadowSource :: String
rawShadowSource = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "field A : 1-form"
  , "def hodge X = X"
  , "def wrapped X ="
  , "  let Y := X"
  , "   in hodge Y"
  , "step:"
  , "  A' = wrapped A"
  ]

formZeroScalarMixSource :: String
formZeroScalarMixSource = unlines
  [ "mode dec"
  , "dimension 1"
  , "axes x"
  , "field A : 0-form @ primal"
  , "field q : scalar"
  , "step:"
  , "  q' = `(∂_x (A + 0))"
  ]

scalarDeltaIdentitySource :: String
scalarDeltaIdentitySource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "field q : scalar"
  , "step:"
  , "  q' = 0 - δ (d u)"
  , "  u' = u"
  ]

scalarLocalMismatchSource :: String
scalarLocalMismatchSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field V_i"
  , "field u : scalar"
  , "step:"
  , "  local q = V"
  , "  u' = `(∂_x q)"
  ]

formLocalMismatchSource :: String
formLocalMismatchSource = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "field V_i"
  , "field A : 2-form"
  , "step:"
  , "  local q : 1-form @ primal = V"
  , "  A' = d q"
  ]

dotShadowKindSource :: String
dotShadowKindSource = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "field u : scalar"
  , "field V_i"
  , "field q : scalar"
  , "def (.) lhs rhs = V"
  , "step:"
  , "  q' = δ (u . u)"
  ]

nestedTraversalSource :: String -> String
nestedTraversalSource expression = unlines
  [ "mode collocated"
  , "dimension 2"
  , "axes x, y"
  , "field V_i"
  , "step:"
  , "  V'_i = " ++ expression
  ]

canonicalFunctionTraversalSource :: String -> String
canonicalFunctionTraversalSource expression = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "field V_i"
  , "step:"
  , "  V'_i = " ++ expression
  ]

updateKindMismatchSource :: String
updateKindMismatchSource = unlines
  [ "mode dec"
  , "dimension 1"
  , "axes x"
  , "field A : 0-form @ primal"
  , "field u : scalar"
  , "field v : scalar"
  , "step:"
  , "  u' = A"
  , "  v' = `(∂_x u')"
  ]

initializerKindMismatchSource :: String
initializerKindMismatchSource = unlines
  [ "mode dec"
  , "dimension 1"
  , "axes x"
  , "field A : 0-form @ primal"
  , "field u : scalar"
  , "init:"
  , "  u := A"
  , "step:"
  , "  u' = u"
  , "  A' = A"
  ]

formUpdateFromScalarSource :: String
formUpdateFromScalarSource = unlines
  [ "mode dec"
  , "dimension 1"
  , "axes x"
  , "field A : 0-form @ primal"
  , "step:"
  , "  A' = 0"
  ]

metricKindMismatchSource :: String
metricKindMismatchSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field V_i"
  , "metric scale [V]"
  , "step:"
  , "  V'_i = V_i"
  ]

metricCanonicalOperandSource :: String
metricCanonicalOperandSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field V_i"
  , "metric scale [Δ V]"
  , "step:"
  , "  V'_i = V_i"
  ]

genericGeometryQuoteSource :: String
genericGeometryQuoteSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "metric scale [`(1 + x)]"
  , "step:"
  , "  u' = u"
  ]

rawGeometryCanonicalSource :: String
rawGeometryCanonicalSource = unlines
  [ "mode dec"
  , "dimension 1"
  , "axes x"
  , "field A : 0-form @ primal"
  , "metric scale [`(hodge A)]"
  , "step:"
  , "  A' = A"
  ]

embeddingCanonicalValueSource :: String
embeddingCanonicalValueSource = unlines
  [ "mode dec"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "embedding [δ]"
  , "step:"
  , "  u' = u"
  ]

continuumDDKindMismatchSource :: String
continuumDDKindMismatchSource = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "field V_i"
  , "assert-dd-zero V"
  , "step:"
  , "  V'_i = V_i"
  ]

continuumDDTopDegreeSource :: String
continuumDDTopDegreeSource = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "field A : 1-form @ primal"
  , "assert-dd-zero A"
  , "step:"
  , "  A' = A"
  ]

symbolicPiSource :: String
symbolicPiSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "embedding [sin π + x]"
  , "field u : scalar"
  , "init:"
  , "  u := cos π"
  , "step:"
  , "  u' = u + π * Δ u"
  ]

validSource :: String
validSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "field V_i"
  , "step:"
  , "  let squared = u * u"
  , "  let energy = withSymbols [i] (V~i . V_i)"
  , "  local mu = Δ u"
  , "  u' = u + `(∂_x squared) + `(∂_x energy) + mu"
  , "  V'_i = V_i"
  ]

assertLeft
  :: String
  -> String
  -> Either OperatorTypeError value
  -> IO ()
assertLeft label expected result = case result of
  Left problem -> assertEqual label expected (operatorTypeErrorMessage problem)
  Right _ -> fail (label ++ ": expected rejection")

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
