#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EGISON_DIR=${EGISON_DIR:-"$ROOT/../egison"}

compile_fme() {
  (cd "$ROOT" && cabal run -v0 fec -- "$1")
}

typecheck_generated() {
  printf '%s\n' "$1" |
    "$ROOT/tests/run_egison_strict.sh" "$EGISON_DIR" -t \
      -l "$ROOT/lib/formurae-grid.egi" \
      -l "$ROOT/lib/formurae-tensor.egi" \
      -l "$ROOT/lib/formurae-geometry.egi" \
      -l "$ROOT/lib/fmrgen.egi" \
      -l "$ROOT/lib/formurae-runtime.egi" /dev/stdin
}

run_generated() {
  printf '%s\n' "$1" |
    (cd "$EGISON_DIR" && cabal run -v0 egison -- \
      -l "$ROOT/lib/formurae-grid.egi" \
      -l "$ROOT/lib/formurae-tensor.egi" \
      -l "$ROOT/lib/formurae-geometry.egi" \
      -l "$ROOT/lib/fmrgen.egi" \
      -l "$ROOT/lib/formurae-runtime.egi" /dev/stdin)
}

tmp_fme() {
  mktemp "${TMPDIR:-/tmp}/formurae-fec-test.XXXXXX"
}

assert_contains() {
  haystack=$1
  needle=$2
  label=$3
  if ! printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null; then
    printf 'missing expected output for %s:\n%s\n' "$label" "$needle" >&2
    exit 1
  fi
}

assert_not_contains() {
  haystack=$1
  needle=$2
  label=$3
  if printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null; then
    printf 'unexpected output for %s:\n%s\n' "$label" "$needle" >&2
    exit 1
  fi
}

# Egison reports type failures with exit status 0, so the strict wrapper must
# turn diagnostics into a failing status.
set +e
strict_output=$(typecheck_generated 'def broken : Integer := missingValue' 2>&1)
strict_status=$?
set -e
if [ "$strict_status" -eq 0 ]; then
  printf 'strict Egison diagnostic wrapper unexpectedly accepted an unbound value\n' >&2
  exit 1
fi
assert_contains "$strict_output" 'Type error:' 'strict Egison diagnostics are fatal'

write_case() {
  file=$1
  shift
  : > "$file"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$file"
  done
}

span_output=$(
  cd "$ROOT"
  cabal exec -v0 runghc -- -ifec/src tests/fec_source_spans.hs
)
assert_contains "$span_output" 'fec source span tests: ok' 'offset-preserving tensor AST spans'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 3' \
  'axes x,y,z' \
  'field u : scalar' \
  'def grad u = withSymbols [i] ∂_i u' \
  'def div X = contractWith (+) (∂_i X~i)' \
  'def lap u = div (grad u)' \
  'init:' \
  '  u = 0.0' \
  'step:' \
  "  u' = lap u"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.partialChainTensor (feTensorDerivative Collocated Collocated) [] feAxisIds 2' 'lap = div grad keeps the second derivative tensor-valued'
assert_contains "$out" 'contractWith (+)' 'lap = div grad contracts in Egison'
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" 'u[i-1,j,k]/(dx**2)' 'runtime scalar contraction emits the x second-difference stencil'
assert_contains "$fmr" 'u[i,j-1,k]/(dy**2)' 'runtime scalar contraction emits the y second-difference stencil'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 3' \
  'axes x,y,z' \
  'field u : scalar' \
  'def lap u = contractWith (+) (∂_i ∂~i u)' \
  'init:' \
  '  u = 0.0' \
  'step:' \
  "  u' = lap u"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" ')_FormuraeInternalIndex1~FormuraeInternalIndex1' 'raised indexed derivative preserves its hygienic mixed diagonal indices'
assert_contains "$out" 'feAxisIds 2' 'raised indexed derivative passes the fused axis pair to Egison'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 3' \
  'axes x,y,z' \
  'metric g' \
  'field u : scalar' \
  'def Δ u = g~i~j . ∂_i ∂_j u' \
  'init:' \
  '  u = 0.0' \
  'step:' \
  "  u' = Δ u"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'def FormuraeInternalMetricContra := FE.metricTensor feDim' 'Euclidean metric is one shared runtime tensor'
assert_contains "$out" 'FormuraeInternalMetricContra~FormuraeInternalIndex1~FormuraeInternalIndex2' 'metric dot laplacian keeps hygienic metric indices'
assert_contains "$out" 'feAxisIds 2' 'metric dot laplacian keeps the fused derivative tensor'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'metric g' \
  'metric scale [1, 2]' \
  'field A_j' \
  'field B~i' \
  'step:' \
  "  B'~i = g~i~j . A_j"
out=$(compile_fme "$f")
rm -f "$f"
typecheck_generated "$out"
assert_contains "$out" 'def FormuraeInternalMetricContra := FE.inverseDiagonalMetricTensor feDim feH' 'non-Euclidean contravariant metric uses shared geometry'
assert_not_contains "$out" 'def FormuraeInternalMetricCov :=' 'unused covariant metric is not emitted'
assert_not_contains "$out" 'def FormuraeInternalMetricMixedUpDown :=' 'unused mixed metric is not emitted'
assert_not_contains "$out" 'def FormuraeInternalMetricMixedDownUp :=' 'unused reverse mixed metric is not emitted'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'metric g' \
  'metric scale [1, 2]' \
  'field u : scalar' \
  'step:' \
  "  u' = u"
out=$(compile_fme "$f")
rm -f "$f"
assert_not_contains "$out" 'def feH ' 'unused direct metric scale helper is omitted'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes r,phi' \
  'def Δ u = lb u' \
  'embedding [ `(1 + r) * cos phi, `(1 + r) * sin phi ]' \
  'field u : scalar' \
  'step:' \
  "  u' = Δ u"
out=$(compile_fme "$f")
rm -f "$f"
typecheck_generated "$out"
assert_contains "$out" 'def feG (a: Integer) (b: Integer) : MathValue :=' 'embedding metric helper is unified'
assert_contains "$out" 'def feH (a: Integer) : MathValue := sqrt (feG a a)' 'embedding scale helper is unified'
assert_contains "$out" 'def feG (a: Integer) (b: Integer) : MathValue := FE.inducedMetric feCoords feX a b' 'induced metric is evaluated by shared geometry'
assert_contains "$out" 'def feSqrtG : MathValue := FE.orthogonalVolume feAxisIds feH' 'embedding volume factor is shared'
assert_contains "$out" 'FE.orthogonalHodgeCoefficient feAxisIds feH [1]' 'Hodge coefficient is evaluated by shared geometry'
assert_contains "$out" 'FE.lbFromFluxes feAxisIds feLbDivergence feLbStoredFlux sg' 'Laplace-Beltrami divergence is evaluated by shared geometry'
assert_contains "$out" 'FE.lbFlux feLbGradient feLbCoefficient axis u' 'Laplace-Beltrami flux is evaluated by shared geometry'
assert_contains "$out" 'nth axis [f1, f2]' 'Laplace-Beltrami divergence reads the materialized flux fields'
assert_not_contains "$out" 'feSqrtG / ((feH' 'generated code has no hand-written Hodge coefficient formula'
assert_contains "$out" 'feG 1 2 = 0' 'embedding orthogonality gate uses unified metric'
assert_contains "$out" 'extern function :: sin' 'embedding intrinsic sin is detected'
assert_contains "$out" 'extern function :: cos' 'embedding intrinsic cos is detected'
assert_contains "$out" 'extern function :: sqrt' 'derived embedding sqrt is declared'
assert_not_contains "$out" 'feGd' 'old diagonal metric helper is absent'
assert_not_contains "$out" 'feGo' 'old off-diagonal metric helper is absent'
assert_not_contains "$out" 'unquoteAll' 'quote cleanup workaround is absent'
assert_not_contains "$out" 'expandAll' 'eager metric expansion is absent'
assert_not_contains "$out" 'def shift ' 'embedding derivatives do not pull in finite-difference helpers'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'def Δ u = lb u' \
  'embedding [sin x]' \
  'field u : scalar' \
  'init:' \
  '  u := 0' \
  'step:' \
  "  u' = Δ u"
