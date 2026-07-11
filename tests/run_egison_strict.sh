#!/bin/sh

# Egison currently reports strict type errors and warnings in its output while
# still exiting successfully.  Test targets must therefore check both the
# process status and the diagnostic stream.

set -u

if [ "$#" -lt 1 ]; then
  printf 'usage: %s EGISON_DIR [egison arguments ...]\n' "$0" >&2
  exit 2
fi

egison_dir=$1
shift

if output=$(cd "$egison_dir" && cabal run -v0 egison -- --type-check-strict "$@" 2>&1); then
  status=0
else
  status=$?
fi

if [ -n "$output" ]; then
  printf '%s\n' "$output"
fi

if [ "$status" -ne 0 ]; then
  exit "$status"
fi

if printf '%s\n' "$output" | grep -E '^(Type error|Warning):' >/dev/null; then
  exit 1
fi
