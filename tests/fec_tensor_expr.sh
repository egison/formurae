#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

compile_fe() {
  (cd "$ROOT" && cabal run -v0 fec -- "$1")
}

tmp_fe() {
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

f=$(tmp_fe)
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
out=$(compile_fe "$f")
rm -f "$f"
assert_contains "$out" '∂ 2 1 x u + ∂ 2 1 y u + ∂ 2 1 z u' 'lap = div grad'

f=$(tmp_fe)
write_case "$f" \
  'dimension 3' \
  'axes x,y,z' \
  'field u : scalar' \
  'def lap u = contractWith (+) (∂_i ∂~i u)' \
  'init:' \
  '  u = 0.0' \
  'step:' \
  "  u' = lap u"
out=$(compile_fe "$f")
rm -f "$f"
assert_contains "$out" '∂ 2 1 x u + ∂ 2 1 y u + ∂ 2 1 z u' 'raised indexed derivative'

f=$(tmp_fe)
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
out=$(compile_fe "$f")
rm -f "$f"
assert_contains "$out" '∂ 2 1 x u + ∂ 2 1 y u + ∂ 2 1 z u' 'metric dot laplacian'

f=$(tmp_fe)
write_case "$f" \
  'dimension 2' \
  'axes x,y' \
  'field A~i_j' \
  'field p : scalar' \
  'def trace A = contractWith (+) A~i_i' \
  'step:' \
  "  p' = trace A~p_q"
out=$(compile_fe "$f")
rm -f "$f"
assert_contains "$out" 'A_1_1 + A_2_2' 'trace'

f=$(tmp_fe)
write_case "$f" \
  'dimension 2' \
  'axes x,y' \
  'field A~i_j' \
  'field B~i_j' \
  'field C~i_j' \
  'step:' \
  "  C'~i_j = A~i_k . B~k_j"
out=$(compile_fe "$f")
rm -f "$f"
assert_contains "$out" 'A_1_1 * B_1_1 + A_1_2 * B_2_1' 'prelude dot'

f=$(tmp_fe)
write_case "$f" \
  'dimension 2' \
  'axes x,y' \
  'field A~i_j' \
  'field B~i_j' \
  'field C~i_j' \
  'def (.) A B = A + B' \
  'step:' \
  "  C'~i_j = A~i_j . B~i_j"
out=$(compile_fe "$f")
rm -f "$f"
assert_contains "$out" 'A_1_1 + B_1_1' 'user-defined dot shadowing'

f=$(tmp_fe)
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
out=$(compile_fe "$f")
rm -f "$f"
assert_contains "$out" 'def feqq2 := (dYee 2' 'withSymbols alpha-renaming'

f=$(tmp_fe)
write_case "$f" \
  'dimension 2' \
  'axes x,y' \
  'field A_i' \
  'field q_i' \
  'def shaped X = withSymbols [i] exp(0 - X_i^2) + sin(X_i)' \
  'step:' \
  "  q'_i = shaped A_i"
out=$(compile_fe "$f")
rm -f "$f"
assert_contains "$out" 'exp(0 - (A_1 ^ 2)) + sin(A_1)' 'scalar call and power AST'
assert_contains "$out" 'exp(0 - (A_2 ^ 2)) + sin(A_2)' 'scalar call and power AST component 2'

f=$(tmp_fe)
write_case "$f" \
  'dimension 2' \
  'axes x,y' \
  'field A~i_j' \
  'field p : scalar' \
  'field q : scalar' \
  'step:' \
  "  p' = contractWith (*) A~i_i" \
  "  q' = contractWith max A~i_i"
out=$(compile_fe "$f")
rm -f "$f"
assert_contains "$out" 'A_1_1 * A_2_2' 'contractWith product reducer'
assert_contains "$out" 'max(A_1_1, A_2_2)' 'contractWith function reducer'

f=$(tmp_fe)
write_case "$f" \
  'dimension 2' \
  'axes x,y' \
  'field v~i' \
  'field p : scalar' \
  'step:' \
  "  p' = v"
set +e
out=$(compile_fe "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'bare indexed tensor field unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'must be referenced with indices' 'bare indexed tensor field error'

f=$(tmp_fe)
write_case "$f" \
  'dimension 2' \
  'axes x,y' \
  'field A~i_j' \
  'field p : scalar' \
  'step:' \
  "  p' = A~i_i"
set +e
out=$(compile_fe "$f" 2>&1)
status=$?
set -e
rm -f "$f"
if [ "$status" -eq 0 ]; then
  printf 'implicit diagonal contraction unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$out" 'use contractWith or .' 'missing explicit contraction error'

printf 'fec tensor expression tests: ok\n'
