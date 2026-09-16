#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
EGISON_DIR=${EGISON_DIR:-"$ROOT/../egison"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/formurae-index-sizes.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
cd "$ROOT"

normalize() {
  cabal run -v0 formurae-pre -- "$1" > "$WORK/model.egi"
  "$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" \
    "$WORK/model.egi" > "$WORK/model.feir"
}
normalize tests/fixtures/pre_index_sizes.fme
cabal run -v0 formurae-post -- "$WORK/model.feir" > "$WORK/model.fmr"
cp tests/index_sizes_check.c "$WORK/check.c"
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

expect_pre_failure() {
  message=$1
  cat > "$WORK/bad.fme"
  if cabal run -v0 formurae-pre -- "$WORK/bad.fme" > "$WORK/bad.out" 2> "$WORK/bad.err"; then
    printf 'accepted invalid index declaration/use: %s\n' "$message" >&2
    exit 1
  fi
  grep -F "$message" "$WORK/bad.err" >/dev/null
  test ! -s "$WORK/bad.out"
}
for size in 0 -1 2.5 huge 18446744073709551617; do
  expect_pre_failure 'positive integer size' <<EOF
dimension 2
axes x, y
index a : $size
EOF
done
expect_pre_failure 'duplicate index declaration' <<'EOF'
dimension 2
axes x, y
index a, a : 9
EOF
expect_pre_failure 'conflicts with a coordinate' <<'EOF'
dimension 2
axes x, y
index x : 9
EOF
for expression in 'f_i' '(f)_i' '∂_a f_a'; do
  case "$expression" in *∂*) message='non-spatial index';; *) message='does not match slot';; esac
  expect_pre_failure "$message" <<EOF
dimension 2
axes x, y
index a : 9
field f_a
init:
  f_a := [| 1,2,3,4,5,6,7,8,9 |]_a
step:
  f'_a = $expression
EOF
done
# Equal extents still denote distinct spaces; a species is not a direction.
expect_pre_failure 'does not match slot' <<'EOF'
dimension 2
axes x, y
index a : 2
field f_a
init:
  f_a := [| 1,2 |]_a
step:
  f'_i = f_a
EOF
expect_pre_failure 'spatial tensor' <<'EOF'
dimension 2
axes x, y
index a, b : 2
metric g
field f_a_b
init:
  f_a_b := g_a_b
step:
  f'_a_b = f_a_b
EOF
expect_pre_failure 'requires explicit indices' <<'EOF'
dimension 2
axes x, y
index a : 2
field f_a
init:
  f_a := [| 1,2 |]_a
step:
  local q : tensor @ primal = f
  f'_a = q_a
EOF
expect_pre_failure 'same size and space' <<'EOF'
dimension 2
axes x, y
index a : 2
field S{_a_i}
EOF
expect_pre_failure 'must precede' <<'EOF'
dimension 2
axes x, y
field f_a
index a : 9
EOF
expect_pre_failure 'conflicts with a coordinate or value' <<'EOF'
dimension 2
axes x, y
index a : 9
def scale a = a * 2
EOF
for name in pi metric tensorShape length; do
  expect_pre_failure 'reserved for normalization' <<EOF
dimension 2
axes x, y
index $name : 9
EOF
done
# Function results must also respect the declared index size.
cat > "$WORK/bad.fme" <<'EOF'
dimension 2
axes x, y
index a : 9
def small = [| 1,2 |]
field u : scalar
init:
  u := 0
step:
  u' = sum (tensorToList ((small)_a))
EOF
cabal run -v0 formurae-pre -- "$WORK/bad.fme" > "$WORK/model.egi"
if "$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" "$WORK/model.egi" > "$WORK/bad.out" 2> "$WORK/bad.err"; then
  printf 'accepted wrong-sized function result\n' >&2
  exit 1
fi
grep -F 'index extent does not match tensor slot' "$WORK/bad.err" >/dev/null
test ! -s "$WORK/bad.out"
printf 'index sizes: mixed shapes, contractions, diffusion, placement, blocking, rejection checks passed\n'