out=$(compile_fme "$f")
rm -f "$f"
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$out" 'extern function :: cos' 'embedding derivative dependency is declared'
assert_contains "$fmr" 'extern function :: cos' 'derived embedding function reaches Formura helpers'
assert_contains "$fmr" 'cos(' 'derived embedding function reaches Formura expressions'
assert_contains "$fmr" 'f1 =' 'Laplace-Beltrami flux is materialized before the update'
assert_contains "$fmr" "u' =" 'Laplace-Beltrami update is emitted'
assert_contains "$fmr" 'f1[' 'Laplace-Beltrami update reads the materialized flux'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'embedding [sin x, y]' \
  'field u : scalar' \
  'step:' \
  "  u' = u"
out=$(compile_fme "$f")
rm -f "$f"
typecheck_generated "$out"
assert_contains "$out" 'def feG (a: Integer) (b: Integer) : MathValue :=' 'embedding metric remains available without lb'
assert_contains "$out" 'extern function :: sin' 'embedding-only intrinsic is detected'
assert_contains "$out" 'def feInits := []' 'empty initializer list is valid Egison'
assert_not_contains "$out" 'def feH ' 'unused embedding scale helper is omitted'
assert_not_contains "$out" 'extern function :: sqrt' 'unused derived sqrt helper is omitted'
assert_not_contains "$out" 'def shift ' 'embedding-only model omits finite-difference helpers'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'metric g' \
  'embedding [2 * x, 3 * y]' \
  'field A_j' \
  'field B~i' \
  'step:' \
  "  B'~i = g~i~j . A_j"
out=$(compile_fme "$f")
rm -f "$f"
typecheck_generated "$out"
assert_contains "$out" 'def FormuraeInternalMetricContra := FE.metricTensor feDim (\i j -> if i = j then 1 / (feG i i) else 0)' 'embedding contravariant metric uses shared metric helper'
assert_not_contains "$out" 'def feH ' 'indexed embedding metric does not need scale factors'
assert_not_contains "$out" 'extern function :: sqrt' 'indexed embedding metric does not need sqrt'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'field u : scalar' \
  'init:' \
  '  u = 0.0'
out=$(compile_fme "$f")
rm -f "$f"
typecheck_generated "$out"
assert_contains "$out" 'def feSteps := []' 'empty step list is valid Egison'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'field u : scalar' \
  'step:' \
  "  u' = 1 + lb u"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
if [ "$status" -eq 0 ]; then
  rm -f "$f"
  printf 'lb without metric unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" "$f:6:12-15" 'direct backend request maps to the original fme line and columns'
rm -f "$f"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'def twice x = x + x' \
  'field u : scalar' \
  'step:' \
  "  u' = twice 123456789 + lb u"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
if [ "$status" -eq 0 ]; then
  rm -f "$f"
  printf 'expanded lb without metric unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" "$f:7:26-29" 'direct request keeps its exact source span after unrelated definition expansion'
assert_not_contains "$out" 'expanded-expression columns' 'expanded expressions no longer fall back to translated columns'
rm -f "$f"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'param α = 1' \
  'def op q = α + lb q' \
  'field u : scalar' \
  'step:' \
  "  u' = op u"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
if [ "$status" -eq 0 ]; then
  rm -f "$f"
  printf 'source-mapped user definition unexpectedly succeeded without a metric\n' >&2
  exit 1
fi
assert_contains "$out" "$f:5:16-19" 'definition-body request uses pre-transliteration source columns'
assert_contains "$out" "in expansion of op (defined at $f:5:12-19, called at $f:8:8-11)" 'user definition diagnostic includes definition and call sites'
rm -f "$f"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'def inner q = lb q' \
  'def outer q = 1 + inner q' \
  'field u : scalar' \
  'step:' \
  "  u' = outer u"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
if [ "$status" -eq 0 ]; then
  rm -f "$f"
  printf 'nested source-mapped definitions unexpectedly succeeded without a metric\n' >&2
  exit 1
fi
assert_contains "$out" "$f:4:15-18" 'nested request retains its innermost definition span'
assert_contains "$out" "in expansion of inner (defined at $f:4:15-18, called at $f:5:19-25)" 'nested trace includes the inner definition call'
assert_contains "$out" "in expansion of outer (defined at $f:5:15-25, called at $f:8:8-14)" 'nested trace includes the outer step call'
rm -f "$f"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'def Δ q = lb q' \
  'metric scale [1, 1]' \
  'field u : scalar' \
  'field v : scalar' \
  'step:' \
  "  u' = Δ u" \
  "  v' = Δ v"
out=$(compile_fme "$f")
rm -f "$f"
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$out" 'def feLbResult : MathValue :=' 'first lb request result'
assert_contains "$out" 'def feLbResult2 : MathValue :=' 'second lb request result'
assert_contains "$out" 'def feLbFlux2 (axis: Integer)' 'second lb request flux function'
assert_contains "$out" 'FormuraeInternalLb2Flux1' 'second lb request owns a distinct flux bundle'
assert_contains "$fmr" 'f1 =' 'first lb flux is materialized'
assert_contains "$fmr" 'FormuraeInternalLb2Flux1 =' 'second lb flux is materialized'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'metric scale [1]' \
  'field u : scalar' \
  'field v : scalar' \
  'field V_i @ primal' \
  'step:' \
  "  u' = lb u" \
  "  v' = lb v" \
  "  V'_i = (lb v) * V_i"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'second collocated lb result unexpectedly mixed with a primal component\n' >&2
  exit 1
fi
assert_contains "$out" 'grid placement mismatch between operands' 'second lb result keeps collocated placement after lowering'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'metric scale [1]' \
  'field u : scalar' \
  'step:' \
  "  u' = 1 + 2 * lb (u)"
out=$(compile_fme "$f")
rm -f "$f"
typecheck_generated "$out"
assert_contains "$out" 'def feLbResult : MathValue :=' 'structural lb request result binding'
assert_contains "$out" '2 * feLbResult' 'nested and parenthesized lb lowering'
assert_not_contains "$out" 'lb (u)' 'no unresolved parenthesized lb application'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'metric scale [1]' \
  'field u : scalar' \
  'field v : scalar' \
  'step:' \
  "  u' = lb (u + v)"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'compound lb argument unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'lb expects an unindexed scalar field argument' 'compound lb argument rejection'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'metric scale [1]' \
  'field u : scalar @ primal' \
  'step:' \
  "  u' = lb u"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'non-collocated lb source unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'lb currently requires a collocated scalar source' 'non-collocated lb source rejection'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'metric scale [1]' \
  'field u : scalar' \
  'field V_i @ primal' \
  'step:' \
  "  V'_i = (lb u) * V_i"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'collocated lb result unexpectedly mixed with a primal component\n' >&2
  exit 1
fi
assert_contains "$out" 'grid placement mismatch between operands' 'lb result keeps collocated placement after lowering'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'field u : scalar' \
  'def lb q = q' \
  'step:' \
  "  u' = lb u"
out=$(compile_fme "$f")
rm -f "$f"
typecheck_generated "$out"
assert_not_contains "$out" 'def feLbResult' 'user-defined lb shadows backend request'
assert_contains "$out" 'scalarEq "u" (u)' 'user-defined lb is expanded normally'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'field lb : scalar' \
  'field u : scalar' \
  'init:' \
  '  u := lb' \
  'step:' \
  "  u' = lb"
out=$(compile_fme "$f")
rm -f "$f"
typecheck_generated "$out"
assert_not_contains "$out" 'def feLbResult' 'a field named lb is not a backend request'
assert_contains "$out" 'fmrInit "u" (lb)' 'a field named lb is valid in an initializer'
assert_contains "$out" 'scalarEq "u" (lb)' 'a field named lb is valid in a step'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'metric scale [1]' \
  'field u : scalar' \
  'field v : scalar' \
  'init:' \
  '  u := lb v' \
  'step:' \
  "  u' = u"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'lb initializer unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'lb is not supported in an initializer' 'lb initializer rejection'
assert_contains "$out" "$f:8:8-11" 'CAS initializer backend request maps to its source span'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'metric scale [1]' \
  'field u : scalar' \
  'field v : scalar' \
  'init:' \
  '  u = lb v' \
  'step:' \
  "  u' = u"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'raw lb initializer unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'lb is not supported in an initializer' 'raw lb initializer rejection'
