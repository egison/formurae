#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
EGISON_DIR=${EGISON_DIR:-"$ROOT/../egison"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/formurae-sample-sides.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
cd "$ROOT"

normalize() {
  cabal run -v0 formurae-pre -- "$1" > "$WORK/model.egi"
  "$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" \
    "$WORK/model.egi" > "$WORK/model.feir"
}
normalize tests/fixtures/pre_sample_sides.fme
cabal run -v0 formurae-post -- "$WORK/model.feir" > "$WORK/model.fmr"
cp tests/sample_sides_check.c "$WORK/check.c"
for blocking in 0 4; do
  cat > "$WORK/model.yaml" <<EOF
length_per_node: [6.283185307179586, 6.283185307179586]
grid_per_node: [16, 16]
mpi_shape: [1, 1]
boundary: [periodic, periodic]
EOF
  if [ "$blocking" != 0 ]; then
    # Radius-one diffusion needs four halo cells on each side.
    printf 'grid_per_block: [24, 24]\ntemporal_blocking_interval: %s\n' "$blocking" >> "$WORK/model.yaml"
  fi
  (cd "$WORK" && "${FORMURA:-$ROOT/bin/formura}" model.fmr > formura.log 2>&1) || {
    cat "$WORK/formura.log" >&2
    exit 1
  }
  "${CC:-cc}" -O2 -std=c11 -I"$WORK" -I"$ROOT/mpistub" "$WORK/check.c" "$WORK/model.c" -lm -o "$WORK/check"
  "$WORK/check"
done

for operation in sampleLower sampleUpper; do
  cat > "$WORK/bad.fme" <<EOF
dimension 2
axes x, y
field u
field v_i @ primal
step:
  v'_i = [| $operation(u,2,0), $operation(u,0,1) |]_i
EOF
  if cabal run -v0 formurae-pre -- "$WORK/bad.fme" > "$WORK/bad.out" 2> "$WORK/bad.err"; then
    printf 'accepted invalid placement bit in %s\n' "$operation" >&2
    exit 1
  fi
  grep -F 'literal 0 or 1' "$WORK/bad.err" >/dev/null
  test ! -s "$WORK/bad.out"
done
printf 'side sampling: source coordinates, both axes, both directions, populations, periodic halos and blocking passed\n'
