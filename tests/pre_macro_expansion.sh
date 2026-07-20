#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
EGISON_DIR=${EGISON_DIR:-"$ROOT/../egison"}
TMPDIR_ROOT=${TMPDIR:-/tmp}
WORK=$(mktemp -d "$TMPDIR_ROOT/formurae-pre-macro.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

compile_pipeline() {
  source=$1
  stem=$2
  cabal run -v0 -j1 formurae-pre -- "$source" > "$WORK/$stem.egi"
  "$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" \
    "$WORK/$stem.egi" > "$WORK/$stem.feir"
  cabal run -v0 -j1 formurae-post -- "$WORK/$stem.feir" > "$WORK/$stem.fmr"
}

cd "$ROOT"

# A macro is a generation-time template: its local bindings lift to the
# enclosing step action with fresh names (let-insertion) and the call is
# replaced by the result expression.  The macro spelling of the conservative
# torus Laplacian must generate exactly the .fmr of its written-out form.
compile_pipeline tests/fixtures/pre_macro_torus.fme macro-torus
compile_pipeline tests/fixtures/pre_macro_torus_direct.fme macro-torus-direct
diff "$WORK/macro-torus.fmr" "$WORK/macro-torus-direct.fmr" >/dev/null

# Each instantiation freshens its lifted locals.
cabal run -v0 -j1 formurae-pre -- tests/fixtures/pre_macro_hygiene.fme \
  > "$WORK/macro-hygiene.egi"
grep -F 'def q :=' "$WORK/macro-hygiene.egi" >/dev/null
grep -F 'def q2 :=' "$WORK/macro-hygiene.egi" >/dev/null

printf 'formurae-pre macro expansion tests: ok\n'
