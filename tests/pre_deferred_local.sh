#!/bin/sh

# A step local declared `: tensor` defers its rank, variances, and form
# degree to the value computed during normalization.  The contract is that
# deferral changes nothing downstream: for column-aligned sources the FEIR
# must match the declared spelling byte-for-byte once the model/source
# identity strings (name, path, registry fingerprint) are masked.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
EGISON_DIR=${EGISON_DIR:-"$ROOT/../egison"}
TMPDIR_ROOT=${TMPDIR:-/tmp}
WORK=$(mktemp -d "$TMPDIR_ROOT/formurae-pre-deferred-local.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

cd "$ROOT"

mask_identity() {
  sed -E 's/sha256:[0-9a-f]+/sha256:MASKED/g; s/(declared|deferred)/SIDE/g'
}

compare_pair() {
  base=$1
  for side in declared deferred; do
    source="tests/fixtures/${base}_${side}.fme"
    cabal run -v0 -j1 pre-fec -- "$source" > "$WORK/${side}.egi"
    "$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" \
      "$WORK/${side}.egi" > "$WORK/${side}.feir"
    mask_identity < "$WORK/${side}.feir" > "$WORK/${side}.masked"
  done
  if ! cmp -s "$WORK/declared.masked" "$WORK/deferred.masked"; then
    printf 'deferred local diverged from declared FEIR: %s\n' "$base" >&2
    diff "$WORK/declared.masked" "$WORK/deferred.masked" >&2 || true
    exit 1
  fi
}

# 2-form intermediate: FormLayout declaration, ordered component bases.
compare_pair pre_fec_deferred_form
# Rank-zero and rank-one intermediates: scalar wrapper and vector layout
# with attached variances.
compare_pair pre_fec_deferred_mixed

printf 'pre-fec deferred-local tests: ok\n'
