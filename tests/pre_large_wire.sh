#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
EGISON_DIR=${EGISON_DIR:-"$ROOT/../egison"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/formurae-large-wire.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

cd "$ROOT"
cabal run -v0 -j1 formurae-pre -- examples/lbm_d3q19/lbm_d3q19.fme > "$WORK/model.egi"

# Load the normal library manifest. The heap limit makes the former single
# enormous definition fail promptly instead of exhausting system memory.
set -- "$EGISON_DIR"
while IFS= read -r library; do
  [ "$library" = 'formurae-egison-normalization' ] && continue
  set -- "$@" -l "$ROOT/$library"
done < "$ROOT/spec/egison-normalization.list"

"$ROOT/tools/run_egison_machine.sh" "$@" -l "$WORK/model.egi" \
  -c 'main []' +RTS -M1G -RTS > "$WORK/model.feir"

# Splitting definitions must preserve every normalized value and every
# provenance entry, including the large origin table in this model.
cmp examples/lbm_d3q19/lbm_d3q19.feir "$WORK/model.feir"
printf 'formurae-pre large wire output within 1 GiB: ok\n'
