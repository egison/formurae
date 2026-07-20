module Main where

import Data.List (isInfixOf)

import Formurae.FEIR.Syntax (PrimitiveManifestId(..))
import Formurae.Pre.EmitEgison
import Formurae.Pre.Parse (parseModel)

main :: IO ()
main = do
  model <- parseModel "pre-emit.fme" "pre-emit" source
  first <- requireRight =<< emitNormalizationUnit manifestId model
  second <- requireRight =<< emitNormalizationUnit manifestId model

  assertEqual "normalization unit is deterministic" first second
  assertContains "shared operators read the generated ambient environment"
    "def FormuraeInternalLap u := Formurae.lap u" first
  assertAbsent first "def FormuraeInternalGrad u :="
  assertAbsent first "Formurae.operatorContext"
  assertAbsent first "feOperatorContext"
  assertAbsent first "FormuraeInternalContext"
  assertContains "user definition receives only its surface parameters"
    "FormuraeInternalDefinition3 u" first
  assertContains "user definitions remain ordinary Egison functions"
    "def FormuraeInternalDefinition1 f u := withSymbols"
    first
  assertContains "prior higher-order user definition receives the ambient operator"
    "FormuraeInternalDefinition1 FormuraeInternalLap u"
    first
  assertContains "indexed derivative contracts repeated indices"
    "contractWith (+) (FormuraeInternalDiff X~i)..._i" first
  assertContains "indexed derivative bridges to per-axis grid requests"
    "def FormuraeInternalDiff value := Formurae.gridDiff value" first
  assertContains "ordered coordinate derivative is a centered radius-one request"
    "FormuraeInternalCoordinateWideDerivative 1 2 1 u" first
  assertContains "surface ∂/∂ is the analytic coordinate derivative"
    "∂/∂ (∂/∂ u x) x" first
  assertContains "∂/∂ by the ambient coordinates vector stays analytic"
    "∂/∂ u coordinates" first
  assertContains "unprimed coordinate derivative preserves the whole nonlinear operand"
    "FormuraeInternalGridWholeDerivative 1 ((u * u) / 2)"
    first
  assertContains "nested quoted derivatives preserve their ordered chain"
    "FormuraeInternalOrderedDerivative [| 1, 1 |] u"
    first
  assertContains "wide derivative is a versioned opaque constructor"
    "FormuraeInternalCoordinateWideDerivative 1 2 2 u"
    first
  assertContains "canonical scalar Delta resolves to its scalar lowering"
    "FormuraeInternalScalarDelta u" first
  assertContains "constant scalar Delta uses the continuum identity"
    "def FormuraeInternalScalarDelta u := Formurae.scalarLaplacian u"
    first
  aliasModel <- parseModel "pre-dec-alias.fme" "pre-dec-alias" decAliasSource
  aliasUnit <- requireRight =<< emitNormalizationUnit manifestId aliasModel
  assertContains "canonical d resolves to the shared exterior derivative"
    "FormuraeInternalD X" aliasUnit

  variableScalarModel <- parseModel "pre-variable-scalar-delta.fme"
    "pre-variable-scalar-delta" variableScalarSource
  variableScalarUnit <- requireRight =<<
    emitNormalizationUnit manifestId variableScalarModel
  -- Canonical Δ on declared geometry is a prelude macro: the weighted flux
  -- is materialized by deferred locals and the signed adjoint divergence
  -- closes the conservative form.  The lb.orthogonal request is gone.
  assertContains "variable Delta materializes the flux weights"
    "def FormuraeInternalDFluxWeights A := Formurae.dFluxWeightsWith"
    variableScalarUnit
  assertContains "variable Delta closes with the adjoint divergence"
    "def FormuraeInternalDFluxDiv w := Formurae.dFluxDivWith"
    variableScalarUnit
  assertContains "the lifted flux locals read back as deferred fields"
    "FormuraeInternalDeferredView" variableScalarUnit
  assertAbsent variableScalarUnit "Formurae.lbOrthogonal"
  assertAbsent variableScalarUnit "FormuraeInternalCodiff"

  variableCodiffModel <- parseModel "pre-variable-codiff.fme"
    "pre-variable-codiff" variableCodiffSource
  variableCodiffUnit <- requireRight =<<
    emitNormalizationUnit manifestId variableCodiffModel
  assertContains "variable DEC delta materializes the flux weights"
    "def FormuraeInternalDFluxWeights A := Formurae.dFluxWeightsWith"
    variableCodiffUnit
  assertContains "variable DEC delta closes with the adjoint divergence"
    "def FormuraeInternalDFluxDiv w := Formurae.dFluxDivWith"
    variableCodiffUnit
  assertAbsent variableCodiffUnit "Formurae.metricCodiff"

  constantHodgeModel <- parseModel "pre-constant-hodge-laplacian.fme"
    "pre-constant-hodge-laplacian" constantHodgeSource
  constantHodgeUnit <- requireRight =<<
    emitNormalizationUnit manifestId constantHodgeModel
  assertContains "constant Delta_H lowers to the general Hodge-Laplacian identity"
    "def FormuraeInternalHodgeLaplacian A := Formurae.hodgeLaplacian A"
    constantHodgeUnit
  assertContains "canonical Delta_H call uses its atomic bridge"
    "FormuraeInternalHodgeLaplacian A" constantHodgeUnit

  variableHodgeModel <- parseModel "pre-variable-hodge-laplacian.fme"
    "pre-variable-hodge-laplacian" variableHodgeSource
  variableHodgeResult <- emitNormalizationUnit manifestId variableHodgeModel
  assertLeft "variable Delta_H has an explicit source-level diagnostic"
    isVariableHodgeLaplacian variableHodgeResult

  collocatedDeltaModel <- parseModel "pre-collocated-codiff.fme"
    "pre-collocated-codiff" collocatedCodiffSource
  collocatedDeltaResult <- emitNormalizationUnit manifestId collocatedDeltaModel
  assertLeft "canonical delta is rejected outside DEC mode"
    (isModeMessage "canonical δ requires mode dec") collocatedDeltaResult
  decScalarModel <- parseModel "pre-dec-scalar-delta.fme"
    "pre-dec-scalar-delta" decScalarSource
  decScalarResult <- emitNormalizationUnit manifestId decScalarModel
  assertLeft "canonical scalar Delta is rejected in DEC mode"
    (isModeMessage
      "canonical scalar Δ requires mode collocated; use Δ_H for differential forms")
    decScalarResult

  canonicalShadowModel <- parseModel "pre-canonical-shadow.fme"
    "pre-canonical-shadow" canonicalShadowSource
  canonicalShadowUnit <- requireRight =<<
    emitNormalizationUnit manifestId canonicalShadowModel
  assertContains "user delta and d definitions prevent scalar-identity fusion"
    "FormuraeInternalDefinition1 (FormuraeInternalDefinition2 u)"
    canonicalShadowUnit
  assertAbsent canonicalShadowUnit "FormuraeInternalScalarDelta"

  -- A near-miss of the exact scalar-Δ identity is not fused; on declared
  -- geometry the δ prelude macro expands instead, in any mode.
  nearMissModel <- parseModel "pre-canonical-near-miss.fme"
    "pre-canonical-near-miss" canonicalNearMissSource
  nearMissUnit <- requireRight =<<
    emitNormalizationUnit manifestId nearMissModel
  assertContains "a near-miss identity expands the codifferential macro"
    "def FormuraeInternalDFluxDiv w := Formurae.dFluxDivWith" nearMissUnit
  assertAbsent nearMissUnit "FormuraeInternalScalarDelta"

  kroneckerModel <- parseModel "pre-kronecker-delta.fme"
    "pre-kronecker-delta" kroneckerSource
  kroneckerUnit <- requireRight =<<
    emitNormalizationUnit manifestId kroneckerModel
  assertContains "marked delta remains the ordinary indexed Kronecker tensor"
    "FormuraeInternalKroneckerDelta~i_j . X~j" kroneckerUnit
  assertAbsent kroneckerUnit "FormuraeInternalCodiff"

  assertContains "stable registry fingerprint"
    "FEIR.atom \"registry-id\", FEIR.string \"sha256:" first
  assertContains "single canonical FEIR output"
    "print (FEIR.render feProgram)" first

  epsilonModel <- parseModel "pre-epsilon.fme" "pre-epsilon" epsilonSource
  epsilonUnit <- requireRight =<< emitNormalizationUnit manifestId epsilonModel
  assertContains "an indexed epsilon use requests the ambient Levi-Civita tensor"
    "def epsilon : Tensor Integer := ε dimension" epsilonUnit

  operatorModel <- parseModel "pre-user-operator.fme" "pre-user-operator"
    userOperatorSource
  operatorUnit <- requireRight =<< emitNormalizationUnit manifestId operatorModel
  assertContains "free covariant result remains anonymous"
    "withSymbols [i, j, k, l, m, n] (withSymbols [i, j, k]"
    operatorUnit
  assertAbsent operatorUnit "Formurae.attachExplicitVariances"

  raisedResultModel <- parseModel "pre-raised-result.fme" "pre-raised-result"
    raisedResultSource
  raisedResultUnit <- requireRight =<<
    emitNormalizationUnit manifestId raisedResultModel
  assertContains "definition bodies are emitted without result-provenance analysis"
    "withSymbols [i, j] (g~i~j . A_j)"
    raisedResultUnit
  assertAbsent raisedResultUnit "FormuraeInternalValidateDefinitionResult"

  mixedResultModel <- parseModel "pre-mixed-result.fme" "pre-mixed-result"
    mixedResultSource
  mixedResultUnit <- requireRight =<<
    emitNormalizationUnit manifestId mixedResultModel
  assertContains "mixed index expressions remain ordinary Egison bodies"
    "withSymbols [i, j, k] (g~i~j . A_j . B_k)"
    mixedResultUnit

  rawRaisedSource <- readFile
    "tests/fixtures/pre_user_result_variance_raw_error.fme"
  rawRaisedModel <- parseModel
    "tests/fixtures/pre_user_result_variance_raw_error.fme"
    "pre-raised-result-raw" rawRaisedSource
  rawRaisedUnit <- requireRight =<<
    emitNormalizationUnit manifestId rawRaisedModel
  assertContains "multiline Egison bodies are emitted without a result contract"
    "let raised := withSymbols [i, j] (g~i~j . A_j)"
    rawRaisedUnit
  assertAbsent rawRaisedUnit "FormuraeInternalValidateDefinitionResult"

  rawPrimitiveSource <- readFile
    "tests/fixtures/pre_user_result_variance_raw_primitive.fme"
  rawPrimitiveModel <- parseModel
    "tests/fixtures/pre_user_result_variance_raw_primitive.fme"
    "pre-raised-result-raw-primitive" rawPrimitiveSource
  rawPrimitiveUnit <- requireRight =<<
    emitNormalizationUnit manifestId rawPrimitiveModel
  assertContains "an Egison scalar reducer may consume a temporary index view"
    "norm2 raised" rawPrimitiveUnit

  rawNearMissSource <- readFile
    "tests/fixtures/pre_user_result_variance_raw_near_miss.fme"
  rawNearMissModel <- parseModel
    "tests/fixtures/pre_user_result_variance_raw_near_miss.fme"
    "pre-raised-result-raw-near-miss" rawNearMissSource
  _ <- requireRight =<< emitNormalizationUnit manifestId rawNearMissModel

  scalarReducerSource <- readFile
    "tests/fixtures/pre_user_result_scalar_reducer.fme"
  scalarReducerModel <- parseModel
    "tests/fixtures/pre_user_result_scalar_reducer.fme"
    "pre-result-scalar-reducer" scalarReducerSource
  scalarReducerUnit <- requireRight =<<
    emitNormalizationUnit manifestId scalarReducerModel
  assertContains "a scalar reducer consumes its argument's upper index view"
    "norm2 (withSymbols [i, j] (g~i~j . A_j))"
    scalarReducerUnit
  assertContains "vector divg consumes a temporary raised vector"
    "FormuraeInternalDivg (withSymbols [i, j] (g~i~j . A_j))"
    scalarReducerUnit

  rawPreservedSource <- readFile
    "tests/fixtures/pre_user_result_variance_raw_preserved.fme"
  rawPreservedModel <- parseModel
    "tests/fixtures/pre_user_result_variance_raw_preserved.fme"
    "pre-result-variance-raw-preserved" rawPreservedSource
  rawPreservedUnit <- requireRight =<<
    emitNormalizationUnit manifestId rawPreservedModel
  assertContains "multiline Egison may return an existing tensor unchanged"
    "let result := X"
    rawPreservedUnit
  assertAbsent rawPreservedUnit "FormuraeInternalValidateDefinitionResult"

  preservedResultSource <- readFile
    "tests/fixtures/pre_user_result_variance_preserved.fme"
  preservedResultModel <- parseModel
    "tests/fixtures/pre_user_result_variance_preserved.fme"
    "pre-result-variance-preserved" preservedResultSource
  preservedResultUnit <- requireRight =<<
    emitNormalizationUnit manifestId preservedResultModel
  assertContains "a whole upper input may be returned unchanged"
    "withSymbols [i, j, k, l, m, n] (X)"
    preservedResultUnit
  assertContains "whole mixed-variance scaling remains ordinary Egison"
    "withSymbols [i, j, k, l, m, n] (2 * T)"
    preservedResultUnit
  assertContains "a declared scalar parameter may scale a tensor"
    "withSymbols [i, j, k, l, m, n] (alpha * X)"
    preservedResultUnit
  assertContains "a declared scalar field may scale a tensor"
    "withSymbols [i, j, k, l, m, n] (c * X)"
    preservedResultUnit
  assertContains "pointwise lap remains an ordinary function application"
    "withSymbols [i, j, k, l, m, n] (FormuraeInternalLap X)"
    preservedResultUnit
  assertAbsent preservedResultUnit "FormuraeInternalDefinitionMetadataMatches"

  higherOrderSqrtSource <- readFile
    "tests/fixtures/pre_definition_higher_order_sqrt.fme"
  higherOrderSqrtModel <- parseModel
    "tests/fixtures/pre_definition_higher_order_sqrt.fme"
    "pre-definition-higher-order-sqrt" higherOrderSqrtSource
  higherOrderSqrtUnit <- requireRight =<<
    emitNormalizationUnit manifestId higherOrderSqrtModel
  assertContains "sqrt remains legal as a higher-order formal"
    "FormuraeInternalDefinition1 sqrt value"
    higherOrderSqrtUnit

  assertAbsent aliasUnit
    "def FormuraeInternalDefinition1 X := Formurae.attachExplicitVariances"

  mapM_ (assertAbsent first)
    [ "def dC "
    , "def dC2 "
    , "dYee"
    , "FMR."
    , "fieldEqs"
    , "storage"
    , "pd2r1"
    ]

  shadowModel <- parseModel "pre-shadow.fme" "pre-shadow" shadowSource
  shadowed <- requireRight =<< emitNormalizationUnit manifestId shadowModel
  assertContains "earlier user definition shadows the standard prelude"
    "withSymbols [i, j, k, l, m, n] (FormuraeInternalDefinition1 u)"
    shadowed
  assertAbsent shadowed "withSymbols [i, j, k, l, m, n] (FormuraeInternalLap u)"

  dotShadowModel <- parseModel "pre-dot-shadow.fme" "pre-dot-shadow" dotShadowSource
  dotShadowed <- requireRight =<< emitNormalizationUnit manifestId dotShadowModel
  assertContains "user dot is published with Egison operator syntax"
    "def (.) := FormuraeInternalDefinition1"
    dotShadowed
  assertContains "later definition resolves user dot without a hidden argument"
    "withSymbols [i, j, k, l, m, n] (FormuraeInternalDefinition1 a b)"
    dotShadowed

  conditionalSource <- readFile "tests/fixtures/pre_conditional.fme"
  conditionalModel <- parseModel "tests/fixtures/pre_conditional.fme"
    "formurae-pre-conditional" conditionalSource
  conditional <- requireRight =<< emitNormalizationUnit manifestId conditionalModel
  assertContains "surface if emits a symbolic canonical Select"
    "Formurae.select (Formurae.predicateOr" conditional
  assertContains "comparison and conjunction stay symbolic until FEIR"
    "Formurae.select (Formurae.predicateAnd (Formurae.predicateLt x threshold) (Formurae.predicateGe u 0))"
    conditional
  assertAbsent conditional "def FormuraeInternalValue1 := if"

  primitiveShadowModel <- parseModel "pre-primitive-shadow.fme"
    "pre-primitive-shadow" primitiveShadowSource
  primitiveShadowed <- requireRight =<< emitNormalizationUnit manifestId
    primitiveShadowModel
  assertContains "a removed surface name resolves an ordinary user definition"
    "withSymbols [i, j, k, l, m, n] (FormuraeInternalDefinition1(x))"
    primitiveShadowed
  assertContains "a parameter may reuse a removed surface name"
    "withSymbols [i, j, k, l, m, n] (materialize(x))"
    primitiveShadowed
  assertContains "the ordinary user definition remains a higher-order value"
    "def FormuraeInternalValue1 := applyShadow useMaterialize u"
    primitiveShadowed
  assertContains "a higher-order formal takes precedence over a prior definition"
    "withSymbols [i, j, k, l, m, n] (materialize(x))"
    primitiveShadowed
  assertAbsent primitiveShadowed "FormuraeInternalMaterialized x"

  parameterModel <- parseModel "pre-definition-parameters.fme"
    "pre-definition-parameters" parameterSource
  parameterUnit <- requireRight =<< emitNormalizationUnit manifestId parameterModel
  assertContains "rank-polymorphic marker emits one whole-value parameter"
    "def FormuraeInternalDefinition1 X := withSymbols"
    parameterUnit
  assertContains "fixed indexed parameter also binds the whole value"
    "def FormuraeInternalDefinition3 X :="
    parameterUnit
  assertContains "fixed indexed parameter checks whole-value metadata"
    "indexed parameter X_i metadata mismatch in fixedIdentity"
    parameterUnit
  assertContains "metadata-preserving tensor scaling remains a user function"
    "withSymbols [i, j, k, l, m, n] (2 * X)"
    parameterUnit
  assertContains "body append-index syntax is preserved"
    "withSymbols [i, j, k, l, m, n] (X..._i)"
    parameterUnit
  assertAbsent parameterUnit "Formurae.attachExplicitVariances"
  assertAbsent parameterUnit "FormuraeInternalDefinition2 X..."
  assertAbsent parameterUnit "FormuraeInternalDefinition3 X_i"

  quotedModel <- parseModel "pre-quoted-derivative.fme"
    "pre-quoted-derivative" quotedDerivativeSource
  quotedUnit <- requireRight =<< emitNormalizationUnit manifestId quotedModel
  assertContains "ordinary coordinate derivative is a placement-directed request"
    "FormuraeInternalGridWholeDerivative 1 (u * u)" quotedUnit
  assertContains "multi quoted derivative emits one ordered request"
    "FormuraeInternalOrderedDerivative [| 1, 1, 2 |] u" quotedUnit
  assertContains "generic quote remains raw Egison"
    "`(u * u)" quotedUnit

  sbpModel <- parseModel "pre-sbp.fme" "pre-sbp" sbpSource
  sbpUnit <- requireRight =<< emitNormalizationUnit manifestId sbpModel
  assertContains "declared sbp boundary reaches the axis registry"
    "FEIR.list [FEIR.atom \"boundary\", FEIR.list [FEIR.atom \"sbp\"]]"
    sbpUnit
  assertContains "plain first derivative stays the grid-whole request"
    "FormuraeInternalGridWholeDerivative 1 u" sbpUnit
  assertContains "plain second derivative stays the wide request"
    "FormuraeInternalCoordinateWideDerivative 1 2 1 u" sbpUnit
  assertAbsent sbpUnit "SbpStaggered"
  assertContains "the declaration supplies the wall threshold constant"
    "FEIR.string \"sbpLoX\"" sbpUnit
  assertContains "the declaration supplies the inverse boundary norm"
    "FEIR.string \"2.0/dx\"" sbpUnit
  assertContains "the wide spelling supplies its own inverse norm"
    "FEIR.string \"sbpHinv4X\"" sbpUnit
  assertContains "the Neumann macro expands to the boundary trace"
    "FormuraeInternalSbpTrace 1 (q)" sbpUnit
  assertContains "sbp trace bridge definition"
    "def FormuraeInternalSbpTrace axis value := Formurae.sbpTrace axis value"
    sbpUnit

  ghostModel <- parseModel "pre-ghost.fme" "pre-ghost" ghostBoundarySource
  ghostUnit <- requireRight =<< emitNormalizationUnit manifestId ghostModel
  assertContains "declared ghost boundary carries its fill value"
    "FEIR.list [FEIR.atom \"boundary\", FEIR.list [FEIR.atom \"ghost\", FEIR.string \"0.0\"]]"
    ghostUnit

  projectionModel <- parseModel "pre-projection.fme"
    "pre-projection" projectionSource
  projectionUnit <- requireRight =<< emitNormalizationUnit manifestId
    projectionModel
  assertContains "axis subscript projects the concrete vector component"
    "q_1" projectionUnit
  assertContains "axis subscripts project rank-2 components positionally"
    "T_1_2" projectionUnit
  assertAbsent projectionUnit "q_x"

  singleQuotedModel <- parseModel "pre-single-quoted.fme"
    "pre-single-quoted" singleQuotedSource
  assertLeft "a single quoted derivative is rejected as redundant"
    isSingleQuotedDerivative
    =<< emitNormalizationUnit manifestId singleQuotedModel

  upperLiteralModel <- parseModel "pre-upper-literal-result.fme"
    "pre-upper-literal-result" upperLiteralResultSource
  upperLiteralUnit <- requireRight =<<
    emitNormalizationUnit manifestId upperLiteralModel
  assertContains "definition result expressions are left to Egison"
    "[| u, u |]~i" upperLiteralUnit

  conservativeSource <- readFile
    "tests/fixtures/pre_conservative_local.fme"
  conservativeModel <- parseModel
    "tests/fixtures/pre_conservative_local.fme"
    "formurae-pre-conservative-local" conservativeSource
  conservativeUnit <- requireRight =<< emitNormalizationUnit manifestId
    conservativeModel
  assertContains "tensor literal remains structured through contextualization"
    "[| -kappa * FormuraeInternalGridWholeDerivative 1 u, -kappa * FormuraeInternalGridWholeDerivative 2 u |]_i"
    conservativeUnit
  assertAbsent conservativeUnit "def pack"

  invalidQuotedAxisModel <- parseModel "pre-invalid-quoted-axis.fme"
    "pre-invalid-quoted-axis" invalidQuotedAxisSource
  invalidQuotedAxis <- emitNormalizationUnit manifestId invalidQuotedAxisModel
  assertLeft "unknown quoted derivative coordinate is rejected"
    isUnknownQuotedCoordinate invalidQuotedAxis

  invalidQuotedVarianceModel <- parseModel "pre-invalid-quoted-variance.fme"
    "pre-invalid-quoted-variance" invalidQuotedVarianceSource
  invalidQuotedVariance <- emitNormalizationUnit manifestId
    invalidQuotedVarianceModel
  assertLeft "quoted derivative coordinate index must be covariant"
    isInvalidQuotedVariance invalidQuotedVariance

  invalidWideAxisModel <- parseModel "pre-invalid-wide-axis.fme"
    "pre-invalid-wide-axis" invalidWideAxisSource
  invalidWideAxis <- emitNormalizationUnit manifestId invalidWideAxisModel
  assertLeft "unknown wide derivative coordinate is rejected"
    isUnknownWideCoordinate invalidWideAxis

  invalidWideArityModel <- parseModel "pre-invalid-wide-arity.fme"
    "pre-invalid-wide-arity" invalidWideAritySource
  invalidWideArity <- emitNormalizationUnit manifestId invalidWideArityModel
  assertLeft "wide derivative arity is checked before Egison"
    isInvalidWideArity invalidWideArity

  ksSource <- readFile "examples/ks3d/ks3d.fme"
  ksModel <- parseModel "examples/ks3d/ks3d.fme" "ks3d" ksSource
  ksUnit <- requireRight =<< emitNormalizationUnit manifestId ksModel
  assertContains "ks3d uses the whole-expression grid derivative boundary"
    "FormuraeInternalGridWholeDerivative 1 ((u * u) / 2)"
    ksUnit

  yinYangSource <- readFile
    "examples/yinyang_diffusion/yinyang_diffusion.fme"
  yinYangModel <- parseModel
    "examples/yinyang_diffusion/yinyang_diffusion.fme"
    "yinyang-diffusion" yinYangSource
  yinYangUnit <- requireRight =<<
    emitNormalizationUnit manifestId yinYangModel
  assertContains "Yin-Yang keeps the symbolic theta origin through emission"
    "5 * π" yinYangUnit
  assertContains "Yin-Yang keeps the symbolic phi origin through emission"
    "19 * π" yinYangUnit
  assertAbsent yinYangUnit "6544984694978736"
  assertAbsent yinYangUnit "0.6544984694978736"

  decimalModel <- parseModel "pre-decimal-literal.fme"
    "pre-decimal-literal" decimalLiteralSource
  decimalUnit <- requireRight =<< emitNormalizationUnit manifestId decimalModel
  assertContains "embedding decimal literal becomes an exact rational"
    "[sin ((25 / 100) + x), cos ((25 / 100) + x), y]" decimalUnit
  assertContains "CAS initializer decimal and exponent literals become exact"
    "((15 / 10000) * cos ((25 / 100) + x)) + 2000" decimalUnit
  assertContains "definition decimal literal becomes an exact rational"
    "withSymbols [i, j, k, l, m, n] ((5 / 10) * u)" decimalUnit
  assertContains "exact binary64 denominator above 2^53 remains supported"
    "withSymbols [i, j, k, l, m, n] ((1 / 100000000000000000000) * u)"
    decimalUnit
  assertContains "integral decimal literal collapses to an integer"
    "(1 * u) + (dt * (0 - FormuraeInternalDFluxDiv deltaFlux))" decimalUnit
  assertContains "raw Egison definition body keeps its Float literal"
    "let y := u * 0.75 in y" decimalUnit
  assertAbsent decimalUnit "0.25"
  assertAbsent decimalUnit "1.5e-3"

  exponentAxisModel <- parseModel "pre-decimal-exponent-axis.fme"
    "pre-decimal-exponent-axis" decimalExponentAxisSource
  exponentAxisUnit <- requireRight =<<
    emitNormalizationUnit manifestId exponentAxisModel
  assertContains "leading-dot decimal and exponent lower before axis renaming"
    "def feGeometryEmbedding := [50 + 1000 * x]" exponentAxisUnit
  assertAbsent exponentAxisUnit "1x"
  assertAbsent exponentAxisUnit ".500"

  overflowingExponentModel <- parseModel "pre-decimal-overflow.fme"
    "pre-decimal-overflow" (unsafeDecimalSource "1e18446744073709551616")
  assertLeft "overflowing decimal exponent is rejected instead of wrapping"
    (isDecimalMessage "exponent outside the supported range")
    =<< emitNormalizationUnit manifestId overflowingExponentModel

  inexactBackendModel <- parseModel "pre-decimal-inexact-backend.fme"
    "pre-decimal-inexact-backend"
    (unsafeDecimalSource "0.10000000000015839")
  assertLeft "decimal with inexact backend division operands is rejected"
    (isDecimalMessage "without inexact numerator/denominator rounding")
    =<< emitNormalizationUnit manifestId inexactBackendModel
  putStrLn "formurae-pre Egison emitter tests: ok"

