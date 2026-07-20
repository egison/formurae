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

  -- The static layer tracks only scalar versus tensor: form-degree checks
  -- (non-form operands, top-degree d) happen during normalization from the
  -- value's dfOrder, so these operands pass the static layer.
  codiffTensor <- model "codiff-tensor" codiffTensorSource
  assertEqual "codifferential defers form checks to normalization"
    (Right ()) (validateModelOperatorTypes codiffTensor)

  topDegree <- model "top-degree" topDegreeSource
  assertEqual "top-degree d defers to the normalization guard"
    (Right ()) (validateModelOperatorTypes topDegree)

  unknownDefinition <- model "unknown-definition" unknownDefinitionSource
  assertLeft "untyped helper parameters cannot hide a scalar-only boundary"
    "scalar Δ requires a statically known scalar operand; untyped definition parameters cannot cross this operator boundary"
    (validateModelOperatorTypes unknownDefinition)

  rawDefinition <- model "raw-definition" rawDefinitionSource
  assertLeft "raw Egison cannot bypass typed canonical operands"
    "canonical hodge cannot be used inside an untyped raw Egison definition; apply it to a declared field, typed local, or structured step expression"
    (validateModelOperatorTypes rawDefinition)

  shadowedIntrinsic <- model "shadowed-intrinsic" shadowedIntrinsicSource
  assertEqual "form operators accept statically unknown operands"
    (Right ()) (validateModelOperatorTypes shadowedIntrinsic)

  rankUnknownDivergence <- model "rank-unknown-divergence"
    rankUnknownDivergenceSource
  assertEqual "form operators accept rank-unknown operands"
    (Right ()) (validateModelOperatorTypes rankUnknownDivergence)

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

  -- A 0-form is a rank-zero value, so at scalar/tensor granularity it may
  -- cross scalar-only operator boundaries.
  formZeroScalarMix <- model "form-zero-scalar-mix" formZeroScalarMixSource
  assertEqual "0-forms check as scalars"
    (Right ()) (validateModelOperatorTypes formZeroScalarMix)

  scalarDeltaIdentity <- model "scalar-delta-identity"
    scalarDeltaIdentitySource
  assertEqual "the exact collocated scalar Delta identity remains scalar"
    (Right ()) (validateModelOperatorTypes scalarDeltaIdentity)

  scalarLocalMismatch <- model "scalar-local-mismatch"
    scalarLocalMismatchSource
  assertLeft "scalar locals reject a known tensor RHS"
    "local q declares scalar, but its RHS has ordinary tensor kind"
    (validateModelOperatorTypes scalarLocalMismatch)

  -- Both sides are tensors at this granularity; the declared degree is
  -- validated against the value's dfOrder at the encode boundary.
  formLocalMismatch <- model "form-local-mismatch" formLocalMismatchSource
  assertEqual "form locals defer degree checks to the encode boundary"
    (Right ()) (validateModelOperatorTypes formLocalMismatch)

  dotShadow <- model "dot-shadow-kind" dotShadowKindSource
  assertEqual "form operators accept shadowed-dot operands"
    (Right ()) (validateModelOperatorTypes dotShadow)

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
  assertEqual "a 0-form updates a scalar field at this granularity"
    (Right ()) (validateModelOperatorTypes updateKindMismatch)

  initializerKindMismatch <- model "initializer-kind-mismatch"
    initializerKindMismatchSource
  assertEqual "a 0-form initializes a scalar field at this granularity"
    (Right ()) (validateModelOperatorTypes initializerKindMismatch)

  formUpdateFromScalar <- model "form-update-from-scalar"
    formUpdateFromScalarSource
  assertEqual "a scalar may initialize a declared 0-form update"
    (Right ()) (validateModelOperatorTypes formUpdateFromScalar)

  metricKindMismatch <- model "metric-kind-mismatch"
    metricKindMismatchSource
  assertLeft "metric scale factors require scalar expressions"
    "metric scale expression requires a scalar value, but received ordinary tensor"
    (validateModelOperatorTypes metricKindMismatch)

  -- Canonical Δ/δ on declared geometry are prelude macros, so their use
  -- inside metric/embedding expressions is rejected during parsing;
  -- tests/pre_static_diagnostic_cli.sh covers those messages.
  genericGeometryQuote <- model "generic-geometry-quote"
    genericGeometryQuoteSource
  assertEqual "generic CAS quotes remain valid in geometry expressions"
    (Right ()) (validateModelOperatorTypes genericGeometryQuote)

  rawGeometryCanonical <- model "raw-geometry-canonical"
    rawGeometryCanonicalSource
  assertLeft "raw geometry fallback cannot hide a canonical operator"
    "canonical hodge cannot be used inside an untyped metric scale expression; rewrite it as a structured expression"
    (validateModelOperatorTypes rawGeometryCanonical)

  symbolicPi <- model "symbolic-pi" symbolicPiSource
  assertEqual "symbolic pi is a statically known scalar"
    (Right ()) (validateModelOperatorTypes symbolicPi)

  valid <- model "valid" validSource
  assertEqual "typed fields and prior scalar local aliases are accepted"
    (Right ()) (validateModelOperatorTypes valid)

  putStrLn "formurae-pre canonical operator kind tests: ok"

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
