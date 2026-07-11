#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
EGISON_DIR=${EGISON_DIR:-"$ROOT/../egison"}
TMPDIR_ROOT=${TMPDIR:-/tmp}
WORK=$(mktemp -d "$TMPDIR_ROOT/formurae-pre-provenance.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

cd "$ROOT"
cabal run -v0 pre-fec -- tests/fixtures/pre_provenance_error.fme \
  > "$WORK/model.egi"

"$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" \
  "$WORK/model.egi" > "$WORK/model.feir"

cabal exec -v0 runghc -- -ifec/src tests/pre_provenance_feir.hs \
  < "$WORK/model.feir"

if cabal run -v0 post-fec -- "$WORK/model.feir" \
     > "$WORK/model.fmr" 2> "$WORK/model.err"; then
  printf 'post-fec accepted an effectful analytic initializer\n' >&2
  exit 1
fi

grep -F 'post-fec: error: tests/fixtures/pre_provenance_error.fme:9:8: opaque operation VersionedOpId "operator.materialized@1" with effect NeedsMaterialization [IntermediateRole] is not allowed outside the step action stream' \
  "$WORK/model.err" >/dev/null
grep -F 'expanded from outer at tests/fixtures/pre_provenance_error.fme:9:8 (defined at tests/fixtures/pre_provenance_error.fme:7:15)' \
  "$WORK/model.err" >/dev/null
grep -F 'expanded from inner at tests/fixtures/pre_provenance_error.fme:7:15 (defined at tests/fixtures/pre_provenance_error.fme:6:15)' \
  "$WORK/model.err" >/dev/null

printf 'pre-fec provenance pipeline tests: ok\n'