manifestId :: PrimitiveManifestId
manifestId = PrimitiveManifestId "sha256:test-manifest"

source :: String
source = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes r"
  , "discretization collocated derivative 2 centered accuracy 4"
  , "param alpha = 0.25"
  , "field u : scalar"
  , "def pass f u = f u"
  , "def indexed X = withSymbols [i] (∂_i X~i)"
  , "def smooth u = pass lap u + ∂^2_r u + ∂_r (u * u / 2)"
  , "def chain u = `(∂_r (`(∂_r u)))"
  , "def wide u = pd2r2_r u"
  , "def analytic u = ∂/∂ (∂/∂ u r) r"
  , "def analyticVec u = ∂/∂ u coordinates"
  , "def lapAlias u = Δ u"
  , "init:"
  , "  u = 0.0"
  , "step:"
  , "  u' = u + alpha * smooth u"
  ]

decAliasSource :: String
decAliasSource = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "field A : 1-form"
  , "def ext X = d X"
  , "step:"
  , "  A' = A"
  ]

variableScalarSource :: String
variableScalarSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "metric scale [1 + x]"
  , "field u : scalar @ primal"
  , "step:"
  , "  u' = u + Δ u"
  ]

variableCodiffSource :: String
variableCodiffSource = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "metric scale [1 + x, 1]"
  , "field A : 1-form"
  , "step:"
  , "  A' = δ A"
  ]

