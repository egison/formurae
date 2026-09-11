#!/bin/sh
# formurae-pre rejects parameters and coordinates named after the symbols
# that Egison's mathematical normalization rewrites (i, w, e); the same
# programs with other names are accepted.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

model() { # name param-name axis-name
  cat > "$work/$1.fme" <<MODEL
dimension 3
axes $3, y, z
metric g
param $2 = 0.15
param radius = 0.25
extern exp
field u : scalar @ collocated
init:
  u := exp (0 - ($3^2 + y^2 + z^2) / $2^2)
step:
  u' = u + radius * $2 * ∂^2_$3 u
MODEL
}

expect_rejection() { # name expected-message-fragment
  output=$(cabal run -v0 -j1 formurae-pre -- "$work/$1.fme" 2>&1 >/dev/null) && {
    printf 'formurae-pre accepted %s\n' "$1" >&2
    exit 1
  }
  case "$output" in
    *"$2"*) ;;
    *)
      printf 'formurae-pre did not report the reserved symbol for %s:\n%s\n' "$1" "$output" >&2
      exit 1
      ;;
  esac
}

model width-w w x
expect_rejection width-w "parameter name 'w' is reserved for Egison's mathematical symbol w, the primitive cube root of unity"
model width-e e x
expect_rejection width-e "parameter name 'e' is reserved for Egison's mathematical symbol e, Euler's constant"
model axis-w width w
expect_rejection axis-w "coordinate name 'w' is reserved for Egison's mathematical symbol w"

model accepted width x
cabal run -v0 -j1 formurae-pre -- "$work/accepted.fme" > "$work/accepted.egi" 2> "$work/accepted.err" || {
  printf 'formurae-pre rejected the renamed parameter:\n' >&2
  cat "$work/accepted.err" >&2
  exit 1
}
grep -q "declare symbol width, radius" "$work/accepted.egi" || {
  printf 'the renamed parameter is not declared as a symbol\n' >&2
  exit 1
}

printf 'formurae-pre reserved mathematical symbol tests: ok\n'
