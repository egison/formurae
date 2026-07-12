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
  cabal run -v0 pre-fec -- "$source" > "$WORK/$stem.egi"
  "$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" \
    "$WORK/$stem.egi" > "$WORK/$stem.feir"
  cabal run -v0 post-fec -- "$WORK/$stem.feir" > "$WORK/$stem.fmr"
}

cd "$ROOT"

compile_pipeline tests/fixtures/pre_fec_user_definitions.fme user-definitions
grep -F 'FormuraeInternalDefinition2 materialize x' \
  "$WORK/user-definitions.egi" >/dev/null
grep -F 'FormuraeInternalDefinition3 X :=' \
  "$WORK/user-definitions.egi" >/dev/null
grep -F 'FormuraeInternalDefinition4 X :=' \
  "$WORK/user-definitions.egi" >/dev/null
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
cabal run -v0 pre-fec -- "$up_error" > "$WORK/index-completion-up.egi"
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

# A fixed indexed formal binds one whole tensor value, but its suffix remains
# a structural rank/variance contract at the generic Egison function entry.
fixed_error=tests/fixtures/pre_fec_fixed_parameter_error.fme
cabal run -v0 pre-fec -- "$fixed_error" > "$WORK/fixed-parameter.egi"
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