constantHodgeSource :: String
constantHodgeSource = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "field A : 1-form"
  , "def hodgeLap A = Δ_H A"
  , "step:"
  , "  A' = hodgeLap A"
  ]

variableHodgeSource :: String
variableHodgeSource = unlines
  [ "mode dec"
  , "dimension 2"
  , "axes x, y"
  , "metric scale [1 + x, 1]"
  , "field A : 1-form"
  , "def hodgeLap A = Δ_H A"
  , "step:"
  , "  A' = hodgeLap A"
  ]

collocatedCodiffSource :: String
collocatedCodiffSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "def co u = δ u"
  , "step:"
  , "  u' = co u"
  ]

decScalarSource :: String
decScalarSource = unlines
  [ "mode dec"
  , "dimension 1"
  , "axes x"
  , "field u : 0-form"
  , "def scalarLap u = Δ u"
  , "step:"
  , "  u' = scalarLap u"
  ]

canonicalShadowSource :: String
canonicalShadowSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "metric scale [1 + x]"
  , "field u : scalar"
  , "def δ x = x"
  , "def d x = x"
  , "def identity u = 0 - δ (d u)"
  , "step:"
  , "  u' = identity u"
  ]

canonicalNearMissSource :: String
canonicalNearMissSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "metric scale [1 + x]"
  , "field u : scalar @ primal"
  , "step:"
  , "  u' = 1 - δ (d u)"
  ]

