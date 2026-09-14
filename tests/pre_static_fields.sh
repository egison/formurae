#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
EGISON_DIR=${EGISON_DIR:-"$ROOT/../egison"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/formurae-static-fields.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
cd "$ROOT"

normalize() {
  cabal run -v0 formurae-pre -- "$1" > "$WORK/model.egi"
  "$ROOT/tools/run_formurae_normalization.sh" "$EGISON_DIR" \
    "$WORK/model.egi" > "$WORK/model.feir"
}
normalize tests/fixtures/pre_static_fields.fme
cabal run -v0 formurae-post -- "$WORK/model.feir" > "$WORK/model.fmr"
grep -F 'doubled[i,j] = 2 * J[i,j]' "$WORK/model.fmr" >/dev/null
grep -F "G_down1_down2'[i,j] = G_down1_down2[i,j]" "$WORK/model.fmr" >/dev/null
grep -F "v_down1'[i,j] = v_down1[i,j]" "$WORK/model.fmr" >/dev/null
grep -F "T_up2_down1'[i,j] = T_up2_down1[i,j]" "$WORK/model.fmr" >/dev/null
grep -F "W_down1_down2'[i,j] = W_down1_down2[i,j]" "$WORK/model.fmr" >/dev/null

# Check the same static dependency and staggered sampling in generated C,
# with and without multiple time steps grouped into a block.
cp tests/static_fields_check.c "$WORK/check.c"
for blocking in 0 4; do
  cat > "$WORK/model.yaml" <<EOF
length_per_node: [6.283185307179586, 6.283185307179586]
grid_per_node: [16, 16]
mpi_shape: [1, 1]
boundary: [periodic, periodic]
EOF
  if [ "$blocking" != 0 ]; then
    printf 'grid_per_block: [16, 16]\ntemporal_blocking_interval: %s\n' \
      "$blocking" >> "$WORK/model.yaml"
  fi
  (cd "$WORK" && "${FORMURA:-$ROOT/bin/formura}" model.fmr > formura.log 2>&1)
  "${CC:-cc}" -O2 -std=c11 -I"$WORK" -I"$ROOT/mpistub" \
    "$WORK/check.c" "$WORK/model.c" -lm -o "$WORK/check"
  "$WORK/check"
done

# These are normalized before validation, so dependencies hidden in a def,
# raw Egison let, a conditional, or another tensor component remain checked.
for expression in 'u' 'hidden' 'rawHidden' 'if x > 0 then 1 else u' "A'" 'B'; do
  cat > "$WORK/bad.fme" <<EOF
dimension 1
axes x
field u : scalar
def hidden = u
def rawHidden = let value := u in value
static field A : scalar := $expression
static field B : scalar := 1
init:
  u := 0
step:
  u' = u
EOF
  normalize "$WORK/bad.fme"
  if cabal run -v0 formurae-post -- "$WORK/model.feir" \
       > "$WORK/bad.out" 2> "$WORK/bad.err"; then
    printf 'accepted invalid static dependency: %s\n' "$expression" >&2
    exit 1
  fi
  grep -F 'static field initializer cannot depend on' "$WORK/bad.err" >/dev/null
  grep -F 'bad.fme:6:' "$WORK/bad.err" >/dev/null
  test ! -s "$WORK/bad.out"
done

cat > "$WORK/tensor-bad.fme" <<'EOF'
dimension 2
axes x, y
field u : scalar
static field A_i @ collocated := [| 1, u |]_i
init:
  u := 0
step:
  u' = u
EOF
normalize "$WORK/tensor-bad.fme"
if cabal run -v0 formurae-post -- "$WORK/model.feir" \
     > "$WORK/bad.out" 2> "$WORK/bad.err"; then
  printf 'accepted a dynamic component in a static tensor\n' >&2
  exit 1
fi
grep -F 'static field initializer cannot depend on' "$WORK/bad.err" >/dev/null
grep -F 'tensor-bad.fme:4:' "$WORK/bad.err" >/dev/null

for extra in "step:
  A' = A" 'init:
  A := 2'; do
  cat > "$WORK/bad.fme" <<EOF
dimension 1
axes x
static field A : scalar := 1
$extra
EOF
  if cabal run -v0 formurae-pre -- "$WORK/bad.fme" \
       > "$WORK/bad.out" 2> "$WORK/bad.err"; then
    printf 'accepted modification of static field\n' >&2
    exit 1
  fi
  grep -F "static field 'A'" "$WORK/bad.err" >/dev/null
done
printf 'static field pipeline tests: ok\n'