assert_contains "$out" "$f:8:7-10" 'raw initializer backend request maps to its source span'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'metric scale [1]' \
  'field u : scalar' \
  'field v : scalar' \
  'init:' \
  '  u = lb(v[i])' \
  'step:' \
  "  u' = u"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'raw Formura lb initializer unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'lb is not supported in an initializer' 'raw Formura lb application rejection'
assert_contains "$out" "$f:8:7-8" 'raw Formura initializer fallback maps the operator token'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'metric scale [1]' \
  'field u : scalar' \
  'field v : scalar' \
  'init:' \
  '  u = lb 1 + v[i]' \
  'step:' \
  "  u' = u"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'numeric raw Formura lb initializer unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'lb is not supported in an initializer' 'numeric raw Formura lb application rejection'
assert_contains "$out" "$f:8:7-8" 'numeric raw initializer fallback maps the operator token'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'metric scale [1]' \
  'field u : scalar' \
  'field v : scalar' \
  'init:' \
  '  u = blb[i] + lb(v[i])' \
  'step:' \
  "  u' = u"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'raw lb request after a containing identifier unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" "$f:8:16-17" 'raw fallback ignores lb inside a larger identifier'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'metric scale [1, 1]' \
  'field U_i' \
  'field v : scalar' \
  'init:' \
  '  U_i = [| 0,' \
  '          α + lb(v[i]) |]_i' \
  'step:' \
  "  v' = v"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'multiline raw lb initializer unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" "$f:9:15-16" 'multiline initializer maps request to its physical pre-transliteration location'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'def op q = lb q' \
  'metric scale [1]' \
  'field u : scalar' \
  'field v : scalar' \
  'init:' \
  '  u := op v' \
  'step:' \
  "  u' = u"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'definition-expanded lb initializer unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" "$f:4:12-15" 'initializer definition request keeps its definition span'
assert_contains "$out" "in expansion of op (defined at $f:4:12-15, called at $f:9:8-11)" 'initializer definition trace includes its call site'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'embedding [x + y, y]' \
  'field u : scalar' \
  'step:' \
  "  u' = u"
out=$(compile_fme "$f")
rm -f "$f"
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" 'the embedding is not orthogonal' 'non-orthogonal embedding runtime gate'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A~i_j' \
  'field p : scalar' \
  'def trace A = contractWith (+) A~i_i' \
  'step:' \
  "  p' = trace A~p_q"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'contractWith (+) (A~FormuraeInternalIndex1_FormuraeInternalIndex1)' 'trace remains a hygienically indexed Egison contraction'
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" "p' =" 'trace emits a scalar equation'
assert_contains "$fmr" 'A_up1_down1' 'trace projects the first diagonal component'
assert_contains "$fmr" 'A_up2_down2' 'trace projects the second diagonal component'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A~i_j' \
  'field B~i_j' \
  'field C~i_j' \
  'step:' \
  "  C'~i_j = A~i_k . B~k_j"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'def FormuraeInternalEquationAtC (FormuraeInternalTargetBasis: [Integer])' 'prelude dot uses one hygienic runtime tensor evaluator'
assert_contains "$out" 'A~FormuraeInternalIndex1_FormuraeInternalIndex3' 'prelude dot keeps the left tensor hygienically indexed'
assert_contains "$out" 'B~FormuraeInternalIndex3_FormuraeInternalIndex2' 'prelude dot keeps the right tensor hygienically indexed'
assert_not_contains "$out" 'def feqC11 :=' 'prelude dot is not component-expanded by fec'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A~i_j' \
  'field B~i_j' \
  'field C~i_j' \
  'def (.) A B = A + B' \
  'step:' \
  "  C'~i_j = A~i_j . B~i_j"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'A~FormuraeInternalIndex1_FormuraeInternalIndex2 + B~FormuraeInternalIndex1_FormuraeInternalIndex2' 'user-defined dot shadowing remains tensor-valued'
assert_not_contains "$out" 'def feqC11 :=' 'user-defined dot has no component helpers'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'def lap u = 7 * u' \
  'step:' \
  "  u' = lap u"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" '7 * u' 'user-defined standard operator shadowing'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'field q_j' \
  'def grad u = withSymbols [i] ∂_i u' \
  'init:' \
  '  u = 0.0' \
  'step:' \
  "  q'_j = grad u"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.partialChainTensor (feTensorDerivative Collocated Collocated)' 'withSymbols derivative is evaluated as a tensor in Egison'
assert_contains "$out" ')_FormuraeInternalIndex1' 'withSymbols local free index is alpha-renamed to the hygienic LHS index'
assert_not_contains "$out" 'def feqq1 :=' 'withSymbols derivative has no component helpers'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A_i' \
  'field q_i' \
  'def shaped X = withSymbols [i] exp(0 - X_i^2) + sin(X_i)' \
  'step:' \
  "  q'_i = shaped A_i"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'exp(' 'scalar call remains in the runtime tensor expression'
assert_contains "$out" 'sin(' 'second scalar call remains in the runtime tensor expression'
assert_contains "$out" 'A_FormuraeInternalIndex1' 'scalar calls consume the hygienically indexed tensor operand'
assert_not_contains "$out" 'def feqq1 :=' 'componentwise scalar calls have no component helpers'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A_i' \
  'field q_i' \
  'def mapExp X... = tensorMap exp X' \
  'step:' \
  "  q'_i = mapExp A"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'tensorMap (exp) (A_FormuraeInternalIndex1)' 'explicit tensorMap materializes the hygienically indexed operand in Egison'
assert_not_contains "$out" 'def feqq1 :=' 'tensorMap has no component helpers'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A_i' \
  'field q_i' \
  'def copy X = subrefs X [_i]' \
  'step:' \
  "  q'_i = copy A"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'subrefs (A) [FormuraeInternalIndex1]' 'subrefs uses hygienic Egison dynamic tensor refs'
assert_not_contains "$out" 'def feqq1 :=' 'subrefs has no component helpers'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A~i_j' \
  'field q~i_j' \
  'def copy X = subrefs X [~i, _j]' \
  'step:' \
  "  q'~i_j = copy A"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'subrefs (suprefs (A) [FormuraeInternalIndex1]) [FormuraeInternalIndex2]' 'mixed dynamic refs preserve each requested variance hygienically'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A_i_j' \
  'field C_i_j' \
  'def transpose2 X_i_j = transpose [j, i] X' \
  'step:' \
  "  C'_i_j = transpose2 A"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'transpose [FormuraeInternalIndex1, FormuraeInternalIndex2] (A_FormuraeInternalIndex2_FormuraeInternalIndex1)' 'transpose is reordered into hygienic LHS index order before projection'
assert_not_contains "$out" 'def feqC11 :=' 'transpose has no component helpers'
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" "C_down1_down2' = A_down2_down1" 'transpose preserves off-diagonal component order'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A_i_j' \
  'field C_i_j' \
  'field D_i_j' \
  'step:' \
  "  C'_i_j = if 1 > 2 then A_i_j else A_j_i" \
  "  D'_i_j = if 2 > 1 then A_j_i else A_i_j"
out=$(compile_fme "$f")
rm -f "$f"
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$out" 'transpose [FormuraeInternalIndex1, FormuraeInternalIndex2] (if' 'runtime result normalizes the selected conditional branch order'
assert_contains "$fmr" "C_down1_down2' = A_down2_down1" 'false conditional branch preserves transposed component order'
assert_contains "$fmr" "C_down2_down1' = A_down1_down2" 'false conditional branch preserves reverse component order'
assert_contains "$fmr" "D_down1_down2' = A_down2_down1" 'true conditional branch preserves transposed component order'
assert_contains "$fmr" "D_down2_down1' = A_down1_down2" 'true conditional branch preserves reverse component order'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A[_i_j]' \
  'field G_i_j' \
  'step:' \
  "  G'_i_j = A_j_i"
out=$(compile_fme "$f")
rm -f "$f"
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" "G_down1_down2' = (-1)*A_down1_down2" 'antisymmetric transpose negates the upper component'
assert_contains "$fmr" "G_down2_down1' = A_down1_down2" 'antisymmetric transpose restores the lower component sign'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A~i' \
  'field B_j' \
  'field C~i_j' \
  'step:' \
  "  C'~i_j = A~i !. B_j"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'A~FormuraeInternalIndex1' 'disjoint product keeps its contravariant operand hygienically indexed'