kroneckerSource :: String
kroneckerSource = unlines
  [ "mode collocated"
  , "dimension 2"
  , "axes x, y"
  , "field X_i"
  , "def delta x = 0"
  , "step:"
  , "  X'_i = withSymbols [j] (δ~i_j . X~j)"
  ]

epsilonSource :: String
epsilonSource = unlines
  [ "mode collocated"
  , "dimension 3"
  , "axes x, y, z"
  , "field X_i"
  , "field Y_i"
  , "step:"
  , "  Y'_i = withSymbols [j, k] (epsilon_i~j~k . ∂_j X_k)"
  ]

userOperatorSource :: String
userOperatorSource = unlines
  [ "mode collocated"
  , "dimension 3"
  , "axes x, y, z"
  , "metric g"
  , "metric scale [1, 2, 3]"
  , "field X_i"
  , "field A_i"
  , "field Y_i"
  , "def curl X = withSymbols [i, j, k] (epsilon_i~j~k . ∂_j X_k)"
  , "step:"
  , "  Y' = curl X"
  ]

raisedResultSource :: String
raisedResultSource = unlines
  [ "mode collocated"
  , "dimension 2"
  , "axes x, y"
  , "metric g"
  , "field A_i"
  , "def raise A = withSymbols [i, j] (g~i~j . A_j)"
  , "step:"
  , "  A' = A"
  ]

