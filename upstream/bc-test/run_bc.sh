#!/bin/sh
# Acceptance tests for boundary conditions (anchored NoBlocking path).
set -eu
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
FORMURA=${FORMURA:-$ROOT/bin/formura}
CC="cc -O2 -std=c11"
rm -rf build && mkdir -p build

yaml1d() { printf 'length_per_node: [1.0]\ngrid_per_node: [64]\nmpi_shape: [1]\nboundary: [%s]\n' "$1"; }

fail=0
for bc in mirror "fixed 0.5" periodic; do
  tag=$(echo "$bc" | tr ' ' '_')
  d="build/bc1d-$tag"; mkdir -p "$d"
  cp bc1d.fmr "$d/"
  yaml1d "$bc" > "$d/bc1d.yaml"
  (cd "$d" && "$FORMURA" bc1d.fmr > /dev/null \
    && $CC -I. -I"$ROOT/mpistub" -DHDR='"bc1d.h"' -o run ../../dump1d.c bc1d.c -lm \
    && ./run 200 | sort -n > out.txt)
  refbc=$(echo "$bc" | cut -d' ' -f1); refv=$(echo "$bc" | awk '{print $2}')
  $CC -o "$d/ref" ref1d.c -lm
  "$d/ref" 200 "$refbc" "${refv:-0}" > "$d/ref.txt"
  maxd=$(paste <(grep -v '^#' "$d/out.txt") "$d/ref.txt" | awk '{d=$2-$4; if(d<0)d=-d; if(d>m)m=d} END{printf "%.3e", m}')
  off=$(grep '^#' "$d/out.txt")
  echo "bc1d [$bc]: max|formura-ref| = $maxd   ($off)"
  ok=$(echo "$maxd" | awk '{print ($1 < 1e-12) ? 1 : 0}')
  [ "$ok" = 1 ] || fail=1
done

# conservation under mirror
d=build/bc1d-mirror
tot0=$(awk 'BEGIN{for(i=0;i<64;i++) s+=0.001*(i+1)*(i+3); printf "%.17e", s}')
tot1=$(grep -v '^#' $d/out.txt | awk '{s+=$2} END{printf "%.17e", s}')
echo "bc1d mirror: total $tot0 -> $tot1"

# 3D mixed boundaries
d="build/bc3d"; mkdir -p "$d"
cp bc3d.fmr "$d/"
printf 'length_per_node: [1.0,0.5,0.5]\ngrid_per_node: [32,16,16]\nmpi_shape: [1,1,1]\nboundary: [mirror, periodic, fixed 0.0]\n' > "$d/bc3d.yaml"
(cd "$d" && "$FORMURA" bc3d.fmr > /dev/null \
  && $CC -I. -I"$ROOT/mpistub" -DHDR='"bc3d.h"' -o run ../../dump3d.c bc3d.c -lm \
  && ./run 50 > out.txt)
$CC -o "$d/ref" ref3d.c -lm
"$d/ref" 50 > "$d/ref.txt"
maxd=$(paste <(grep -v '^#' "$d/out.txt") "$d/ref.txt" | awk '{d=$4-$8; if(d<0)d=-d; if(d>m)m=d} END{printf "%.3e", m}')
echo "bc3d [mirror,periodic,fixed]: max|formura-ref| = $maxd   ($(grep '^#' $d/out.txt))"
ok=$(echo "$maxd" | awk '{print ($1 < 1e-12) ? 1 : 0}')
[ "$ok" = 1 ] || fail=1

[ "$fail" = 0 ] && echo "ALL BC TESTS PASS" || { echo "BC TESTS FAILED"; exit 1; }
