#!/bin/sh

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EGISON_DIR=${EGISON_DIR:-"$ROOT/../egison"}

output=$(
  "$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" -t \
    "$ROOT/tests/formurae_opaque_derivative_error.egi" 2>&1
) || true

case "$output" in
  *"strict analytic derivative: no registered derivative rule for formuraeOpaqueBarrier"*) ;;
  *)
    printf 'strict differentiation did not reject an opaque request:\n%s\n' "$output" >&2
    exit 1
    ;;
esac

printf 'Formurae opaque derivative barrier test: ok\n'