mixedResultSource :: String
mixedResultSource = unlines
  [ "mode collocated"
  , "dimension 2"
  , "axes x, y"
  , "metric g"
  , "field A_i"
  , "field B_i"
  , "def mixed A B = withSymbols [i, j, k] (g~i~j . A_j . B_k)"
  , "step:"
  , "  A' = A"
  ]

shadowSource :: String
shadowSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "def lap u = u + 1"
  , "def use u = lap u"
  , "init:"
  , "  u = 0.0"
  , "step:"
  , "  u' = use u"
  ]

dotShadowSource :: String
dotShadowSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "def (.) a b = a + b"
  , "def combine a b = a . b"
  , "init:"
  , "  u = 0.0"
  , "step:"
  , "  u' = combine u 2"
  ]

primitiveShadowSource :: String
primitiveShadowSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "def materialize x = x + 1"
  , "def useMaterialize x = materialize(x)"
  , "def applyShadow materialize x = materialize(x)"
  , "step:"
  , "  u' = applyShadow useMaterialize u"
  ]

parameterSource :: String
parameterSource = unlines
  [ "mode collocated"
  , "dimension 2"
  , "axes x, y"
  , "field X_i"
  , "def rankIdentity X... = X"
  , "def appendIndex X... = X..._i"
  , "def fixedIdentity X_i = X"
  , "def scale X... = 2 * X"
  , "step:"
  , "  X' = scale (fixedIdentity (rankIdentity X))"
  ]

