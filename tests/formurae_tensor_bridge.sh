#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp "${TMPDIR:-/tmp}/formurae-standard-ops.XXXXXX.egi")
trap 'rm -f "$tmp"' EXIT

(cd "$root" && cabal run -v0 fec -- tests/formurae_standard_ops.fme >"$tmp")
(cd "$root/../egison" && cabal run -v0 egison -- -l "$root/lib/formurae-tensor.egi" -l "$root/lib/fmrgen.egi" "$tmp" >/dev/null)
