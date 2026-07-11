#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMPDIR_ROOT=${TMPDIR:-/tmp}
WORK=$(mktemp -d "$TMPDIR_ROOT/formurae-post-diagnostic.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

cd "$ROOT"
cabal build -v0 post-fec
POST_FEC=$(cabal list-bin post-fec)

runghc -Wall -ifec/src tests/post_diagnostic_cli_fixture.hs validation \
  > "$WORK/validation.feir"
if fec_datadir="$ROOT" "$POST_FEC" "$WORK/validation.feir" \
     > "$WORK/validation.fmr" 2> "$WORK/validation.err"; then
  printf 'post-fec accepted an invalid field layout\n' >&2
  exit 1
fi
grep -F 'post-fec: error: /workspace/cli-model.fme:10:4: layout VectorLayout is invalid' \
  "$WORK/validation.err" >/dev/null

runghc -Wall -ifec/src tests/post_diagnostic_cli_fixture.hs compile \
  > "$WORK/compile.feir"
if fec_datadir="$ROOT" "$POST_FEC" "$WORK/compile.feir" \
     > "$WORK/compile.fmr" 2> "$WORK/compile.err"; then
  printf 'post-fec accepted a wide derivative without radius\n' >&2
  exit 1
fi
grep -F 'post-fec: error: /workspace/cli-model.fme:30:7: wide derivative is missing attribute AttributeId "radius"' \
  "$WORK/compile.err" >/dev/null

printf 'post-fec source diagnostic CLI tests: ok\n'