quotedDerivativeSource :: String
quotedDerivativeSource = unlines
  [ "mode collocated"
  , "dimension 2"
  , "axes r, s"
  , "field u : scalar"
  , "def ordinary u = d_r (u * u)"
  , "def quotedMulti u = `(d_s (`(d_r (`(d_r u)))))"
  , "def genericQuote u = `(u * u)"
  , "step:"
  , "  u' = ordinary u + quotedMulti u + genericQuote u"
  ]

sbpSource :: String
sbpSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "boundary x : sbp"
  , "field u : scalar @ primal"
  , "field v : scalar @ dual"
  , "step:"
  , "  local q @ dual = ∂'_x u"
  , "  v' = ∂_x u"
  , "  u' = u + ∂^2_x u + satNeumann_x(q, 0.0, 0.0)"
  ]

ghostBoundarySource :: String
ghostBoundarySource = unlines
  [ "mode collocated"
  , "dimension 2"
  , "axes x, y"
  , "boundary y : ghost 0.0"
  , "field u : scalar"
  , "step:"
  , "  u' = u"
  ]

projectionSource :: String
projectionSource = unlines
  [ "mode collocated"
  , "dimension 2"
  , "axes x, y"
  , "field u : scalar @ primal"
  , "field q_i @ primal"
  , "field T_i_j @ primal"
  , "init:"
  , "  u = 0.0"
  , "  q_i = [| 0.0, 0.0 |]_i"
  , "  T_i_j = [| [| 0.0, 0.0 |], [| 0.0, 0.0 |] |]_i_j"
  , "step:"
  , "  u' = u + q_x - T_x_y"
  , "  q' = q"
  , "  T' = T"
  ]

