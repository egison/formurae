#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EGISON_DIR=${EGISON_DIR:-"$ROOT/../egison"}

compile_fme() {
  (cd "$ROOT" && cabal run -v0 fec -- "$1")
}

typecheck_generated() {
  printf '%s\n' "$1" |
    (cd "$EGISON_DIR" && cabal run -v0 egison -- -t \
      -l "$ROOT/lib/formurae-tensor.egi" \
      -l "$ROOT/lib/fmrgen.egi" \
      -l "$ROOT/lib/formurae-runtime.egi" /dev/stdin)
}

run_generated() {
  printf '%s\n' "$1" |
    (cd "$EGISON_DIR" && cabal run -v0 egison -- \
      -l "$ROOT/lib/formurae-tensor.egi" \
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

write_case() {
  file=$1
  shift
  : > "$file"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$file"
  done
}

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
assert_contains "$out" '∂ 2 1 x u + ∂ 2 1 y u + ∂ 2 1 z u' 'lap = div grad'

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
assert_contains "$out" '∂ 2 1 x u + ∂ 2 1 y u + ∂ 2 1 z u' 'raised indexed derivative'

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
assert_contains "$out" '∂ 2 1 x u + ∂ 2 1 y u + ∂ 2 1 z u' 'metric dot laplacian'
assert_not_contains "$out" 'FormuraeInternalMetric' 'Euclidean metric is specialized away'

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
assert_contains "$out" 'def FormuraeInternalMetricContra := generateTensor' 'non-Euclidean contravariant metric is retained as a bare tensor'
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
assert_contains "$out" 'def feSqrtG : MathValue := product (map feH feAxisIds)' 'embedding volume factor is shared'
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
assert_contains "$out" 'def FormuraeInternalMetricContra := generateTensor (\[i, j] -> if i = j then 1 / (feG i i) else 0)' 'embedding contravariant metric uses unified metric helper'
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
  'dimension 2' \
  'axes x,y' \
  'def Δ q = lb q' \
  'metric scale [1, 1]' \
  'field u : scalar' \
  'field v : scalar' \
  'step:' \
  "  u' = Δ u" \
  "  v' = Δ v"
set +e
out=$(compile_fme "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'multiple lb targets unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'lb currently supports one scalar field per model; found: u, v' 'multiple lb target rejection'

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
assert_contains "$out" 'A_1_1 + A_2_2' 'trace'

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
assert_contains "$out" 'A_1_1 * B_1_1 + A_1_2 * B_2_1' 'prelude dot'

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
assert_contains "$out" 'A_1_1 + B_1_1' 'user-defined dot shadowing'

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
assert_contains "$out" 'def feSteps := scalarEq "u" (7 * u)' 'user-defined standard operator shadowing'

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
assert_contains "$out" 'def feqq2 := ∂ 1 1 y u' 'withSymbols alpha-renaming'

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
assert_contains "$out" 'exp(0 - (A_1 ^ 2)) + sin(A_1)' 'scalar call and power AST'
assert_contains "$out" 'exp(0 - (A_2 ^ 2)) + sin(A_2)' 'scalar call and power AST component 2'

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
assert_contains "$out" 'exp A_1' 'explicit tensorMap component 1'
assert_contains "$out" 'exp A_2' 'explicit tensorMap component 2'

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
assert_contains "$out" 'A_1' 'subrefs component 1'
assert_contains "$out" 'A_2' 'subrefs component 2'

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
assert_contains "$out" 'A_1_1' 'transpose diagonal component'
assert_contains "$out" 'A_2_1' 'transpose off-diagonal component'

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
assert_contains "$out" 'A_1 * B_1' 'disjoint product component 1'
assert_contains "$out" 'A_2 * B_2' 'disjoint product component 2'

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
assert_contains "$out" 'def feqS12 := (sym A)_1_2' 'Egison symmetrize bridge'
assert_contains "$out" 'def A := generateTensor' 'field tensor is generated as a bare binding'
assert_not_contains "$out" 'def A_i_j := generateTensor' 'indexed field binding is not generated'
assert_not_contains "$out" 'def A := A_#_#' 'bare field alias is unnecessary'
assert_not_contains "$out" 'FormuraeInternalTensor' 'obsolete internal tensor aliases are not emitted'

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
assert_contains "$out" 'def feqC12 := (wedge A B)_1_2' 'Egison wedge bridge'
assert_contains "$out" 'def A := generateTensor' 'wedge lhs is a bare field binding'
assert_contains "$out" 'def B := generateTensor' 'wedge rhs is a bare field binding'
assert_not_contains "$out" 'def A := A_#' 'wedge lhs needs no alias'
assert_not_contains "$out" 'def B := B_#' 'wedge rhs needs no alias'

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
assert_contains "$out" "def feqC12 := (wedge A' B)_1_2" 'primed bare tensor reaches Egison bridge'

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
assert_contains "$out" 'def T := withSymbols [i] B_i' 'indexed let is generated as a bare tensor binding'
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
assert_contains "$out" 'A_1_1 * A_2_2' 'contractWith product reducer'
assert_contains "$out" 'max(A_1_1, A_2_2)' 'contractWith function reducer'

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
assert_contains "$out" '∂ 2 1 x u' 'decorated second derivative'
assert_contains "$out" '∂ 2 2 x u' 'quoted stencil-radius derivative'

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
assert_contains "$out" '∂ 1 1 x u + ∂ 1 1 y u' 'subscript first derivative'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field V_i @ staggered' \
  'field q : scalar' \
  'def divg X = ∂_x X_1 + ∂_y X_2' \
  'step:' \
  "  V'_i = V_i" \
  "  q' = divg V_i"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'dYee 1 [0, 0] (V_1, [1 / 2, 0])' 'staggered coordinate derivative x'
assert_contains "$out" 'dYee 2 [0, 0] (V_2, [0, 1 / 2])' 'staggered coordinate derivative y'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 3' \
  'axes x,y,z' \
  'field E_i' \
  'field B_i' \
  'step:' \
  "  E'_i = curl B_i" \
  "  B'_i = curl E'_i"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" '∂ 1 1 y B_3 - ∂ 1 1 z B_2' 'standard curl component expansion'
assert_contains "$out" "def E' := generateTensor" 'primed component family uses a bare tensor binding'
assert_not_contains "$out" "def E'_i := generateTensor" 'indexed primed binding is not generated'
assert_not_contains "$out" "def E' := E'_#" 'primed tensor alias is unnecessary'
assert_not_contains "$out" 'def curl ' 'standard curl is not emitted'

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
assert_contains "$out" 'def feqq1 := ∂ 1 1 x u' 'standard grad component 1'
assert_contains "$out" 'def feqq2 := ∂ 1 1 y u' 'standard grad component 2'
assert_not_contains "$out" 'def grad ' 'standard grad is not emitted'

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
assert_contains "$out" 'def feqG12 := ∂ 1 1 x X_2' 'standard dGrad component expansion'
assert_not_contains "$out" 'def dGrad ' 'standard dGrad is not emitted'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 3' \
  'axes x,y,z' \
  'field X_i @ staggered' \
  'field C_i @ staggered' \
  'step:' \
  "  C'_i = curl X_i"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'dYee 2 [1 / 2, 0, 0] (X_3, [0, 0, 1 / 2])' 'standard curl uses staggered derivative'
assert_contains "$out" 'dYee 3 [1 / 2, 0, 0] (X_2, [0, 1 / 2, 0])' 'standard curl uses staggered derivative second term'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field V~i @ staggered' \
  'field q : scalar' \
  'step:' \
  "  V'~i = V~i" \
  "  q' = divg V~i"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'dYee 1 [0, 0] (V_1, [1 / 2, 0])' 'standard divg uses staggered coordinate derivative x'
assert_contains "$out" 'dYee 2 [0, 0] (V_2, [0, 1 / 2])' 'standard divg uses staggered coordinate derivative y'

f=$(tmp_fme)
write_case "$f" \
  'mode collocated' \
  'dimension 2' \
  'axes x,y' \
  'field V_i @ staggered' \
  'step:' \
  "  V'_i = V_i"
out=$(compile_fme "$f")
rm -f "$f"
assert_not_contains "$out" 'def dYee ' 'unused Yee helpers are not emitted'

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
assert_contains "$out" 'def feqH11 := ∂ 2 1 x u' 'standard hessian diagonal is second derivative'
assert_contains "$out" 'def feqH12 := ∂ 1 1 x (∂ 1 1 y u)' 'standard hessian mixed derivative'
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
assert_contains "$out" '∂ 2 1 x u + ∂ 2 1 y u' 'standard lap expansion'
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
assert_contains "$out" '∂ 2 1 x u + ∂ 2 1 y u' 'higher-order standard operator is re-expanded after substitution'
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
assert_contains "$out" '∂ 2 1 x u + ∂ 2 1 y u' 'higher-order returned operator consumes remaining arguments'
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
assert_contains "$out" '∂ 2 1 x u + ∂ 2 1 y u' 'parenthesized partial application is redispatched after head expansion'
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
assert_contains "$out" '∂ 2 1 x u + ∂ 2 1 y u' 'finite higher-order application spine is flattened before expansion'
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
assert_contains "$out" '∂ 2 1 x u + ∂ 2 1 y u' 'higher-order dot result is re-expanded'
assert_not_contains "$out" 'lap u' 'dot expansion leaves no runtime-only coordinate operator'

f=$(tmp_fme)
write_case "$f" \
  'mode dec' \
  'dimension 3' \
  'axes x,y,z' \
  'field E : 1-form' \
  'field B : 2-form' \
  'step:' \
  "  E' = E + dt * δ B" \
  "  B' = B - dt * d E'"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" '-- mode dec' 'explicit dec mode metadata'
assert_contains "$out" 'def dForm (f:' 'dec exterior derivative is automatic'
assert_contains "$out" 'formComps (codiff Bf)' 'dec codifferential is automatic'

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
assert_contains "$out" 'formComps (codiff (dForm uf))' 'composed dec operators in user def'

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
assert_contains "$out" 'def feqq1 := ∂ 2 1 x u' 'decorated indexed derivative component 1'
assert_contains "$out" 'def feqq2 := ∂ 2 1 y u' 'decorated indexed derivative component 2'

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
assert_contains "$out" 'def feqq1 := ∂ 2 2 x u' 'quoted indexed derivative component 1'
assert_contains "$out" 'def feqq2 := ∂ 2 2 y u' 'quoted indexed derivative component 2'

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