assert_contains "$out" 'B_FormuraeInternalIndex2' 'disjoint product keeps its covariant operand hygienically indexed'
assert_contains "$out" ' !. ' 'disjoint product is evaluated by Egison'
assert_not_contains "$out" 'def feqC11 :=' 'disjoint product has no component helpers'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A_i_j' \
  'field S_i_j' \
  'step:' \
  "  S'_i_j = sym A..._i_j"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'sym' 'Egison symmetrize bridge remains in the runtime tensor expression'
assert_not_contains "$out" 'def feqS12 :=' 'symmetrize bridge has no component helpers'
assert_contains "$out" 'def A := generateTensor' 'field tensor is generated as a bare binding'
assert_not_contains "$out" 'def A_i_j := generateTensor' 'indexed field binding is not generated'
assert_not_contains "$out" 'def A := A_#_#' 'bare field alias is unnecessary'
assert_not_contains "$out" 'FormuraeInternalTensor' 'obsolete internal tensor aliases are not emitted'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A_i' \
  'field B_j' \
  'field C_i_j' \
  'step:' \
  "  C'_i_j = wedge A B..._i_j"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'wedge' 'Egison wedge bridge remains in the runtime tensor expression'
assert_not_contains "$out" 'def feqC12 :=' 'wedge bridge has no component helpers'
assert_contains "$out" 'def A := generateTensor' 'wedge lhs is a bare field binding'
assert_contains "$out" 'def B := generateTensor' 'wedge rhs is a bare field binding'
assert_not_contains "$out" 'def A := A_#' 'wedge lhs needs no alias'
assert_not_contains "$out" 'def B := B_#' 'wedge rhs needs no alias'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A_i' \
  'field B_j' \
  'field C_i_j' \
  'step:' \
  "  A'_i = A_i" \
  "  C'_i_j = wedge A' B..._i_j"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" "def A' := generateTensor" 'primed tensor is generated as a bare binding'
assert_not_contains "$out" "def A'_i := generateTensor" 'indexed primed binding is not generated'
assert_not_contains "$out" "def A' := A'_#" 'primed tensor needs no alias'
assert_contains "$out" "wedge" 'primed bare tensor reaches Egison bridge'
assert_not_contains "$out" 'def feqC12 :=' 'primed wedge has no component helpers'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A_i' \
  'field B_i' \
  'field C_i_j' \
  'step:' \
  '  let T_i = B_i' \
  "  C'_i_j = wedge A T..._i_j"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'def FormuraeInternalLetAtT ' 'indexed let uses one runtime tensor evaluator'
assert_contains "$out" 'def T := generateTensor' 'indexed let is materialized as one bare tensor binding'
assert_contains "$out" 'B_FormuraeInternalIndex1' 'indexed let preserves its hygienic operand index'
assert_not_contains "$out" 'def T_i := withSymbols' 'indexed let binding is not retained'
assert_not_contains "$out" 'def T := T_#' 'indexed let needs no alias'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A~i_j' \
  'field p : scalar' \
  'field q : scalar' \
  'step:' \
  "  p' = contractWith (*) A~i_i" \
  "  q' = contractWith max A~i_i"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'contractWith (*) (A~FormuraeInternalIndex1_FormuraeInternalIndex1)' 'contractWith product reducer remains an Egison contraction'
assert_contains "$out" 'contractWith (FE.symbolicBinary "max") (A~FormuraeInternalIndex1_FormuraeInternalIndex1)' 'contractWith function reducer remains a symbolic Egison contraction'
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" "p' = A_up1_down1[i,j]*A_up2_down2[i,j]" 'product reducer executes in Egison'
assert_contains "$fmr" "q' = max(A_up1_down1[i,j],A_up2_down2[i,j])" 'named reducer prints as a backend function call'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A_i' \
  'field q : scalar' \
  'step:' \
  "  q' = A_long"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'multi-character free index unexpectedly bypassed scalar validation\n' >&2
  exit 1
fi
assert_contains "$out" 'index long is free but not on the left-hand side' 'multi-character scalar index validation'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 3' \
  'axes x,y,z' \
  'field u : scalar' \
  'step:' \
  "  u' = ∂^2_x u + ∂'^2_x u"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.partialChainTensor (feTensorDerivative Collocated Collocated) [] feAxisIds 2' 'decorated second derivative uses the tensor derivative bridge'
assert_contains "$out" '∂ 2 2 x (u)' 'quoted stencil-radius derivative'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'step:' \
  "  u' = ∂_x u + ∂_y u"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'feAxisIds 1 (FE.scalarTensor (u)))_1' 'x first derivative is selected from the runtime derivative tensor'
assert_contains "$out" 'feAxisIds 1 (FE.scalarTensor (u)))_2' 'y first derivative is selected from the runtime derivative tensor'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field V_i @ primal' \
  'field q : scalar' \
  'def divg X = ∂_x X_1 + ∂_y X_2' \
  'step:' \
  "  V'_i = V_i" \
  "  q' = divg V_i"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.partialChainTensor (feTensorDerivative Collocated Primal) [] feAxisIds 1 (V)' 'primal vector derivatives share the runtime tensor bridge'
assert_contains "$out" ')_1_1' 'primal coordinate derivative x selects the x diagonal'
assert_contains "$out" ')_2_2' 'primal coordinate derivative y selects the y diagonal'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 3' \
  'axes x,y,z' \
  'param dt = 1' \
  'field E_i' \
  'field B_i' \
  'step:' \
  "  E'_i = curl B_i" \
  "  B'_i = curl E'_i"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.curl (feTensorDerivative Collocated Collocated) feAxisIds B' 'standard curl remains a native Egison tensor operator'
assert_not_contains "$out" '∂ 1 1 y B_3 - ∂ 1 1 z B_2' 'native curl is not component-expanded by fec'
assert_contains "$out" "def E' := generateTensor" 'primed component family uses a bare tensor binding'
assert_not_contains "$out" "def E'_i := generateTensor" 'indexed primed binding is not generated'
assert_not_contains "$out" "def E' := E'_#" 'primed tensor alias is unnecessary'
assert_contains "$out" 'def feqE := withSymbols' 'collocated vector update is one checked native tensor RHS'
assert_contains "$out" 'FE.curl (feTensorDerivative Collocated Collocated) feAxisIds B' 'checked native tensor retains curl'
assert_contains "$out" 'FE.checkedTensorSignature "tensor signature mismatch for E"' 'native curl signature is checked through tensorIndices'
assert_not_contains "$out" 'def feqE1 :=' 'collocated vector update has no scalar helper definitions'
assert_contains "$out" 'fieldEqs (nth 1 feFieldDescriptors) (Collocated, feqE)' 'descriptor equation printer receives the whole tensor RHS'
assert_contains "$out" '("E", Collocated, [3], ["down"], "vector"' 'ordinary fields default to a collocated descriptor'
assert_contains "$out" 'def feFieldPolicies : [(String, GridPolicy)] := map' 'policy table is derived from field descriptors'
assert_not_contains "$out" 'def curl ' 'standard curl is not emitted'
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" "E_down1' =" 'tensor equation printer recovers the first storage target'
assert_contains "$fmr" "B_down3' =" 'tensor equation printer recovers the last storage target'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'field q_i' \
  'step:' \
  "  q'_i = grad u"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.grad (feTensorDerivative Collocated Collocated) feAxisIds u' 'standard grad tensor RHS remains native'
assert_contains "$out" 'FE.checkedTensorSignature "tensor signature mismatch for q"' 'standard grad uses runtime index metadata validation'
assert_not_contains "$out" 'def grad ' 'standard grad is not emitted'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'field q~i' \
  'step:' \
  "  q'~i = grad u"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.grad (feTensorDerivative Collocated Collocated) feAxisIds u' 'native indexed equation keeps the whole-tensor operator'
assert_contains "$out" '["up"]' 'native indexed equation validates the declared result variance in Egison'
assert_not_contains "$out" 'def feqq1 :=' 'native indexed equation does not enter ixExpand validation'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'field X_i' \
  'field q : vector' \
  'step:' \
  "  q' = grad u + X"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.grad ' 'implicit vector native equation bypasses the legacy signature oracle'
