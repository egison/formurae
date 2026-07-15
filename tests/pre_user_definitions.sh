#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
EGISON_DIR=${EGISON_DIR:-"$ROOT/../egison"}
TMPDIR_ROOT=${TMPDIR:-/tmp}
WORK=$(mktemp -d "$TMPDIR_ROOT/formurae-pre-user-definitions.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

compile_pipeline() {
  source=$1
  stem=$2
  cabal run -v0 -j1 pre-fec -- "$source" > "$WORK/$stem.egi"
  "$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" \
    "$WORK/$stem.egi" > "$WORK/$stem.feir"
  cabal run -v0 -j1 post-fec -- "$WORK/$stem.feir" > "$WORK/$stem.fmr"
}

expect_normalization_failure() {
  source=$1
  stem=$2
  expected=$3
  cabal run -v0 -j1 pre-fec -- "$source" > "$WORK/$stem.egi"
  if "$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" \
       "$WORK/$stem.egi" > "$WORK/$stem.feir" 2> "$WORK/$stem.err"; then
    printf 'normalization accepted invalid user definition result: %s\n' \
      "$source" >&2
    exit 1
  fi
  grep -F "$expected" "$WORK/$stem.err" >/dev/null
  if [ -s "$WORK/$stem.feir" ]; then
    printf 'failed user definition result leaked FEIR output: %s\n' \
      "$source" >&2
    exit 1
  fi
}

cd "$ROOT"

compile_pipeline tests/fixtures/pre_fec_user_definitions.fme user-definitions
# `materialize` below is deliberately a normal user-defined function after
# removal of the former primitive surface; it must not regain storage meaning.
grep -F 'FormuraeInternalDefinition2 materialize x' \
  "$WORK/user-definitions.egi" >/dev/null
grep -F 'FormuraeInternalDefinition3 X :=' \
  "$WORK/user-definitions.egi" >/dev/null
grep -F 'FormuraeInternalDefinition4 X :=' \
  "$WORK/user-definitions.egi" >/dev/null
if grep -F 'FormuraeInternalValidateDefinitionResult' \
     "$WORK/user-definitions.egi" >/dev/null; then
  printf 'user definition result validator unexpectedly remains in generated Egison\n' >&2
  exit 1
fi
if grep -F 'FormuraeInternalMaterialized x' "$WORK/user-definitions.egi" >/dev/null \
   || grep -E 'FormuraeInternalDefinition[0-9]+ X(\.\.\.|_[[:alnum:]])' \
        "$WORK/user-definitions.egi" >/dev/null; then
  printf 'user definition lexical shadow or parameter lowering leaked generated syntax\n' >&2
  exit 1
fi
grep -F "u'[i,j] = 1 + u[i,j]" "$WORK/user-definitions.fmr" >/dev/null
grep -F "Y_down1'[i,j] = X_down1[i,j]" "$WORK/user-definitions.fmr" >/dev/null
grep -F "B_down1_down2'[i,j] = A_down1_down2[i,j]" \
  "$WORK/user-definitions.fmr" >/dev/null

# A comment marker inside a string is data, not the start of a surface
# comment.  Exercise the complete generated Egison/FEIR pipeline so a
# truncated definition body cannot pass on a merely nonempty pre-fec output.
compile_pipeline \
  tests/fixtures/pre_fec_reserved_string_near_miss.fme \
  reserved-string-near-miss
grep -F "u'[i] = u[i]" "$WORK/reserved-string-near-miss.fmr" >/dev/null

# An anonymous/default-down result cannot be stored in an upper field.  This
# is rejected at the equation target, independently of the definition body.
expect_normalization_failure \
  tests/fixtures/pre_fec_user_result_variance_raw_error.fme \
  result-variance-raw \
  'Assertion failed: "normalized equation tensor metadata mismatch"'

# Egison may use temporary index views internally when the stored result is a
# scalar.  Formurae does not inspect the definition's calculation history.
compile_pipeline \
  tests/fixtures/pre_fec_user_result_variance_raw_primitive.fme \
  result-variance-raw-scalar-reducer
grep -F "u'[i,j] =" \
  "$WORK/result-variance-raw-scalar-reducer.fmr" >/dev/null

# Full-source comment handling follows Egison strings, character literals,
# line comments, and nested block comments.  Prime-suffixed local identifiers
# remain ordinary raw Egison bindings.
compile_pipeline \
  tests/fixtures/pre_fec_user_result_variance_raw_near_miss.fme \
  result-variance-raw-near-miss
grep -F "u'[i,j] =" "$WORK/result-variance-raw-near-miss.fmr" >/dev/null

# A multiline Egison definition may return an existing upper tensor unchanged.
# Definition bodies do not receive a separate result-provenance contract.
compile_pipeline \
  tests/fixtures/pre_fec_user_result_variance_raw_preserved.fme \
  result-variance-raw-preserved
grep -F "Y_up1'[i,j] = X_up1[i,j]" \
  "$WORK/result-variance-raw-preserved.fmr" >/dev/null

# Scalar reducers may consume a temporary index view; only their stored scalar
# result is checked against the equation target.
compile_pipeline \
  tests/fixtures/pre_fec_user_result_scalar_reducer.fme \
  result-scalar-reducer
grep -F "u'[i,j] =" "$WORK/result-scalar-reducer.fmr" >/dev/null
grep -F "v'[i,j] =" "$WORK/result-scalar-reducer.fmr" >/dev/null

# Existing upper and mixed-variance values may pass through ordinary Egison
# identity, scaling, and pointwise functions before target metadata is checked.
compile_pipeline \
  tests/fixtures/pre_fec_user_result_variance_preserved.fme \
  result-variance-preserved
grep -F "Y_up1'[i,j] = X_up1[i,j]" \
  "$WORK/result-variance-preserved.fmr" >/dev/null
grep -F "U_up1_down2'[i,j] = 2 * T_up1_down2[i,j]" \
  "$WORK/result-variance-preserved.fmr" >/dev/null
grep -F "P_up1'[i,j] = alpha * X_up1[i,j]" \
  "$WORK/result-variance-preserved.fmr" >/dev/null
grep -F "Q_up1'[i,j] = X_up1[i,j] * c[i,j]" \
  "$WORK/result-variance-preserved.fmr" >/dev/null
grep -F "L_up1'[i,j] =" \
  "$WORK/result-variance-preserved.fmr" >/dev/null

# Built-in mathematical functions remain legal higher-order formals.  They
# are not captured by the small set of names generated inside fixed-parameter
# checks.
compile_pipeline \
  tests/fixtures/pre_fec_definition_higher_order_sqrt.fme \
  higher-order-sqrt
grep -F "u'[i] =" "$WORK/higher-order-sqrt.fmr" >/dev/null

# The checked-in whole-tensor sample exercises standard operators through a
# pure higher-order user function all the way across Egison and FEIR.
compile_pipeline tests/formurae_standard_ops.fme higher-order
grep -F 'apply FormuraeInternalLap u' \
  "$WORK/higher-order.egi" >/dev/null
grep -F 'apply FormuraeInternalGrad u' \
  "$WORK/higher-order.egi" >/dev/null
grep -F "u'[i,j] =" "$WORK/higher-order.fmr" >/dev/null
grep -F "q_down1'[i,j] =" "$WORK/higher-order.fmr" >/dev/null

# A free lower index in an ordinary user tensor definition is structurally
# completed at the equation boundary.  Differential-form results retain their
# anonymous degree axes and therefore remain distinct in FEIR.
compile_pipeline tests/fixtures/pre_fec_index_completion.fme index-completion
cabal exec -v0 runghc -- -ifec/src tests/pre_index_completion_feir.hs \
  < "$WORK/index-completion.feir"
grep -F "q_down1'[i,j] =" "$WORK/index-completion.fmr" >/dev/null
grep -F "D_1'[i,j] =" "$WORK/index-completion.fmr" >/dev/null
grep -F "H_1'[i,j] =" "$WORK/index-completion.fmr" >/dev/null

# An anonymous derivative axis has the default lower variance.  Completion
# must not reinterpret it as an upper index merely to satisfy the target.
up_error=tests/fixtures/pre_fec_index_completion_up_error.fme
cabal run -v0 -j1 pre-fec -- "$up_error" > "$WORK/index-completion-up.egi"
if "$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" \
     "$WORK/index-completion-up.egi" > "$WORK/index-completion-up.feir" \
     2> "$WORK/index-completion-up.err"; then
  printf 'anonymous lower index unexpectedly completed to an upper target\n' >&2
  exit 1
fi
grep -F 'Assertion failed: "normalized equation tensor metadata mismatch"' \
  "$WORK/index-completion-up.err" >/dev/null
if [ -s "$WORK/index-completion-up.feir" ]; then
  printf 'failed upper-index completion leaked FEIR output\n' >&2
  exit 1
fi

# An anonymous rank-one result receives a fresh lower axis; it is not unified
# with an already explicit E_i merely because both axes are covariant.
anonymous_error=tests/fixtures/pre_fec_anonymous_index_nonunification.fme
cabal run -v0 -j1 pre-fec -- "$anonymous_error" \
  > "$WORK/anonymous-index-nonunification.egi"
grep -F 'withSymbols [i] (E_i + gradLike u)' \
  "$WORK/anonymous-index-nonunification.egi" >/dev/null
if "$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" \
     "$WORK/anonymous-index-nonunification.egi" \
     > "$WORK/anonymous-index-nonunification.feir" \
     2> "$WORK/anonymous-index-nonunification.err"; then
  printf 'anonymous result axis unexpectedly unified with explicit E_i\n' >&2
  exit 1
fi
grep -E 'Inconsistent tensor index|normalized equation tensor metadata mismatch' \
  "$WORK/anonymous-index-nonunification.err" >/dev/null
if [ -s "$WORK/anonymous-index-nonunification.feir" ]; then
  printf 'failed anonymous-index composition leaked FEIR output\n' >&2
  exit 1
fi

# A fixed indexed formal binds one whole tensor value, but its suffix remains
# a structural rank/variance contract at the generic Egison function entry.
fixed_error=tests/fixtures/pre_fec_fixed_parameter_error.fme
cabal run -v0 -j1 pre-fec -- "$fixed_error" > "$WORK/fixed-parameter.egi"
if "$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" \
     "$WORK/fixed-parameter.egi" > "$WORK/fixed-parameter.feir" \
     2> "$WORK/fixed-parameter.err"; then
  printf 'fixed rank-two parameter unexpectedly accepted a vector\n' >&2
  exit 1
fi
grep -F 'Assertion failed: "indexed parameter X_i_j metadata mismatch in fixedIdentity"' \
  "$WORK/fixed-parameter.err" >/dev/null
if [ -s "$WORK/fixed-parameter.feir" ]; then
  printf 'failed fixed-parameter contract leaked FEIR output\n' >&2
  exit 1
fi

printf 'pre-fec user definition and higher-order pipeline tests: ok\n'
