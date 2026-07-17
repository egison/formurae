#!/bin/sh

# Load the versioned Formurae normalization library set in its normative
# order, then delegate strict machine-output handling to the generic runner.

set -eu

if [ "$#" -lt 2 ]; then
  printf 'usage: %s EGISON_DIR UNIT.egi\n' "$0" >&2
  printf '       %s EGISON_DIR -t TEST.egi\n' "$0" >&2
  exit 2
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
manifest="$root/spec/egison-normalization.list"

exec 3< "$manifest"
IFS= read -r schema <&3
if [ "$schema" != 'formurae-egison-normalization' ]; then
  printf '%s: unsupported normalization manifest: %s\n' "$0" "$schema" >&2
  exit 2
fi

egison_dir=$1
shift

# The schema fixes five ordered entries. Explicit reads preserve every
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

# Ambient Formurae operators close over bindings in the generated unit.  A
# normal one-unit invocation must therefore put that unit in the same initial
# recursive binding batch as the libraries, then invoke its main explicitly.
# Test invocations carry `-t`; the Egison CLI already includes their test file
# in the initial batch.  No other pass-through shape is accepted because a
# positional unit would form a later batch and silently break the ambient API.
if [ "$#" -eq 1 ]; then
  unit=$1
  "$root/tools/run_egison_machine.sh" "$egison_dir" \
    -l "$root/$library_1" -l "$root/$library_2" -l "$root/$library_3" \
    -l "$root/$library_4" -l "$root/$library_5" \
    -l "$unit" -c 'main []'
elif [ "$#" -eq 2 ] && [ "$1" = '-t' ]; then
  "$root/tools/run_egison_machine.sh" "$egison_dir" \
    -l "$root/$library_1" -l "$root/$library_2" -l "$root/$library_3" \
    -l "$root/$library_4" -l "$root/$library_5" "$@"
else
  printf 'usage: %s EGISON_DIR UNIT.egi\n' "$0" >&2
  printf '       %s EGISON_DIR -t TEST.egi\n' "$0" >&2
  exit 2
fi