assert_contains "$out" 'FE.checkedTensorSignature "tensor signature mismatch for q"' 'implicit vector result is checked in Egison'
assert_not_contains "$out" 'def feqq1 :=' 'implicit vector native equation has no component fallback helpers'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'field X~i' \
  'field q : vector' \
  'step:' \
  "  q' = grad u + X~i"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'implicit lower vector target unexpectedly erased an explicit upper index\n' >&2
  exit 1
fi
assert_contains "$out" 'wrong variance' 'implicit vector target preserves explicit source variance'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'field q_i' \
  'init:' \
  '  u = x' \
  '  q_i := grad u'
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'fieldInits (nth 2 feFieldDescriptors)' 'standard grad uses one whole-tensor indexed initializer'
assert_not_contains "$out" 'FE.relativePlacement' 'same-lattice indexed initializer needs no resampling'
assert_not_contains "$out" 'FormuraeInternalNativeGrad' 'indexed initializer emits no native marker'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'field q_i' \
  'step:' \
  '  let T_i = grad u' \
  "  q'_i = T_i"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'def T := withSymbols' 'indexed let keeps one checked tensor binding'
assert_contains "$out" 'FE.grad (feTensorDerivative Collocated Collocated) feAxisIds u' 'indexed let keeps the standard operator native'
assert_not_contains "$out" 'FormuraeInternalNativeGrad' 'indexed let emits no native marker'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'step:' \
  '  let T~i = grad u'
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'def T := withSymbols' 'native indexed let uses one checked tensor binding'
assert_contains "$out" 'FE.grad (feTensorDerivative Collocated Collocated) feAxisIds u' 'native indexed let trusts NativeValue rank without legacy component validation'
assert_not_contains "$out" 'withSymbols [i] d_i u' 'native indexed let does not construct its legacy fallback'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'param a = 1' \
  'field u : scalar' \
  'field q_i' \
  'step:' \
  "  q'_i = if a > 0 then grad u else q_i"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'if (a > 0) then FE.grad ' 'native if validates branch signatures independently'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'field A_i_j' \
  'field C_i_j' \
  'step:' \
  "  C'_i_j = if 1 > 2 then hessian u else A_j_i"
out=$(compile_fme "$f")
rm -f "$f"
assert_not_contains "$out" 'def feqC12 :=' 'native mixed branch uses no component fallback helpers'
assert_contains "$out" 'transpose [FormuraeInternalIndex1, FormuraeInternalIndex2] (if' 'native mixed branch preserves the direct tensor index order'
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" "C_down1_down2' = A_down2_down1" 'native mixed false branch preserves its transpose'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field X_i' \
  'field q : scalar' \
  'step:' \
  "  q' = divg X_i"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'scalarEq "q" (FE.divg (feTensorDerivative Collocated Collocated) feAxisIds X)' 'native scalar equation bypasses legacy divg index validation'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field X_i' \
  'field q : scalar' \
  'init:' \
  '  X_i = [| 0, 0 |]_i' \
  '  q := divg X_i'
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'fmrInit "q" (FE.divg (feTensorDerivative Collocated Collocated) feAxisIds X)' 'native scalar initializer bypasses legacy divg component expansion'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'field X~i' \
  'field q_i' \
  'step:' \
  "  q'_i = grad u + X_i"
if out=$(compile_fme "$f" 2>&1); then
  rm -f "$f"
  printf 'native symbolic field reference unexpectedly ignored declared variance\n' >&2
  exit 1
fi
rm -f "$f"
assert_contains "$out" 'referenced with incompatible index variance' 'NativeValue validates explicit field reference variance without strictEinstein'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field X_j' \
  'field G_i_j' \
  'step:' \
  "  G'_i_j = dGrad X"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.dGrad (feTensorDerivative Collocated Collocated) feAxisIds X' 'standard dGrad remains a native rank-2 tensor'
assert_contains "$out" 'FE.checkedTensorSignature "tensor signature mismatch for G"' 'native rank-2 result is checked through tensorIndices'
assert_not_contains "$out" 'def feqG12 :=' 'native dGrad has no component helper definitions'
assert_not_contains "$out" 'def dGrad ' 'standard dGrad is not emitted'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field X_j @ primal' \
  'field G_i_j @ primal' \
  'step:' \
  "  G'_i_j = dGrad X"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.dGrad (feTensorDerivative Primal Primal) feAxisIds X' 'full rank-2 native derivative closes over target and source policies'
assert_contains "$out" '(targetBasis: [Integer]) (derivativeAxes: [Integer])' 'native derivative callback receives the concrete target basis and derivative axes'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 3' \
  'axes x,y,z' \
  'field X_i @ primal' \
  'field C_i @ dual' \
  'step:' \
  "  C'_i = curl X_i"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.curl (feTensorDerivative Dual Primal) feAxisIds X' 'curl closes over dual target and primal source policies'
assert_contains "$out" '(FE.componentPlacement feDim targetPolicy targetBasis)' 'curl target placement is inferred from its runtime component basis'
assert_contains "$out" '(FE.componentPlacement feDim sourcePolicy sourceBasis)' 'curl source placement is inferred from its runtime component basis'
assert_contains "$out" '("X", Primal, [3]' 'primal policy is stored in the X descriptor'
assert_contains "$out" '("C", Dual, [3]' 'dual policy is stored in the C descriptor'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 3' \
  'axes x,y,z' \
  'field E_i @ primal' \
  'field B_i @ dual' \
  'step:' \
  "  E'_i = B_i"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'cross-policy assignment unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'grid placement mismatch in indexed equation' 'cross-policy assignment rejection'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 3' \
  'axes x,y,z' \
  'field E_i @ primal' \
  'field B_i @ dual' \
  'step:' \
  "  E'_i = E_i + B_i"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'cross-policy addition unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'grid placement mismatch between operands' 'cross-policy addition rejection'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 3' \
  'axes x,y,z' \
  'field E_i @ primal' \
  'step:' \
  "  E'_i = curl E_i"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'same-policy primal curl assignment unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'grid placement mismatch in indexed equation' 'curl policy propagation rejection'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar @ primal' \
  'field v : scalar @ collocated' \
  'step:' \
  "  u' = lap u + v"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.lap (feTensorDerivative Primal Primal) feAxisIds u' 'native policy merge accepts equal physical scalar placements'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'field u : scalar @ dual' \
  'field X_i @ primal' \
  'step:' \
  "  u' = lap u + X_1"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.partialChainTensor (feTensorDerivative Dual Dual) [] feAxisIds 2' 'fixed component basis keeps the derivative tensor-valued'
assert_contains "$out" '+ X_1' 'fixed component basis remains explicit beside the runtime contraction'
assert_not_contains "$out" 'FE.lap ' 'fixed component basis does not enter the compact native policy summary'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field c : scalar @ dual' \
  'field u : scalar @ primal' \
  'step:' \
  "  u' = if c > 0 then lap u else u"
if out=$(compile_fme "$f" 2>&1); then
  rm -f "$f"
  printf 'native if unexpectedly read a condition at a different placement\n' >&2
  exit 1
fi
rm -f "$f"
assert_contains "$out" 'grid placement mismatch between operands in native expression' 'native if condition placement rejection'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field V~i @ primal' \
  'field q : scalar' \
  'step:' \
  "  V'~i = V~i" \
  "  q' = divg V~i"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.divg (feTensorDerivative Primal Primal) feAxisIds V' 'standard divg preserves the primal operator policy'
assert_contains "$out" '(FE.componentPlacement feDim targetPolicy targetBasis)' 'native divg lowers each target component placement in Egison'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field V_i @ primal' \
  'step:' \
  "  V'_i = V_i"
