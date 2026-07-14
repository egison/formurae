#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
EGISON_DIR=${EGISON_DIR:-"$ROOT/../egison"}
TMPDIR_ROOT=${TMPDIR:-/tmp}
WORK=$(mktemp -d "$TMPDIR_ROOT/formurae-pre-provenance.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

cd "$ROOT"
cabal run -v0 -j1 pre-fec -- tests/fixtures/pre_provenance_error.fme \
  > "$WORK/model.egi"

"$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" \
  "$WORK/model.egi" > "$WORK/model.feir"

cabal exec -v0 runghc -- -ifec/src tests/pre_provenance_feir.hs \
  < "$WORK/model.feir"

cabal run -v0 -j1 post-fec -- "$WORK/model.feir" > "$WORK/model.fmr"
test -s "$WORK/model.fmr"

printf 'pre-fec canonical-resample provenance pipeline tests: ok\n'
