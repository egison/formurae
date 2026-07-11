#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
egi_tmp=$(mktemp "${TMPDIR:-/tmp}/formurae-standard-ops.XXXXXX.egi")
type_tmp=$(mktemp "${TMPDIR:-/tmp}/formurae-standard-ops.XXXXXX.type")
fmr_tmp=$(mktemp "${TMPDIR:-/tmp}/formurae-standard-ops.XXXXXX.fmr")
err_tmp=$(mktemp "${TMPDIR:-/tmp}/formurae-standard-ops.XXXXXX.err")
trap 'rm -f "$egi_tmp" "$type_tmp" "$fmr_tmp" "$err_tmp"' EXIT

for model in formurae_standard_ops formurae_runtime_tensor_ops formurae_metric_tensor_ops; do
  (cd "$root" && cabal run -v0 fec -- "tests/$model.fme" >"$egi_tmp")
  if [ "$model" = formurae_standard_ops ]; then
    if ! grep -F 'def feqq := [|' "$egi_tmp" >/dev/null \
       || ! grep -F "tensorEqs q' feqq" "$egi_tmp" >/dev/null; then
      printf 'generated tensor equation bridge is missing for %s:\n' "$model" >&2
      cat "$egi_tmp" >&2
      exit 1
    fi
  fi
  (cd "$root/../egison" && cabal run -v0 egison -- \
    -t \
    -l "$root/lib/formurae-grid.egi" \
    -l "$root/lib/formurae-tensor.egi" \
    -l "$root/lib/formurae-geometry.egi" \
    -l "$root/lib/fmrgen.egi" \
    -l "$root/lib/formurae-runtime.egi" \
    "$egi_tmp" >"$type_tmp" 2>"$err_tmp")
  if grep -E 'Warning:|Evaluation error:|(^|[^[:alpha:]])Error:' "$type_tmp" "$err_tmp" >/dev/null; then
    printf 'Egison reported a type error for %s:\n' "$model" >&2
    cat "$type_tmp" "$err_tmp" >&2
    exit 1
  fi
  (cd "$root/../egison" && cabal run -v0 egison -- \
    -l "$root/lib/formurae-grid.egi" \
    -l "$root/lib/formurae-tensor.egi" \
    -l "$root/lib/formurae-geometry.egi" \
    -l "$root/lib/fmrgen.egi" \
    -l "$root/lib/formurae-runtime.egi" \
    "$egi_tmp" >"$fmr_tmp" 2>"$err_tmp")
  if grep -E 'Warning:|Evaluation error:|(^|[^[:alpha:]])Error:' "$fmr_tmp" "$err_tmp" >/dev/null; then
    printf 'Egison reported an evaluation error for %s:\n' "$model" >&2
    cat "$fmr_tmp" "$err_tmp" >&2
    exit 1
  fi
  if ! grep -F 'begin function' "$fmr_tmp" >/dev/null; then
    printf 'Egison produced no Formura model for %s:\n' "$model" >&2
    cat "$fmr_tmp" "$err_tmp" >&2
    exit 1
  fi
  if [ "$model" = formurae_standard_ops ]; then
    if ! grep -F "q_down1' =" "$fmr_tmp" >/dev/null \
       || ! grep -F "q_down2' =" "$fmr_tmp" >/dev/null; then
      printf 'tensor equation bridge did not recover storage targets for %s:\n' "$model" >&2
      cat "$fmr_tmp" >&2
      exit 1
    fi
  fi
done