singleQuotedSource :: String
singleQuotedSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes r"
  , "field u : scalar"
  , "step:"
  , "  u' = `(d_r (u * u))"
  ]

upperLiteralResultSource :: String
upperLiteralResultSource = unlines
  [ "mode collocated"
  , "dimension 2"
  , "axes x, y"
  , "field u : scalar"
  , "def literal u = [| u, u |]~i"
  , "step:"
  , "  u' = u"
  ]

invalidQuotedAxisSource :: String
invalidQuotedAxisSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "step:"
  , "  u' = `(d_q u)"
  ]

invalidQuotedVarianceSource :: String
invalidQuotedVarianceSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "step:"
  , "  u' = `(d~x u)"
  ]

invalidWideAxisSource :: String
invalidWideAxisSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "step:"
  , "  u' = pd2r2_q u"
  ]

invalidWideAritySource :: String
invalidWideAritySource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "step:"
  , "  u' = pd2r2_x u u"
  ]

decimalLiteralSource :: String
decimalLiteralSource = unlines
  [ "mode collocated"
  , "dimension 2"
  , "axes x, y"
  , "param dt = 0.0003"
  , "embedding [ sin (0.25 + x), cos (0.25 + x), y ]"
  , "field u : scalar @ primal"
  , "def half u = 0.5 * u"
  , "def tiny u = 1e-20 * u"
  , "def rawQuarter u = let y := u * 0.75 in y"
  , "init:"
  , "  u := 1.5e-3 * cos (0.25 + x) + 2e3"
  , "step:"
  , "  u' = 1.0 * u + dt * Δ u"
  ]

