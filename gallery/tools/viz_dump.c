/* Generic field dumper for the gallery.  Compiled per example with
 *   -DHDR='"<example>.h"' -DNAME='"<name>"' -DOUTDIR='"..."'
 *   -DF1='formura_data.u[i][j][k]' [-DF2=... -DF3=...]
 * and one of
 *   -DDUMPS='{0,800}'                line dumps (x profile) at those steps
 *   -DDUMPS='{0,800}' -DSLICE        z-mid slice dumps (x-y matrix)
 *   -DSTRIP -DSTRIDE=5000 -DSTEPS=600000   one x row every STRIDE steps
 * All indices are remapped to logical cells via to_pos_*, so both the
 * drifting periodic path and the anchored boundary path dump the same
 * physical picture. */

#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include HDR

/* The same dumper is used for 1D, 2D, and 3D examples.  Existing gallery
 * calls default to 3D; low-dimensional calls pass -DDIM=1 or -DDIM=2 so the
 * compiler does not refer to navigation fields absent from their headers. */
#ifndef DIM
#define DIM 3
#endif
#ifndef AXIS_X
#define AXIS_X x
#endif
#ifndef AXIS_Y
#define AXIS_Y y
#endif
#ifndef AXIS_Z
#define AXIS_Z z
#endif

#define CAT2(a, b) a##b
#define CAT(a, b) CAT2(a, b)
#define NAV_FIELD2(n, prefix, axis) n.prefix##axis
#define NAV_FIELD(n, prefix, axis) NAV_FIELD2(n, prefix, axis)
#define AXIS_FUNC(prefix, axis) CAT(prefix, axis)

#ifdef F3
#define NF 3
#elif defined(F2)
#define NF 2
#else
#define NF 1
#endif

#define MAXN 1024

static int lx(Formura_Navi n, int i) {
  int N = NAV_FIELD(n, total_grid_, AXIS_X);
  int c = (int)floor(AXIS_FUNC(to_pos_, AXIS_X)(i, n)
                      / NAV_FIELD(n, space_interval_, AXIS_X) + 0.5);
  return ((c % N) + N) % N;
}
#if DIM >= 2
static int ly(Formura_Navi n, int j) {
  int N = NAV_FIELD(n, total_grid_, AXIS_Y);
  int c = (int)floor(AXIS_FUNC(to_pos_, AXIS_Y)(j, n)
                      / NAV_FIELD(n, space_interval_, AXIS_Y) + 0.5);
  return ((c % N) + N) % N;
}
#endif
#if DIM >= 3
static int lz(Formura_Navi n, int k) {
  int N = NAV_FIELD(n, total_grid_, AXIS_Z);
  int c = (int)floor(AXIS_FUNC(to_pos_, AXIS_Z)(k, n)
                      / NAV_FIELD(n, space_interval_, AXIS_Z) + 0.5);
  return ((c % N) + N) % N;
}
#endif

#if DIM >= 2
static int midJ(Formura_Navi n) {
  for (int j = NAV_FIELD(n, lower_, AXIS_Y);
       j < NAV_FIELD(n, upper_, AXIS_Y); j++)
    if (ly(n, j) == NAV_FIELD(n, total_grid_, AXIS_Y) / 2) return j;
  return NAV_FIELD(n, lower_, AXIS_Y);
}
#endif
#if DIM >= 3
static int midK(Formura_Navi n) {
  for (int k = NAV_FIELD(n, lower_, AXIS_Z);
       k < NAV_FIELD(n, upper_, AXIS_Z); k++)
    if (lz(n, k) == NAV_FIELD(n, total_grid_, AXIS_Z) / 2) return k;
  return NAV_FIELD(n, lower_, AXIS_Z);
}
#endif

static double a1[MAXN], a2[MAXN], a3[MAXN];

static void gatherLine(Formura_Navi n) {
  int j = 0, k = 0;
#if DIM >= 2
  j = midJ(n);
#endif
#if DIM >= 3
  k = midK(n);
#endif
  for (int i = NAV_FIELD(n, lower_, AXIS_X);
       i < NAV_FIELD(n, upper_, AXIS_X); i++) {
    int c = lx(n, i);
    a1[c] = F1;
#if NF > 1
    a2[c] = F2;
#endif
#if NF > 2
    a3[c] = F3;
#endif
  }
}

