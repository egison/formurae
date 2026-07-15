#!/bin/sh

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EGISON_DIR=${EGISON_DIR:-"$ROOT/../egison"}

output=$(
  "$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" -t \
    "$ROOT/tests/formurae_divg_rank_error.egi" 2>&1
) && {
  printf 'vector divergence accepted a rank-two tensor\n' >&2
  exit 1
}

case "$output" in
  *"divg requires coordinates and a vector of the same dimension"*) ;;
  *)
    printf 'vector divergence did not report its rank contract:\n%s\n' \
      "$output" >&2
    exit 1
    ;;
esac

printf 'Formurae vector-divergence domain tests: ok\n'
