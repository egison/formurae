#!/bin/sh
# Prepare the validated Egison revision without changing the adjacent checkout.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
revision=$(cat "$root/spec/egison-revision")
source=${EGISON_SOURCE:-"$root/../egison"}
target="$root/.build/egison-$revision"
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