out=$(compile_fme "$f")
rm -f "$f"
assert_not_contains "$out" 'def dYee ' 'unused Yee helpers are not emitted'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field X_i @ collocated' \
  'field V_i @ dual' \
  'init:' \
  '  V_i := X_i'
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.componentPlacement feDim Dual FormuraeInternalTargetBasis' 'dual indexed initializer derives every component placement from its runtime basis'
assert_contains "$out" 'FE.relativePlacement' 'cross-lattice indexed initializer subtracts its RHS placement'
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" 'V_down1[i,j] = X_down1[i,j+(1 / 2)]' 'dual component 1 initializer uses its y half-cell placement'
assert_contains "$fmr" 'V_down2[i,j] = X_down2[i+(1 / 2),j]' 'dual component 2 initializer uses its x half-cell placement'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field X_i @ primal' \
  'field V_i @ primal' \
  'init:' \
  '  V_i := X_i'
out=$(compile_fme "$f")
rm -f "$f"
assert_not_contains "$out" 'FE.relativePlacement' 'same-policy indexed field initializer has zero relative offset'
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" 'V_down1[i,j] = X_down1[i,j]' 'same-policy indexed initializer does not double-shift component 1'
assert_contains "$fmr" 'V_down2[i,j] = X_down2[i,j]' 'same-policy indexed initializer does not double-shift component 2'

f=$(tmp_fme)
write_case "$f" \
  'mode dec' \
  'dimension 2' \
  'axes x,y' \
  'metric scale [2, 3]' \
  'field A : 1-form @ primal' \
  'field X~i @ primal' \
  'init:' \
  '  X~i := sharp A'
out=$(compile_fme "$f")
rm -f "$f"
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" 'X_up1[i,j] = A_1[i,j]/(4)' 'sharp initializer shares the source lattice in component 1'
assert_contains "$fmr" 'X_up2[i,j] = A_2[i,j]/(9)' 'sharp initializer shares the source lattice in component 2'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar @ dual' \
  'field V : vector @ collocated' \
  'field S : symmetric @ primal'
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" '("u", Dual, [], [], "scalar"' 'legacy scalar form stores dual policy in its descriptor'
assert_contains "$out" '("V", Collocated, [2], ["down"], "vector"' 'legacy vector form stores collocated policy in its descriptor'
assert_contains "$out" '("S", Primal, [2, 2], ["down", "down"], "symmetric"' 'legacy symmetric form stores primal policy in its descriptor'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar @ dual' \
  'init:' \
  '  u := x + y' \
  'step:' \
  "  u' = u"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.componentPlacement feDim Dual []' 'dual scalar CAS initializer is sampled at the dual cell'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field v : scalar @ dual' \
  'field u : scalar @ dual' \
  'init:' \
  '  u := v'
out=$(compile_fme "$f")
rm -f "$f"
assert_not_contains "$out" 'FE.relativePlacement' 'same-policy scalar initializer has zero relative offset'
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" 'u[i,j] = v[i,j]' 'same-policy scalar initializer does not double-shift its source'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field v : scalar @ dual' \
  'field u : scalar @ dual' \
  'init:' \
  '  u := v + x'
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'mixed physical-coordinate and staggered-field initializer unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'cannot mix explicit coordinates with a staggered field-valued expression' 'mixed-coordinate initializer is rejected instead of being sampled incorrectly'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'field v : scalar @ dual' \
  'step:' \
  "  u' = v"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'cross-policy scalar assignment unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'grid placement mismatch' 'cross-policy scalar assignment rejection'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field V_i @ staggered'
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'removed staggered policy unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" "bad grid policy 'staggered'" 'removed staggered policy'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'field u : scalar' \
  'step:' \
  "  u' = shift 1 1 u"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'def shift ' 'direct low-level derivative helper retains its dependency closure'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'field H_i_j' \
  'step:' \
  "  H'_i_j = hessian u"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" '-- mode collocated' 'explicit collocated mode metadata'
assert_contains "$out" 'FE.hessian (feTensorDerivative Collocated Collocated) feAxisIds u' 'standard hessian remains native and delegates fused derivative axes'
assert_contains "$out" 'FE.checkedTensorSignature "tensor signature mismatch for H"' 'native hessian result signature is checked in Egison'
assert_not_contains "$out" 'def feqH11 :=' 'native hessian has no component helper definitions'
assert_not_contains "$out" 'fePartial2' 'obsolete hessian helper is not emitted'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'step:' \
  "  u' = lap u"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.lap (feTensorDerivative Collocated Collocated) feAxisIds u' 'standard lap remains native'
assert_not_contains "$out" 'def lap ' 'standard lap is not emitted'
assert_not_contains "$out" 'def feGrad ' 'obsolete coordinate operator helpers are not emitted'
assert_not_contains "$out" 'def dF ' 'unused forward derivative helper is not emitted'
assert_not_contains "$out" 'def dB ' 'unused backward derivative helper is not emitted'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'def apply f x = f x' \
  'step:' \
  "  u' = apply lap u"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.lap (feTensorDerivative Collocated Collocated) feAxisIds u' 'higher-order standard operator retains native identity after substitution'
assert_not_contains "$out" 'lap u' 'higher-order expansion leaves no runtime-only coordinate operator'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'def pass f = (f)' \
  'step:' \
  "  u' = pass lap u"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.lap (feTensorDerivative Collocated Collocated) feAxisIds u' 'higher-order returned operator consumes remaining arguments natively'
assert_not_contains "$out" 'lap u' 'remaining arguments are re-expanded through the returned operator'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'def pass f = f' \
  'step:' \
  "  u' = (pass lap) u"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.lap (feTensorDerivative Collocated Collocated) feAxisIds u' 'parenthesized partial application is redispatched to the native operator'
assert_not_contains "$out" '(lap) u' 'parenthesized higher-order head leaves no runtime-only operator'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'def apply f x = f x' \
  'step:' \
  "  u' = apply apply lap u"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.lap (feTensorDerivative Collocated Collocated) feAxisIds u' 'finite higher-order application spine reaches the native operator'
assert_not_contains "$out" 'apply lap' 'partial higher-order application does not fail or survive'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'field u : scalar' \
  'def self f = f f' \
  'step:' \
  "  u' = self self u"
if out=$(compile_fme "$f" 2>&1); then
  rm -f "$f"
  printf 'recursive higher-order expansion unexpectedly succeeded\n' >&2
  exit 1
fi
rm -f "$f"
assert_contains "$out" 'possible higher-order recursion' 'recursive higher-order expansion is bounded'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'def (.) f x = f x' \
  'step:' \
  "  u' = lap . u"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.lap (feTensorDerivative Collocated Collocated) feAxisIds u' 'higher-order dot result is re-expanded to the native operator'
assert_not_contains "$out" 'lap u' 'dot expansion leaves no runtime-only coordinate operator'

f=$(tmp_fme)
write_case "$f" \
  'mode dec' \
  'dimension 3' \
  'axes x,y,z' \
  'param dt = 1' \
  'field E : 1-form' \
  'field B : 2-form' \
  'field H : 1-form @ dual' \
  'step:' \
  "  E' = E + dt * δ B" \
  "  B' = B - dt * d E'"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" '-- mode dec' 'explicit dec mode metadata'
assert_contains "$out" '("E", Primal, [3], ["down"], "form"' 'default E form policy is stored in its descriptor'
assert_contains "$out" '("B", Primal, [3, 3], ["down", "down"], "form"' 'default B form policy is stored in its descriptor'
assert_contains "$out" '("H", Dual, [3], ["down"], "form"' 'explicit dual form policy is stored in its descriptor'
assert_contains "$out" 'def Ef : (GridPolicy, Tensor MathValue) := (Primal,' 'default form value carries primal policy and a tensor'
assert_contains "$out" 'def Hf : (GridPolicy, Tensor MathValue) := (Dual,' 'explicit dual form value carries dual policy and a tensor'
assert_contains "$out" 'FE.canonicalFormTensor' 'form fields use canonical antisymmetric tensors'
assert_contains "$out" 'FE.componentPlacement feDim policy targetBasis' 'form derivative uses shared parity inference'
assert_not_contains "$out" 'def sigmaC ' 'complex-bit placement helper is removed'
assert_not_contains "$out" '(Integer, Integer, [MathValue])' 'form tuples no longer encode policy as an integer'
assert_not_contains "$out" 'def dForm ' 'exterior derivative semantics live in the shared geometry library'
assert_contains "$out" 'fieldEqs (nth 1 feFieldDescriptors) (FE.addForm Ef (FE.scaleForm (dt) (FE.codiffForm feDim feFormDerivative feHodgeCoefficient Bf)))' 'dec codifferential stays tensor-valued through the descriptor equation printer'
assert_not_contains "$out" 'formComps' 'form component-list bridge is removed'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode dec' \
  'dimension 2' \
  'axes x,y' \
  'field A : 1-form @ dual' \
  'field H : 1-form' \
  'step:' \
  "  H' = hodge A"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'fieldEqs (nth 2 feFieldDescriptors) (FE.hodgeForm feDim feHodgeCoefficient Af)' 'whole-form hodge flips dual input to primal target through its descriptor'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode dec' \
  'dimension 2' \
  'axes x,y' \
  'field u : 0-form' \
  'field q : 0-form' \
  'def lapForm a = codiff (d a)' \
  'step:' \
  "  q' = lapForm u"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'fieldEqs (nth 2 feFieldDescriptors) (FE.codiffForm feDim feFormDerivative feHodgeCoefficient (FE.dForm feDim feFormDerivative uf))' 'composed dec operators stay tensor-valued through their descriptor'

