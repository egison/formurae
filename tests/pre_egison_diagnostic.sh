#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
EGISON_DIR=${EGISON_DIR:-"$ROOT/../egison"}
TMPDIR_ROOT=${TMPDIR:-/tmp}
WORK=$(mktemp -d "$TMPDIR_ROOT/formurae-pre-egison-diagnostic.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

cd "$ROOT"
cabal run -v0 -j1 pre-fec -- tests/fixtures/pre_egison_diagnostic_error.fme \
  > "$WORK/model.egi"

if "$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" \
     "$WORK/model.egi" > "$WORK/model.feir" 2> "$WORK/model.err"; then
  printf 'Egison accepted a scalar equation with a tensor value\n' >&2
  exit 1
fi

if [ -s "$WORK/model.feir" ]; then
  printf 'failed Egison normalization leaked output into the FEIR stream\n' >&2
  exit 1
fi

grep -F 'pre-fec: error: tests/fixtures/pre_egison_diagnostic_error.fme:11:8: Egison normalization failed' \
  "$WORK/model.err" >/dev/null
grep -F 'expanded from outer at tests/fixtures/pre_egison_diagnostic_error.fme:11:8 (defined at tests/fixtures/pre_egison_diagnostic_error.fme:7:15)' \
  "$WORK/model.err" >/dev/null
grep -F 'expanded from inner at tests/fixtures/pre_egison_diagnostic_error.fme:7:15 (defined at tests/fixtures/pre_egison_diagnostic_error.fme:6:15)' \
  "$WORK/model.err" >/dev/null
grep -F 'Assertion failed: "normalized equation tensor metadata mismatch"' \
  "$WORK/model.err" >/dev/null

if grep -F '@@FORMURAE_ACTIVE_ORIGIN:' "$WORK/model.err" >/dev/null; then
  printf 'machine origin marker leaked into the user diagnostic\n' >&2
  exit 1
fi

cabal run -v0 -j1 pre-fec -- tests/fixtures/pre_fec_curl_dimension_error.fme \
  > "$WORK/curl-dimension.egi"

if "$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" \
     "$WORK/curl-dimension.egi" \
     > "$WORK/curl-dimension.feir" 2> "$WORK/curl-dimension.err"; then
  printf 'Egison accepted curl in two dimensions\n' >&2
  exit 1
fi

if [ -s "$WORK/curl-dimension.feir" ]; then
  printf 'failed curl normalization leaked output into the FEIR stream\n' >&2
  exit 1
fi

grep -F 'pre-fec: error: tests/fixtures/pre_fec_curl_dimension_error.fme:7:8: Egison normalization failed' \
  "$WORK/curl-dimension.err" >/dev/null
grep -F 'Assertion failed: "curl requires three-dimensional coordinates and a vector"' \
  "$WORK/curl-dimension.err" >/dev/null

for metric_use in bare mixed; do
  source="tests/fixtures/pre_fec_metric_${metric_use}_error.fme"
  cabal run -v0 -j1 pre-fec -- "$source" > "$WORK/metric-$metric_use.egi"
  if "$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" \
       "$WORK/metric-$metric_use.egi" \
       > "$WORK/metric-$metric_use.feir" \
       2> "$WORK/metric-$metric_use.err"; then
    printf 'Egison accepted unsupported %s metric access\n' "$metric_use" >&2
    exit 1
  fi
  if [ -s "$WORK/metric-$metric_use.feir" ]; then
    printf 'failed %s metric access leaked FEIR output\n' "$metric_use" >&2
    exit 1
  fi
  grep -F 'Unbound variable: g' "$WORK/metric-$metric_use.err" >/dev/null
done

# The static layer distinguishes only scalar and tensor, so form-degree
# misuse passes pre-fec and must fail here with the library and encode
# guards, keeping the origin-resolved source position of the offending
# expression where one exists.
expect_normalization_failure() {
  fixture=$1
  location=$2
  message=$3
  source="tests/fixtures/$fixture.fme"
  cabal run -v0 -j1 pre-fec -- "$source" > "$WORK/$fixture.egi"
  if "$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" \
       "$WORK/$fixture.egi" \
       > "$WORK/$fixture.feir" 2> "$WORK/$fixture.err"; then
    printf 'Egison normalized invalid form-degree fixture: %s\n' "$source" >&2
    exit 1
  fi
  if [ -s "$WORK/$fixture.feir" ]; then
    printf 'failed %s normalization leaked FEIR output\n' "$fixture" >&2
    exit 1
  fi
  if [ -n "$location" ]; then
    grep -F "pre-fec: error: $source:$location: Egison normalization failed" \
      "$WORK/$fixture.err" >/dev/null
  fi
  grep -F "Assertion failed: \"$message\"" "$WORK/$fixture.err" >/dev/null
}

expect_normalization_failure pre_fec_codiff_tensor_error '6:10' \
  'canonical codifferential requires a scalar or differential form value'
expect_normalization_failure pre_fec_shadowed_intrinsic_kind_error '9:8' \
  'canonical codifferential requires a scalar or differential form value'
expect_normalization_failure pre_fec_divg_rank_unknown_error '7:8' \
  'divg requires coordinates and a vector of the same dimension'
expect_normalization_failure pre_fec_dd_kind_mismatch '' \
  'canonical d requires a scalar or differential form value'
expect_normalization_failure pre_fec_form_local_kind_mismatch '7:31' \
  'normalized equation tensor metadata mismatch'
expect_normalization_failure pre_fec_degree_mismatch '8:8' \
  'normalized equation tensor metadata mismatch'

printf 'pre-fec Egison source-diagnostic tests: ok\n'