static void dumpLine(Formura_Navi n, int t) {
  char fn[512];
  snprintf(fn, sizeof fn, "%s/%s_t%d.txt", OUTDIR, NAME, t);
  FILE *f = fopen(fn, "w");
  gatherLine(n);
  for (int c = 0; c < NAV_FIELD(n, total_grid_, AXIS_X); c++) {
    fprintf(f, "%.10g %.16g", c * NAV_FIELD(n, space_interval_, AXIS_X), a1[c]);
#if NF > 1
    fprintf(f, " %.16g", a2[c]);
#endif
#if NF > 2
    fprintf(f, " %.16g", a3[c]);
#endif
    fputc('\n', f);
  }
  fclose(f);
}

#if DIM >= 3 && defined(SLICEX)
static double m2[MAXN][MAXN];

/* matrix over (axis2 rows, axis3 cols) at the outermost interior x */
static void dumpSliceX(Formura_Navi n, int t) {
  char fn[512];
  snprintf(fn, sizeof fn, "%s/%s_x_t%d.mat", OUTDIR, NAME, t);
  FILE *f = fopen(fn, "w");
  int i = NAV_FIELD(n, upper_, AXIS_X) - 1;
  for (int j = NAV_FIELD(n, lower_, AXIS_Y);
       j < NAV_FIELD(n, upper_, AXIS_Y); j++)
    for (int k = NAV_FIELD(n, lower_, AXIS_Z);
         k < NAV_FIELD(n, upper_, AXIS_Z); k++)
      m2[ly(n, j)][lz(n, k)] = F1;
  for (int cy = 0; cy < NAV_FIELD(n, total_grid_, AXIS_Y); cy++) {
    for (int cz = 0; cz < NAV_FIELD(n, total_grid_, AXIS_Z); cz++)
      fprintf(f, "%.10g ", m2[cy][cz]);
    fputc('\n', f);
  }
  fclose(f);
}
#endif

#if DIM >= 2 && defined(SLICE)
static double m1[MAXN][MAXN];

static void dumpSlice(Formura_Navi n, int t) {
  char fn[512];
  snprintf(fn, sizeof fn, "%s/%s_t%d.mat", OUTDIR, NAME, t);
  FILE *f = fopen(fn, "w");
#if DIM >= 3
  int k = midK(n);
#endif
  for (int i = NAV_FIELD(n, lower_, AXIS_X);
       i < NAV_FIELD(n, upper_, AXIS_X); i++)
    for (int j = NAV_FIELD(n, lower_, AXIS_Y);
         j < NAV_FIELD(n, upper_, AXIS_Y); j++)
      m1[ly(n, j)][lx(n, i)] = F1;
  for (int cy = 0; cy < NAV_FIELD(n, total_grid_, AXIS_Y); cy++) {
    for (int cx = 0; cx < NAV_FIELD(n, total_grid_, AXIS_X); cx++)
      fprintf(f, "%.10g ", m1[cy][cx]);
    fputc('\n', f);
  }
  fclose(f);
}
#endif

int main(int argc, char **argv) {
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);

#ifdef STRIP
  char fn[512];
  snprintf(fn, sizeof fn, "%s/%s_strip.mat", OUTDIR, NAME);
  FILE *f = fopen(fn, "w");
  for (;;) {
    gatherLine(n);
    for (int c = 0; c < NAV_FIELD(n, total_grid_, AXIS_X); c++)
      fprintf(f, "%.10g ", a1[c]);
    fputc('\n', f);
    if (n.time_step >= STEPS) break;
    int next = n.time_step + STRIDE;
    while (n.time_step < next) Formura_Forward(&n);
  }
  fclose(f);
#else
  int dumps[] = DUMPS;
  int nd = sizeof dumps / sizeof dumps[0];
  for (int d = 0; d < nd; d++) {
    while (n.time_step < dumps[d]) Formura_Forward(&n);
#ifdef SLICE
    dumpSlice(n, dumps[d]);
#endif
#ifdef SLICEX
    dumpSliceX(n, dumps[d]);
#endif
#if !defined(SLICE) && !defined(SLICEX)
    dumpLine(n, dumps[d]);
#endif
  }
#endif
  Formura_Finalize();
  return 0;
}
