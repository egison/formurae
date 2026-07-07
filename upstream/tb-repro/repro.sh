#!/bin/sh
# Map the trigger of the Formura 2.3.2 temporal-blocking defect.
# For each program, run TB4 vs no-TB and compare the per-variable
# VALUE MULTISETS bitwise (immune to array-internal translation).
set -eu
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
FORMURA=${FORMURA:-$ROOT/bin/formura}
STEPS=${STEPS:-8}

yaml_for() { # prog mode
  case "$1" in
    repro2d|reprodg)
      printf 'length_per_node: [1.0,1.0]\ngrid_per_node: [32,32]\nmpi_shape: [1,1]\n'
      [ "$2" = tb ] && printf 'grid_per_block: [8,8]\ntemporal_blocking_interval: 4\n' ;;
    repro3d|reproE)
      printf 'length_per_node: [1.0,1.0,1.0]\ngrid_per_node: [32,16,16]\nmpi_shape: [1,1,1]\n'
      [ "$2" = tb ] && printf 'grid_per_block: [8,8,8]\ntemporal_blocking_interval: 4\n' ;;
    repro3dg)
      printf 'length_per_node: [1.0,0.125,0.125]\ngrid_per_node: [128,16,16]\nmpi_shape: [1,1,1]\n'
      [ "$2" = tb ] && printf 'grid_per_block: [16,16,16]\ntemporal_blocking_interval: 4\n' ;;
    mxB|mxB?|repro[GHIJ])
      printf 'length_per_node: [1.0,0.125,0.125]\ngrid_per_node: [128,16,16]\nmpi_shape: [1,1,1]\n'
      [ "$2" = tb ] && printf 'grid_per_block: [8,8,8]\ntemporal_blocking_interval: 4\n' ;;
    maxwell3d|mx[ACD])
      printf 'length_per_node: [1.0,0.125,0.125]\ngrid_per_node: [128,16,16]\nmpi_shape: [1,1,1]\n'
      [ "$2" = tb ] && printf 'grid_per_block: [16,16,16]\ntemporal_blocking_interval: 4\n' ;;
    *)
      printf 'length_per_node: [1.0]\ngrid_per_node: [64]\nmpi_shape: [1]\n'
      [ "$2" = tb ] && printf 'grid_per_block: [8]\ntemporal_blocking_interval: 4\n' ;;
  esac
  return 0
}
driver_for() {
  case "$1" in
    repro2d|reprodg) echo dump2d.c ;;
    repro3d|repro3dg) echo dump3d.c ;;
    reproE|repro[GHIJ]) echo dumpE.c ;;
    maxwell3d|mx*)   echo dumpmx.c ;;
    reproxy)         echo dumpxy.c ;;
    *)               echo dump.c ;;
  esac
}

rm -rf build && mkdir -p build
for prog in ${PROGS:-repro1 repro2 repro2d reprodg reproxy repro3d maxwell3d}; do
  for mode in tb nb; do
    d="build/$prog-$mode"
    mkdir -p "$d"
    if [ "$prog" = maxwell3d ]; then cp "$ROOT/examples/maxwell3d/maxwell3d.fmr" "$d/"
    elif [ "$prog" = repro3dg ]; then cp repro3d.fmr "$d/repro3dg.fmr"
    else cp "$prog.fmr" "$d/"; fi
    yaml_for "$prog" "$mode" > "$d/$prog.yaml"
    (cd "$d" && "$FORMURA" "$prog.fmr" > /dev/null \
      && cc -O2 -std=c11 -I. -I"$ROOT/mpistub" -DHDR="\"$prog.h\"" \
           -o run "../../$(driver_for "$prog")" "$prog.c" -lm \
      && ./run "$STEPS" | sort > raw.txt \
      && awk '{print $1, $NF}' raw.txt | sort > vals.txt)
  done
  if diff -q "build/$prog-tb/vals.txt" "build/$prog-nb/vals.txt" > /dev/null; then
    pos="(positions also match)"
    diff -q "build/$prog-tb/raw.txt" "build/$prog-nb/raw.txt" > /dev/null || pos="(values match, POSITIONS differ)"
    echo "$prog: TB vs no-TB values bit-identical  [OK] $pos"
  else
    nd=$(diff "build/$prog-tb/vals.txt" "build/$prog-nb/vals.txt" | grep -c '^<' || true)
    echo "$prog: TB vs no-TB VALUES DIFFER ($nd lines)  [BUG]"
  fi
done
