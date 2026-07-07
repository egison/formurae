#!/bin/sh
set -eu
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
FORMURA=${FORMURA:-$ROOT/bin/formura}
rm -rf build && mkdir -p build/poisson
cp poisson1d.fmr build/poisson/
printf 'length_per_node: [1.0]\ngrid_per_node: [64]\nmpi_shape: [1]\nboundary: [fixed 0.0]\nreduces: [res = absmax d, tot = sum q]\n' > build/poisson/poisson1d.yaml
(cd build/poisson && "$FORMURA" poisson1d.fmr > /dev/null \
  && cc -O2 -std=c11 -I. -I"$ROOT/mpistub" -o check ../../poisson_check.c poisson1d.c -lm \
  && ./check 1e-13)
