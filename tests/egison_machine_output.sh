#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
egison_dir=${1:-"$root/../egison"}
runner="$root/tools/run_egison_machine.sh"

output=$(
  "$runner" "$egison_dir" "$root/tests/machine_output_valid.egi"
)

if [ "$output" != 'machine-ok' ]; then
  printf 'unexpected machine stdout: %s\n' "$output" >&2
  exit 1
fi

diagnostic_file=${TMPDIR:-/tmp}/formurae-machine-diagnostic.$$
trap 'rm -f "$diagnostic_file" "$diagnostic_file.stdout"' EXIT HUP INT TERM

if "$runner" "$egison_dir" "$root/tests/machine_output_invalid.egi" \
    >"$diagnostic_file.stdout" 2>"$diagnostic_file"; then
  printf 'machine runner accepted a strict type error\n' >&2
  exit 1
fi

if [ -s "$diagnostic_file.stdout" ]; then
  printf 'machine runner leaked failed output to stdout\n' >&2
  exit 1
fi

rm -f "$diagnostic_file.stdout"

if ! grep -E '^(Type error|Warning):' "$diagnostic_file" >/dev/null; then
  printf 'machine runner did not preserve the strict diagnostic\n' >&2
  exit 1
fi

printf 'Egison machine-output tests: ok\n'
