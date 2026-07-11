#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
out=$(mktemp "${TMPDIR:-/tmp}/formurae-runtime-error.XXXXXX")
trap 'rm -f "$out"' EXIT

if (cd "$root/../egison" && cabal run -v0 egison -- \
      -t \
      -l "$root/lib/formurae-grid.egi" \
      -l "$root/lib/formurae-tensor.egi" \
      -l "$root/lib/formurae-geometry.egi" \
      -l "$root/lib/formurae-runtime.egi" \
      "$root/tests/formurae_runtime_shape_mismatch.egi") >"$out" 2>&1; then
  printf 'tensor shape mismatch unexpectedly succeeded:\n' >&2
  sed -n '1,40p' "$out" >&2
  exit 1
fi

if ! grep -F 'tensor equation shape mismatch: [2] /= [3]' "$out" >/dev/null; then
  printf 'tensor shape mismatch diagnostic is missing:\n' >&2
  sed -n '1,40p' "$out" >&2
  exit 1
fi

if (cd "$root/../egison" && cabal run -v0 egison -- \
      -t \
      -l "$root/lib/formurae-grid.egi" \
      -l "$root/lib/formurae-tensor.egi" \
      -l "$root/lib/formurae-geometry.egi" \
      -l "$root/lib/formurae-runtime.egi" \
      "$root/tests/formurae_runtime_form_mismatch.egi") >"$out" 2>&1; then
  printf 'form policy mismatch unexpectedly succeeded:\n' >&2
  sed -n '1,40p' "$out" >&2
  exit 1
fi

if ! grep -F 'form equation policy/shape mismatch' "$out" >/dev/null; then
  printf 'form policy mismatch diagnostic is missing:\n' >&2
  sed -n '1,40p' "$out" >&2
  exit 1
fi
