#!/bin/bash
# Generate the gallery's raw data: compile the generic dumper against
# each example's generated C (run `make all` first so the .c/.h exist)
# and run it.  Output goes to gallery/data/; render.py turns it into
# gallery/img/.
set -e
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
DATA=$PWD/data
TOOLS=$PWD/tools
mkdir -p "$DATA" img

CC=${CC:-cc}
FLAGS="-O2 -std=c11 -I$ROOT/mpistub"

run() { # name dir src extra-flags...
  local name=$1 dir=$2 src=$3; shift 3
  ( cd "$ROOT/examples/$dir" && \
    $CC $FLAGS -I. -DHDR="\"$src.h\"" -DNAME="\"$name\"" -DOUTDIR="\"$DATA\"" \
      "$@" -o viz "$TOOLS/viz_dump.c" "$src.c" -lm && ./viz )
  echo "ok: $name"
}

U='formura_data'

# --- long ones first ---
run cahnhilliard cahnhilliard3d cahnhilliard3d -DSLICE -DDUMPS='{0,25000}' \
  -DF1="$U.c[i][j][k]" &
CHPID=$!

run diffusion diffusion3d diffusion3d -DSLICE -DDUMPS='{0,100}' -DF1="$U.u[i][j][k]"
run maxwell maxwell3d maxwell3d -DDUMPS='{0,100}' -DF1="$U.Ey[i][j][k]" -DF2="$U.Bz[i][j][k]"
run yee maxwell3d_yee maxwell3d_yee -DDUMPS='{0,100}' -DF1="$U.Ey[i][j][k]" -DF2="$U.Bz[i][j][k]"
run burgers burgers3d burgers3d -DDUMPS='{0,5000}' -DF1="$U.u[i][j][k]"
run tdgl tdgl3d tdgl3d -DSLICE -DDUMPS='{0,4000}' \
  -DF1="$U.a[i][j][k]*$U.a[i][j][k]+$U.b[i][j][k]*$U.b[i][j][k]"
run elastic elastic3d elastic3d -DDUMPS='{0,600}' -DF1="$U.vx[i][j][k]" -DF2="$U.vy[i][j][k]"
run metric metric_torus metric_torus -DSLICE -DDUMPS='{0,1000,3000}' -DF1="$U.u[i][j][k]"
run kg kleingordon kleingordon -DDUMPS='{0,400,800}' -DF1="$U.phi[i][j][k]"
run sw shallowwater shallowwater -DDUMPS='{0,400}' -DF1="$U.h[i][j][k]" -DF2="$U.mx[i][j][k]"
run lbm lbm_d3q19 lbm_d3q19 -DDUMPS='{0,1000}' \
  -DF1="$U.f3[i][j][k]-$U.f4[i][j][k]+$U.f7[i][j][k]-$U.f8[i][j][k]-$U.f9[i][j][k]+$U.f10[i][j][k]+$U.f15[i][j][k]-$U.f16[i][j][k]+$U.f17[i][j][k]-$U.f18[i][j][k]"
run acoustic acoustic3d acoustic3d -DDUMPS='{0,600}' -DF1="$U.p[i][j][k]"
run sod euler_sod euler_sod -DDUMPS='{120}' -DF1="$U.rho[i][j][k]" \
  -DF2="0.4*($U.en[i][j][k]-$U.mx[i][j][k]*$U.mx[i][j][k]/(2.0*$U.rho[i][j][k]))" \
  -DF3="$U.mx[i][j][k]/$U.rho[i][j][k]"
run ks ks3d ks3d -DSTRIP -DSTRIDE=4000 -DSTEPS=600000 -DF1="$U.u[i][j][k]"
run dirichlet dirichlet_diffusion dirichlet_diffusion -DSTRIP -DSTRIDE=2500 -DSTEPS=10000 \
  -DF1="$U.u[i][j][k]"
run mhd mhd_ot mhd_ot -DSLICE -DDUMPS='{0,1250}' -DF1="$U.rho[i][j][k]"
run sphere metric_sphere metric_sphere -DSLICE -DDUMPS='{0,2000}' -DF1="$U.u[i][j][k]"
run hyp hyperbolic hyperbolic -DSLICE -DDUMPS='{0,5000}' -DF1="$U.u[i][j][k]"
run polar polar2d polar2d -DSLICE -DDUMPS='{0,2000}' -DF1="$U.u[i][j][k]"
run shell spherical3d spherical3d -DSLICE -DSLICEX -DDUMPS='{0,1000}' -DF1="$U.u[i][j][k]"

# pearson: reuse the PGM the check driver wrote during `make all`
cp "$ROOT/examples/pearson3d/pearson_V.pgm" "$DATA/pearson_V.pgm" 2>/dev/null || \
  echo "note: run 'make pearson3d' first for the pearson panel"

wait $CHPID
echo "all data generated in $DATA"