f=$(tmp_fme)
write_case "$f" \
  'mode dec' \
  'dimension 2' \
  'axes x,y' \
  'field X_i @ primal' \
  'field A : 1-form @ primal' \
  'step:' \
  "  A' = flat X_i"
if out=$(compile_fme "$f" 2>&1); then
  rm -f "$f"
  printf 'flat unexpectedly accepted a covariant vector\n' >&2
  exit 1
fi
rm -f "$f"
assert_contains "$out" 'flat expects an explicitly contravariant rank-1 vector' 'flat variance rejection'

f=$(tmp_fme)
write_case "$f" \
  'mode dec' \
  'dimension 2' \
  'axes x,y' \
  'field X~i @ primal' \
  'field A : 1-form @ primal' \
  'step:' \
  "  A' = flat X_i"
if out=$(compile_fme "$f" 2>&1); then
  rm -f "$f"
  printf 'flat unexpectedly accepted a reference with wrong variance\n' >&2
  exit 1
fi
rm -f "$f"
assert_contains "$out" 'referenced with incompatible index variance' 'flat validates operand reference variance'

f=$(tmp_fme)
write_case "$f" \
  'mode dec' \
  'dimension 2' \
  'axes x,y' \
  'field X_i @ primal' \
  'field A : 1-form @ primal' \
  'step:' \
  "  X'_i = sharp A"
if out=$(compile_fme "$f" 2>&1); then
  rm -f "$f"
  printf 'sharp unexpectedly wrote a covariant vector\n' >&2
  exit 1
fi
rm -f "$f"
assert_contains "$out" 'sharp target must be an explicitly contravariant rank-1 vector' 'sharp target variance rejection'

f=$(tmp_fme)
write_case "$f" \
  'mode dec' \
  'dimension 2' \
  'axes x,y' \
  'field X~i @ primal' \
  'field A : 2-form @ primal' \
  'step:' \
  "  X'~i = sharp A"
if out=$(compile_fme "$f" 2>&1); then
  rm -f "$f"
  printf 'sharp unexpectedly accepted a non-1-form\n' >&2
  exit 1
fi
rm -f "$f"
assert_contains "$out" 'sharp expects a 1-form' 'sharp degree rejection'

f=$(tmp_fme)
write_case "$f" \
  'mode dec' \
  'dimension 2' \
  'axes x,y' \
  'field X~i @ primal' \
  'field B : 2-form @ primal' \
  'step:' \
  "  B' = flat X~i"
if out=$(compile_fme "$f" 2>&1); then
  rm -f "$f"
  printf 'flat unexpectedly wrote a non-1-form target\n' >&2
  exit 1
fi
rm -f "$f"
assert_contains "$out" 'form degree mismatch' 'flat target degree rejection'

f=$(tmp_fme)
write_case "$f" \
  'mode dec' \
  'dimension 2' \
  'axes x,y' \
  'field X~i @ primal' \
  'field B : 2-form @ primal' \
  'step:' \
  "  B' = d (flat X~i)"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.dForm feDim feFormDerivative (FE.flat feMusicalScale (Primal, X))' 'form degree inference accepts d composed with flat'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field X~i' \
  'field A_i' \
  'step:' \
  "  A'_i = flat X~i"
if out=$(compile_fme "$f" 2>&1); then
  rm -f "$f"
  printf 'flat unexpectedly succeeded outside mode dec\n' >&2
  exit 1
fi
rm -f "$f"
assert_contains "$out" 'flat requires mode dec' 'musical maps are restricted to differential-form mode'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'mode dec' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar'
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'duplicate mode unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'mode may be declared only once' 'duplicate mode'

f=$(tmp_fme)
write_case "$f" \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar'
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'missing mode unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'mode declaration is required' 'required mode'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 3' \
  'axes x,y,z' \
  'use vector-calculus { curl }' \
  'field E_i'
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'removed use declaration unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'unrecognized: use vector-calculus { curl }' 'removed use declaration'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'field q_i' \
  'step:' \
  "  q'_i = ∂^2_i u"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.diagonalCoordinateDerivative (feTensorDerivative Collocated Collocated) ∂ feCoords feAxisIds 2 1' 'decorated indexed derivative remains one runtime tensor'
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" "q_down1' = (-2)*u[i,j]/(dx**2)" 'decorated indexed derivative emits the x diagonal stencil'
assert_contains "$fmr" "q_down2' = (-2)*u[i,j]/(dy**2)" 'decorated indexed derivative emits the y diagonal stencil'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'field q_i' \
  'step:' \
  "  q'_i = ∂'^2_i u"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.diagonalCoordinateDerivative (feTensorDerivative Collocated Collocated) ∂ feCoords feAxisIds 2 2' 'quoted indexed derivative remains one runtime tensor'
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" 'u[i-2,j]/(12*dx**2)' 'quoted indexed derivative emits the wide x stencil'
assert_contains "$fmr" 'u[i,j-2]/(12*dy**2)' 'quoted indexed derivative emits the wide y stencil'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'field u : scalar' \
  'step:' \
  "  u' = ∂_x (u * u / 2)"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FE.partialChainTensor' 'fixed-axis derivative materializes a compound scalar in Egison'
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" 'u[i+1]**2' 'compound scalar derivative emits its positive centered sample'
assert_contains "$fmr" 'u[i-1]**2' 'compound scalar derivative emits its negative centered sample'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A_i @ primal' \
  'field q_i @ primal' \
  'step:' \
  "  q'_i = ∂_x (A_i * 2)"
out=$(compile_fme "$f")
rm -f "$f"
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" "q_down1' = (-1)*A_down1[i-1,j]/(dx) + A_down1[i+1,j]/(dx)" 'compound indexed derivative preserves its staggered source basis'
assert_contains "$fmr" "q_down2' = (-1)*A_down2[i-1,j]/(dx) + A_down2[i+1,j]/(dx)" 'compound indexed derivative preserves the transverse component basis'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A~j @ primal' \
  'field q_i~j @ primal' \
  'step:' \
  "  q'_i~j = ∂_i (A~j * 2)"
out=$(compile_fme "$f")
rm -f "$f"
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" "q_down1_up1' = 2*A_up1[i,j]/(dx) + (-2)*A_up1[i-1,j]/(dx)" 'indexed compound derivative applies its derivative axis to source placement'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A~j @ primal' \
  'field q_i~j @ primal' \
  'step:' \
  "  q'_i~j = ∂_i (A * 2)"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'bare tensor inside a compound derivative unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'must be referenced with indices' 'compound derivative requires an explicit tensor component basis'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'step:' \
  "  u' = ∂ 2 1 x u"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'legacy coordinate derivative unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'coordinate derivative must be written with subscript notation' 'legacy coordinate derivative rejection'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'step:' \
  "  u' = ∂x u"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'compact coordinate derivative unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'coordinate derivative must be written with subscript notation' 'compact coordinate derivative rejection'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'param A = 1.0' \
  'field A_i' \
  'step:' \
  "  A'_i = A_i"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'duplicate param/field value name unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" "value name 'A' is declared more than once as param/field" 'bare binding name collision'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field feDim_i' \
  'step:' \
  "  feDim'_i = feDim_i"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'field/generated value name collision unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" "value name 'feDim' is reserved for generated Egison code (field)" 'bare field/generated name collision'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A_i' \
  'step:' \
  '  let feAxes_i = A_i' \
  "  A'_i = A_i"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'indexed let/generated value name collision unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" "value name 'feAxes' is reserved for generated Egison code (let)" 'bare indexed let/generated name collision'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field generateTensor_i' \
  'step:' \
  "  generateTensor'_i = generateTensor_i"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'Egison keyword field name unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" "value name 'generateTensor' is reserved for generated Egison code (field)" 'bare field/Egison keyword collision'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field contractWith_i' \
  'step:' \
  "  contractWith'_i = contractWith_i"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'generated helper field name unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" "value name 'contractWith' is reserved for generated Egison code (field)" 'bare field/generated helper collision'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field X_i' \
  'field XAt_i' \
  'step:' \
  "  X'_i = X_i" \
  "  XAt'_i = XAt_i"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'def FormuraeInternalEquationAtX ' 'runtime evaluator uses the reserved internal namespace'
