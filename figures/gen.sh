#!/bin/sh
# Generate plot data (out/*.dat) for the paper figures:
#   yee_prof0/prof1/energy : Yee-FDTD, dt=0.5dx, TB4, 100 steps (t = 50 dx)
#   colloc01_prof1/energy  : collocated, dt=0.1dx, TB4, 500 steps (t = 50 dx)
#   colloc04tb_energy      : collocated, dt=0.4dx, TB4, 100 steps  (diverges)
#   colloc04nb_energy      : collocated, dt=0.4dx, no TB, 100 steps (bounded)
set -eu
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
FORMURA=$ROOT/bin/formura
CFLAGS="-O2 -std=c11 -I. -I$ROOT/mpistub"

rm -rf build out
mkdir -p out

prep() { # dir fmr-src yaml-body
  mkdir -p "build/$1"
  cp "$2" "build/$1/"
  printf '%s\n' "$3" > "build/$1/$(basename "$2" .fmr).yaml"
}

split_raw() { # dir prefix
  awk -v p="out/$2" '
    $1=="P0" {print $2, $3 > (p "_prof0.tmp")}
    $1=="P1" {print $2, $3 > (p "_prof1.tmp")}
    $1=="EN" {print $2, $3 > (p "_energy.dat")}' "build/$1/raw.txt"
  for f in "out/$2"_prof*.tmp; do
    [ -f "$f" ] && sort -n "$f" > "${f%.tmp}.dat" && rm "$f"
  done || true
}

YAML_TB='length_per_node: [1.0,0.125,0.125]
grid_per_node: [128,16,16]
grid_per_block: [8,8,8]
temporal_blocking_interval: 4
mpi_shape: [1,1,1]'

YAML_TB16='length_per_node: [1.0,0.125,0.125]
grid_per_node: [128,16,16]
grid_per_block: [16,16,16]
temporal_blocking_interval: 4
mpi_shape: [1,1,1]'

YAML_NB='length_per_node: [1.0,0.125,0.125]
grid_per_node: [128,16,16]
mpi_shape: [1,1,1]'

# --- Yee, dt=0.5dx, TB4 ---
prep yee "$ROOT/examples/maxwell3d_yee/maxwell3d_yee.fmr" "$YAML_TB"
(cd build/yee && "$FORMURA" maxwell3d_yee.fmr > /dev/null \
  && cc $CFLAGS -o run ../../dump_yee.c maxwell3d_yee.c -lm \
  && ./run 100 0.5 > raw.txt)
split_raw yee yee

# --- collocated, dt=0.1dx, TB4, 500 steps ---
prep c01 "$ROOT/examples/maxwell3d/maxwell3d.fmr" "$YAML_TB16"
(cd build/c01 && "$FORMURA" maxwell3d.fmr > /dev/null \
  && cc $CFLAGS -o run ../../dump_colloc.c maxwell3d.c -lm \
  && ./run 500 0.1 > raw.txt)
split_raw c01 colloc01

# --- collocated, dt=0.1dx, no TB, 500 steps ---
prep c01nb "$ROOT/examples/maxwell3d/maxwell3d.fmr" "$YAML_NB"
(cd build/c01nb && "$FORMURA" maxwell3d.fmr > /dev/null \
  && cc $CFLAGS -o run ../../dump_colloc.c maxwell3d.c -lm \
  && ./run 500 0.1 > raw.txt)
split_raw c01nb colloc01nb

# --- collocated, dt=0.4dx, TB4, 100 steps (diverges) ---
prep c04tb "$ROOT/examples/maxwell3d/maxwell3d.fmr" "$YAML_TB16"
sed -i '' 's/double :: dt = 0.1\*dx/double :: dt = 0.4*dx/' build/c04tb/maxwell3d.fmr
(cd build/c04tb && "$FORMURA" maxwell3d.fmr > /dev/null \
  && cc $CFLAGS -o run ../../dump_colloc.c maxwell3d.c -lm \
  && ./run 100 0.4 > raw.txt)
split_raw c04tb colloc04tb

# --- collocated, dt=0.4dx, no TB, 100 steps (bounded) ---
prep c04nb "$ROOT/examples/maxwell3d/maxwell3d.fmr" "$YAML_NB"
sed -i '' 's/double :: dt = 0.1\*dx/double :: dt = 0.4*dx/' build/c04nb/maxwell3d.fmr
(cd build/c04nb && "$FORMURA" maxwell3d.fmr > /dev/null \
  && cc $CFLAGS -o run ../../dump_colloc.c maxwell3d.c -lm \
  && ./run 100 0.4 > raw.txt)
split_raw c04nb colloc04nb

echo "generated:"
ls -la out/
