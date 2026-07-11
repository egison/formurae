#!/bin/sh

# Load the versioned Formurae normalization library set in its normative
# order, then delegate strict machine-output handling to the generic runner.

set -eu

if [ "$#" -lt 2 ]; then
  printf 'usage: %s EGISON_DIR [egison arguments ...] UNIT.egi\n' "$0" >&2
  exit 2
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
manifest="$root/spec/egison-normalization-v1.list"

exec 3< "$manifest"
IFS= read -r schema <&3
if [ "$schema" != 'formurae-egison-normalization 1' ]; then
  printf '%s: unsupported normalization manifest: %s\n' "$0" "$schema" >&2
  exit 2
fi

egison_dir=$1
shift

# The v1 schema fixes five ordered entries. Explicit reads preserve every
# caller argument verbatim without relying on non-POSIX shell arrays.
IFS= read -r library_1 <&3
IFS= read -r library_2 <&3
IFS= read -r library_3 <&3
IFS= read -r library_4 <&3
IFS= read -r library_5 <&3
if IFS= read -r extra_library <&3 || [ -z "$library_5" ]; then
  printf '%s: normalization manifest v1 must list exactly five libraries\n' "$0" >&2
  exit 2
fi

for library in "$library_1" "$library_2" "$library_3" "$library_4" "$library_5"; do
  if [ ! -f "$root/$library" ]; then
    printf '%s: normalization library does not exist: %s\n' \
      "$0" "$library" >&2
    exit 2
  fi
done

"$root/tools/run_egison_machine.sh" "$egison_dir" \
  -l "$root/$library_1" -l "$root/$library_2" -l "$root/$library_3" \
  -l "$root/$library_4" -l "$root/$library_5" "$@"
