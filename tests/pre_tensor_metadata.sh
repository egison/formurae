#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
EGISON_DIR=${EGISON_DIR:-"$ROOT/../egison"}
TMPDIR_ROOT=${TMPDIR:-/tmp}
WORK=$(mktemp -d "$TMPDIR_ROOT/formurae-pre-tensor-metadata.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

run_machine() {
  "$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" "$@"
}

cd "$ROOT"
cabal run -v0 pre-fec -- tests/fixtures/pre_fec_materialized_metadata.fme \
  > "$WORK/materialized.egi"
grep -F 'Formurae.materialized FormuraeInternalContext value' \
  "$WORK/materialized.egi" >/dev/null
grep -F 'def FormuraeInternalValue1 := stored X' \
  "$WORK/materialized.egi" >/dev/null
grep -F 'def FormuraeInternalValue2 := stored A' \
  "$WORK/materialized.egi" >/dev/null
run_machine "$WORK/materialized.egi" > "$WORK/materialized.feir"
cabal exec -v0 runghc -- -ifec/src tests/pre_materialized_metadata_feir.hs \
  < "$WORK/materialized.feir"

expect_metadata_failure() {
  kind=$1
  location=$2
  source="tests/fixtures/pre_fec_${kind}_mismatch.fme"
  cabal run -v0 pre-fec -- "$source" > "$WORK/$kind.egi"
  if run_machine "$WORK/$kind.egi" \
       > "$WORK/$kind.feir" 2> "$WORK/$kind.err"; then
    printf 'Egison accepted a %s metadata mismatch\n' "$kind" >&2
    exit 1
  fi
  if [ -s "$WORK/$kind.feir" ]; then
    printf '%s metadata failure leaked FEIR output\n' "$kind" >&2
    exit 1
  fi
  grep -F "pre-fec: error: $source:$location: Egison normalization failed" \
    "$WORK/$kind.err" >/dev/null
  grep -F 'Assertion failed: "normalized equation tensor metadata mismatch"' \
    "$WORK/$kind.err" >/dev/null
}

expect_metadata_failure variance 7:10
expect_metadata_failure degree 7:8

printf 'pre-fec structural tensor metadata tests: ok\n'