decimalExponentAxisSource :: String
decimalExponentAxisSource = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes e3"
  , "embedding [ .5e2 + 1e3 * e3 ]"
  , "field u : scalar"
  , "init:"
  , "  u := 0"
  , "step:"
  , "  u' = u"
  ]

unsafeDecimalSource :: String -> String
unsafeDecimalSource literal = unlines
  [ "mode collocated"
  , "dimension 1"
  , "axes x"
  , "field u : scalar"
  , "init:"
  , "  u := " ++ literal
  , "step:"
  , "  u' = u"
  ]

requireRight :: Either EmitError a -> IO a
requireRight (Right value) = pure value
requireRight (Left err) = fail (show err)

assertContains :: String -> String -> String -> IO ()
assertContains label needle haystack
  | needle `isInfixOf` haystack = pure ()
  | otherwise = fail (label ++ ": missing " ++ show needle)

assertAbsent :: String -> String -> IO ()
assertAbsent haystack needle
  | needle `isInfixOf` haystack = fail ("unexpected generated text " ++ show needle)
  | otherwise = pure ()

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

isUnknownQuotedCoordinate :: EmitError -> Bool
isUnknownQuotedCoordinate problem =
  case problem of
    EmitAtSource _ nested -> isUnknownQuotedCoordinate nested
    EmitExpressionError message ->
      message == "quoted derivative uses unknown coordinate q"
    _ -> False

isSingleQuotedDerivative :: EmitError -> Bool
isSingleQuotedDerivative problem =
  case problem of
    EmitAtSource _ nested -> isSingleQuotedDerivative nested
    EmitExpressionError message ->
      "single quoted derivative" `isInfixOf` message
    _ -> False

isInvalidQuotedVariance :: EmitError -> Bool
isInvalidQuotedVariance problem =
  case problem of
    EmitAtSource _ nested -> isInvalidQuotedVariance nested
    EmitExpressionError message ->
      message == "quoted derivative coordinate index must be covariant: ~x"
    _ -> False

isUnknownWideCoordinate :: EmitError -> Bool
isUnknownWideCoordinate problem =
  case problem of
    EmitAtSource _ nested -> isUnknownWideCoordinate nested
    EmitExpressionError message -> message == "pd2r2 uses unknown coordinate q"
    _ -> False

isInvalidWideArity :: EmitError -> Bool
isInvalidWideArity problem =
  case problem of
    EmitAtSource _ nested -> isInvalidWideArity nested
    EmitExpressionError message ->
      message == "pd2r2 coordinate derivative needs one operand"
    _ -> False

isDecimalMessage :: String -> EmitError -> Bool
isDecimalMessage expected problem =
  case problem of
    EmitAtSource _ nested -> isDecimalMessage expected nested
    EmitExpressionError message -> expected `isInfixOf` message
    _ -> False

isVariableHodgeLaplacian :: EmitError -> Bool
isVariableHodgeLaplacian problem =
  case problem of
    EmitAtSource _ nested -> isVariableHodgeLaplacian nested
    EmitExpressionError message ->
      "canonical Δ_H is not supported for variable metric geometry"
        `isInfixOf` message
    _ -> False

isModeMessage :: String -> EmitError -> Bool
isModeMessage expected problem =
  case problem of
    EmitAtSource _ nested -> isModeMessage expected nested
    EmitExpressionError message -> message == expected
    _ -> False
