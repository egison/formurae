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

#ifdef F3
#define NF 3
#elif defined(F2)
#define NF 2
#else
#define NF 1
#endif

#define MAXN 1024

static int lx(Formura_Navi n, int i) {
  int N = n.total_grid_x;
  int c = (int)floor(to_pos_x(i, n) / n.space_interval_x + 0.5);
  return ((c % N) + N) % N;
}
static int ly(Formura_Navi n, int j) {
  int N = n.total_grid_y;
  int c = (int)floor(to_pos_y(j, n) / n.space_interval_y + 0.5);
  return ((c % N) + N) % N;
}
static int lz(Formura_Navi n, int k) {
  int N = n.total_grid_z;
  int c = (int)floor(to_pos_z(k, n) / n.space_interval_z + 0.5);
  return ((c % N) + N) % N;
}

static int midJ(Formura_Navi n) {
  for (int j = n.lower_y; j < n.upper_y; j++)
    if (ly(n, j) == n.total_grid_y / 2) return j;
  return n.lower_y;
}
static int midK(Formura_Navi n) {
  for (int k = n.lower_z; k < n.upper_z; k++)
    if (lz(n, k) == n.total_grid_z / 2) return k;
  return n.lower_z;
}

static double a1[MAXN], a2[MAXN], a3[MAXN];

static void gatherLine(Formura_Navi n) {
  int j = midJ(n), k = midK(n);
  for (int i = n.lower_x; i < n.upper_x; i++) {
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
  for (int c = 0; c < n.total_grid_x; c++) {
    fprintf(f, "%.10g %.16g", c * n.space_interval_x, a1[c]);
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

#ifdef SLICEX
static double m2[MAXN][MAXN];

/* matrix over (axis2 rows, axis3 cols) at the outermost interior x */
static void dumpSliceX(Formura_Navi n, int t) {
  char fn[512];
  snprintf(fn, sizeof fn, "%s/%s_x_t%d.mat", OUTDIR, NAME, t);
  FILE *f = fopen(fn, "w");
  int i = n.upper_x - 1;
  for (int j = n.lower_y; j < n.upper_y; j++)
    for (int k = n.lower_z; k < n.upper_z; k++)
      m2[ly(n, j)][lz(n, k)] = F1;
  for (int cy = 0; cy < n.total_grid_y; cy++) {
    for (int cz = 0; cz < n.total_grid_z; cz++)
      fprintf(f, "%.10g ", m2[cy][cz]);
    fputc('\n', f);
  }
  fclose(f);
}
#endif

#ifdef SLICE
static double m1[MAXN][MAXN];

static void dumpSlice(Formura_Navi n, int t) {
  char fn[512];
  snprintf(fn, sizeof fn, "%s/%s_t%d.mat", OUTDIR, NAME, t);
  FILE *f = fopen(fn, "w");
  int k = midK(n);
  for (int i = n.lower_x; i < n.upper_x; i++)
    for (int j = n.lower_y; j < n.upper_y; j++)
      m1[ly(n, j)][lx(n, i)] = F1;
  for (int cy = 0; cy < n.total_grid_y; cy++) {
    for (int cx = 0; cx < n.total_grid_x; cx++)
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
    for (int c = 0; c < n.total_grid_x; c++) fprintf(f, "%.10g ", a1[c]);
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
