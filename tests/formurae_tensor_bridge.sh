#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
egi_tmp=$(mktemp "${TMPDIR:-/tmp}/formurae-standard-ops.XXXXXX.egi")
type_tmp=$(mktemp "${TMPDIR:-/tmp}/formurae-standard-ops.XXXXXX.type")
fmr_tmp=$(mktemp "${TMPDIR:-/tmp}/formurae-standard-ops.XXXXXX.fmr")
err_tmp=$(mktemp "${TMPDIR:-/tmp}/formurae-standard-ops.XXXXXX.err")
trap 'rm -f "$egi_tmp" "$type_tmp" "$fmr_tmp" "$err_tmp"' EXIT

for model in formurae_standard_ops formurae_runtime_tensor_ops formurae_metric_tensor_ops formurae_musical_ops formurae_musical_variable_metric formurae_hodge_variable_metric formurae_native_rank2_ops; do
  (cd "$root" && cabal run -v0 fec -- "tests/$model.fme" >"$egi_tmp")
  if [ "$model" = formurae_standard_ops ]; then
    if ! grep -F 'def feqq := FE.grad ' "$egi_tmp" >/dev/null \
       || ! grep -F 'FE.lap ' "$egi_tmp" >/dev/null \
       || ! grep -F 'fieldEqs (nth 2 feFieldDescriptors) (Collocated, feqq)' "$egi_tmp" >/dev/null; then
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
  if [ "$model" = formurae_musical_ops ]; then
    if ! grep -F 'FE.flat feMusicalScale (Primal, X)' "$egi_tmp" >/dev/null \
       || ! grep -F 'FE.sharp feMusicalScale Af' "$egi_tmp" >/dev/null \
       || ! grep -F "A_1' = 4*X_up1" "$fmr_tmp" >/dev/null \
       || ! grep -F "A_2' = 9*X_up2" "$fmr_tmp" >/dev/null \
       || ! grep -F "X_up1' = A_1[i,j]/(4)" "$fmr_tmp" >/dev/null \
       || ! grep -F "X_up2' = A_2[i,j]/(9)" "$fmr_tmp" >/dev/null; then
      printf 'orthogonal flat/sharp lowering is missing for %s:\n' "$model" >&2
      cat "$egi_tmp" "$fmr_tmp" >&2
      exit 1
    fi
  fi
  if [ "$model" = formurae_native_rank2_ops ]; then
    if ! grep -F 'def feqH := FE.hessian ' "$egi_tmp" >/dev/null \
       || ! grep -F 'FE.dGrad (feTensorDerivative Collocated Collocated) feAxisIds q' "$egi_tmp" >/dev/null \
       || grep -F 'def feqH11 :=' "$egi_tmp" >/dev/null \
       || grep -F 'def feqG11 :=' "$egi_tmp" >/dev/null \
       || ! grep -F "H_down1_down1' =" "$fmr_tmp" >/dev/null \
       || ! grep -F "H_down1_down2' =" "$fmr_tmp" >/dev/null \
       || ! grep -F "G_down2_down1' = S_down1_down2" "$fmr_tmp" >/dev/null \
       || ! grep -F "K_down2_down1' = (-1)*A_down1_down2" "$fmr_tmp" >/dev/null \
       || grep -F 'S_2_1[' "$fmr_tmp" >/dev/null \
       || grep -F 'A_2_1[' "$fmr_tmp" >/dev/null \
       || grep -F 'FormuraeInternalField' "$fmr_tmp" >/dev/null; then
      printf 'native rank-2 operator projection is missing for %s:\n' "$model" >&2
      cat "$egi_tmp" "$fmr_tmp" >&2
      exit 1
    fi
  fi
  if [ "$model" = formurae_musical_variable_metric ]; then
    if ! grep -F 'def feMusicalScale (policy: GridPolicy) (axis: Integer)' "$egi_tmp" >/dev/null \
       || ! grep -F 'FE.componentPlacement feDim policy [axis]' "$egi_tmp" >/dev/null \
       || ! grep -F 'FE.flat feMusicalScale' "$egi_tmp" >/dev/null \
       || ! grep -F 'FE.sharp feMusicalScale' "$egi_tmp" >/dev/null \
       || ! grep -F 'dx**2/(4)' "$fmr_tmp" >/dev/null \
       || ! grep -F 'dx*(i*dx)' "$fmr_tmp" >/dev/null; then
      printf 'variable metric musical-map sampling is missing for %s:\n' "$model" >&2
      cat "$egi_tmp" "$fmr_tmp" >&2
      exit 1
    fi
  fi
  if [ "$model" = formurae_hodge_variable_metric ]; then
    if ! grep -F 'def feHodgeCoefficient (policy: GridPolicy) (basis: [Integer])' "$egi_tmp" >/dev/null \
       || ! grep -F 'FE.componentPlacement feDim policy basis' "$egi_tmp" >/dev/null \
       || ! grep -F 'FE.hodgeForm feDim feHodgeCoefficient Af' "$egi_tmp" >/dev/null \
       || ! grep -F "H_1' =" "$fmr_tmp" >/dev/null \
       || ! grep -F "H_2' =" "$fmr_tmp" >/dev/null \
       || ! grep -F 'dx/(2)' "$fmr_tmp" >/dev/null; then
      printf 'variable metric Hodge sampling is missing for %s:\n' "$model" >&2
      cat "$egi_tmp" "$fmr_tmp" >&2
      exit 1
    fi
  fi
done
