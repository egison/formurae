#!/bin/sh
# Reproduce the July Formurae snapshot without modifying the adjacent Egison
# checkout, whose subsequent type-system changes are a separate migration.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
revision=1a0298c67cc487dd4a73d96f526f3042b74d6570
source=${EGISON_SOURCE:-"$root/../egison"}
target="$root/.build/egison-elastic-validation"
if [ ! -f "$target/.formurae-revision" ]; then
  git -C "$source" cat-file -e "$revision^{commit}"
  mkdir -p "$target"
  git -C "$source" archive "$revision" | tar -x -C "$target"
  printf '%s\n' "$revision" > "$target/.formurae-revision"
fi
if [ "$(cat "$target/.formurae-revision")" != "$revision" ]; then
  printf 'Unexpected Egison revision in %s\n' "$target" >&2
  exit 1
fi
printf '%s\n' "$target"
