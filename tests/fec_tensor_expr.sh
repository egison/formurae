#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

compile_fme() {
  (cd "$ROOT" && cabal run -v0 fec -- "$1")
}

tmp_fme() {
  mktemp "${TMPDIR:-/tmp}/formurae-fec-test.XXXXXX"
}

assert_contains() {
  haystack=$1
  needle=$2
  label=$3
  if ! printf '%s\n' "$haystack" | grep -F "$needle" >/dev/null; then
    printf 'missing expected output for %s:\n%s\n' "$label" "$needle" >&2
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

f=$(tmp_fme)
write_case "$f" \
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
assert_contains "$out" 'def feqq2 := dYee 2' 'withSymbols alpha-renaming'

f=$(tmp_fme)
write_case "$f" \
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
  'dimension 3' \
  'axes x,y,z' \
  'use vector-calculus { curl }' \
  'field E_i' \
  'field B_i' \
  'step:' \
  "  E'_i = curl B_i"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'def feqE1 := (1 * (∂ 1 1 y B_3 - ∂ 1 1 z B_2))' 'standard curl expands for indexed fields'

f=$(tmp_fme)
write_case "$f" \
  'dimension 3' \
  'axes x,y,z' \
  'use vector-calculus { curl }' \
  'field E : vector' \
  'field B : vector' \
  'step:' \
  "  E' = curl B"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'def feqE1 := (1 * (∂ 1 1 y B_3 - ∂ 1 1 z B_2))' 'standard curl expands for legacy vector equation'

f=$(tmp_fme)
write_case "$f" \
  'dimension 3' \
  'axes x,y,z' \
  'use vector-calculus { curl }' \
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
  'dimension 2' \
  'axes x,y' \
  'use vector-calculus { divg }' \
  'field V_i @ staggered' \
  'field q : scalar' \
  'step:' \
  "  V'_i = V_i" \
  "  q' = divg V_i"
out=$(compile_fme "$f")
rm -f "$f"
assert_contains "$out" 'dYee 1 [0, 0] (V_1, [1 / 2, 0])' 'standard divg uses staggered coordinate derivative x'
assert_contains "$out" 'dYee 2 [0, 0] (V_2, [0, 1 / 2])' 'standard divg uses staggered coordinate derivative y'

f=$(tmp_fme)
write_case "$f" \
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