assert_contains "$out" 'def FormuraeInternalEquationAtXAt ' 'runtime evaluator names remain injective across X and XAt'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A_i~j' \
  'field q_i' \
  'step:' \
  "  q'_i = contractWith (+) (∂_FormuraeInternalTargetBasis A_i~FormuraeInternalTargetBasis)"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'FormuraeInternalTargetBasis: [Integer]' 'runtime basis binder remains separate from hygienic symbolic indices'
assert_contains "$out" 'withSymbols [FormuraeInternalIndex1, FormuraeInternalIndex2]' 'the user dummy index is alpha-renamed without capture'
typecheck_generated "$out"

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'field q_i' \
  'step:' \
  '  let T_i = ∂_i u' \
  "  q'_i = T_i"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'def FormuraeInternalLetAtT ' 'indexed derivative let uses a runtime evaluator'
assert_not_contains "$out" 'withSymbols [i] d_i u' 'indexed derivative let has no unresolved legacy derivative'
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" "q_down1' = (-1)*u[i-1,j]/(2*dx)" 'indexed derivative let emits its x stencil'
assert_contains "$fmr" "q_down2' = (-1)*u[i,j-1]/(2*dy)" 'indexed derivative let emits its y stencil'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A_i_j' \
  'field C_i_j' \
  'step:' \
  '  let T_i_j = A_j_i' \
  "  C'_i_j = T_i_j"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'def T := generateTensor' 'rank-two indexed let is inferred from its two indices'
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" "C_down1_down2' = A_down2_down1" 'rank-two indexed let preserves transpose order'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A~i' \
  'field q~i' \
  'step:' \
  '  let T~i = A~i' \
  '  let U~i = tensorMap exp T' \
  "  q'~i = U~i"
out=$(compile_fme "$f")
rm -f "$f"
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" "q_up1' = exp(A_up1[i,j])" 'bare upper-index let retains its declared variance'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A~i' \
  'field q_i' \
  'step:' \
  '  let T~i = A~i' \
  "  q'_i = tensorMap exp T_i"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'indexed let variance mismatch unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'incompatible index variance' 'indexed let reference variance is validated'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A_i @ primal' \
  'field q_i @ primal' \
  'step:' \
  '  let c = 2' \
  "  q'_i = A_i * c"
out=$(compile_fme "$f")
rm -f "$f"
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" "q_down1' = 2*A_down1[i,j]" 'constant scalar let remains placement-neutral'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar @ primal' \
  'field q_i @ primal' \
  'step:' \
  '  let c = u + 1' \
  "  q'_i = ∂_i c"
out=$(compile_fme "$f")
rm -f "$f"
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" "q_down1' = (-1)*u[i,j]/(dx) + u[i+1,j]/(dx)" 'scalar let preserves its referenced primal policy'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar @ primal' \
  'field q_i @ dual' \
  'step:' \
  "  q'_i = ∂_i u"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'indexed derivative with the wrong result policy unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'grid placement mismatch in runtime tensor expression' 'indexed derivative result policy follows source parity'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A_i' \
  'field q_i' \
  'step:' \
  "  q'_i = T_i" \
  '  let T_i = A_i'
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'forward indexed let reference unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'before its definition' 'forward indexed let reference is rejected'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'init:' \
  '  u := s' \
  'step:' \
  '  local s = 1'
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'initializer step-local reference unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'initializer cannot reference step binding' 'initializer step scope is enforced'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'init:' \
  "  u := u'"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'primed initializer reference unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'initializer cannot reference primed field' 'initializer rejects unavailable primed storage'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A_i @ primal' \
  'field q_i @ primal' \
  'step:' \
  "  q'_i = contractWith (+) (delta~j_i * A_j)"
out=$(compile_fme "$f")
rm -f "$f"
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" "q_down1' = A_down1[i,j]" 'zero Kronecker branches do not cause false placement failures'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'metric g' \
  'field v~i @ primal' \
  'field S{~i~j} @ primal' \
  'step:' \
  "  S'~i~j = S~i~j + g~i~k . ∂_k v~j"
out=$(compile_fme "$f")
rm -f "$f"
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" "S_up1_up1'" 'zero off-diagonal metric branches do not cause false placement failures'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'metric g' \
  'field g : scalar @ dual' \
  'field S~i~j @ dual' \
  'step:' \
  "  S'~i~j = g~i~j * g"
out=$(compile_fme "$f" 2>/dev/null)
rm -f "$f"
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" "S_up1_up1' = g[i,j]" 'indexed metric wins over a same-named staggered scalar field'
assert_contains "$fmr" "S_up1_up2' = 0" 'same-named metric keeps neutral off-diagonal zero branches'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A_i~j @ primal' \
  'field v_j @ dual' \
  'field q_i @ primal' \
  'step:' \
  "  q'_i = A_i~j . v_j"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'cross-policy contracted product unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'grid placement mismatch' 'contracted operands must be collocated term by term'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A~i' \
  'field B_i' \
  'field p : scalar' \
  'step:' \
  "  p' = exp(1) * contractWith (+) (A~exp * B_exp)"
out=$(compile_fme "$f")
rm -f "$f"
assert_not_contains "$out" 'withSymbols [exp]' 'runtime dummy indices cannot capture scalar functions'
assert_contains "$out" 'exp(1)' 'hygienic dummy renaming preserves the scalar function call in generated Egison'
typecheck_generated "$out"
fmr=$(run_generated "$out")
assert_contains "$fmr" '*e' 'CAS may normalize exp(1) after hygienic dummy renaming'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 1' \
  'axes x' \
  'field u : scalar @ primal' \
  'field A_i @ primal' \
  'field q_i @ primal' \
  'step:' \
  "  q'_i = A_i * ∂'_x u"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'wide odd fixed-axis derivative across staggered lattices unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'wide odd-order coordinate derivative needs a placement-aware stencil' 'wide fixed-axis odd derivative rejects an unsupported half-grid stencil'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'raw my_fun = fun(x) x' \
  'field u : scalar' \
  'step:' \
  "  u' = my_fun(u)"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'my_fun(u)' 'underscore helper name is not misparsed as an indexed tensor'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A_i' \
  'field p : scalar' \
  'step:' \
  "  p' = tensorMap exp A"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'tensor-valued scalar equation unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'scalar expression has a tensor-valued result' 'scalar result rank is validated'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field v~i' \
  'field p : scalar' \
  'step:' \
  "  p' = v"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'bare indexed tensor field unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'must be referenced with indices' 'bare indexed tensor field error'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A_i' \
  'field q_i' \
  'step:' \
  "  q'_i = @ + A_i"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'unsupported tensor parser atom unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'bad tensor expression: unsupported scalar expression atom near: @ at column 1 in: @ + A_i' 'tensor parser diagnostic'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field u : scalar' \
  'step:' \
  "  u' = withSymbols [i ∂_i u"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'unbalanced withSymbols expression unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'withSymbols needs a bracketed symbol list at column 1 in: withSymbols [i d_i u' 'unbalanced bracket diagnostic'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field A~i_j' \
  'field p : scalar' \
  'step:' \
  "  p' = A~i_i"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'implicit diagonal contraction unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'use contractWith or .' 'missing explicit contraction error'

printf 'fec tensor expression tests: ok\n'
