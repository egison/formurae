#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
out=$(mktemp "${TMPDIR:-/tmp}/formurae-grid-error.XXXXXX")
trap 'rm -f "$out"' EXIT

check_rejected() {
  expression=$1
  expected=${2:-'component indices must be in 1..dim'}
  if (cd "$root/../egison" && cabal run -v0 egison -- \
        --type-check-strict \
        -l "$root/lib/formurae-grid.egi" \
        -e "$expression") >"$out" 2>&1; then
    printf 'invalid grid placement unexpectedly succeeded: %s\n' "$expression" >&2
    sed -n '1,40p' "$out" >&2
    exit 1
  fi

  if ! grep -F "$expected" "$out" >/dev/null; then
    printf 'grid placement diagnostic is missing for: %s\n' "$expression" >&2
    sed -n '1,40p' "$out" >&2
    exit 1
  fi
}

check_rejected 'FE.componentPlacement 3 Primal [0]'
check_rejected 'FE.componentPlacement 3 Primal [4]'
check_rejected 'FE.componentPlacement (-1) Primal []'
check_rejected 'FE.togglePlacement 0 [0, 0, 0]' 'axis must be in 1..length(placement)'
check_rejected 'FE.togglePlacement 4 [0, 0, 0]' 'axis must be in 1..length(placement)'
