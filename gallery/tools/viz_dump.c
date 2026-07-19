/* Generic field dumper for the gallery.  Compiled per example with
 *   -DHDR='"<example>.h"' -DNAME='"<name>"' -DOUTDIR='"..."'
 *   -DF1='formura_data.u[i][j][k]' [-DF2=... -DF3=...]
 * and one of
 *   -DDUMPS='{0,800}'                line dumps (x profile) at those steps
 *   -DDUMPS='{0,800}' -DSLICE        z-mid slice dumps (x-y matrix)
 *   -DVIDEO_END=800 -DVIDEO_FRAMES=36
 *                                      additional evenly-spaced video frames
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
#if defined(VIDEO_FRAMES) && VIDEO_FRAMES < 2
#error VIDEO_FRAMES must be at least 2
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

static void outputPath(char *path, size_t size, const char *ext,
                       int t, int videoFrame) {
  if (videoFrame >= 0)
    snprintf(path, size, "%s/%s_v%04d_t%d.%s",
             OUTDIR, NAME, videoFrame, t, ext);
  else
    snprintf(path, size, "%s/%s_t%d.%s", OUTDIR, NAME, t, ext);
}

static void dumpLine(Formura_Navi n, int t, int videoFrame) {
  char fn[512];
  outputPath(fn, sizeof fn, "txt", t, videoFrame);
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
static void dumpSliceX(Formura_Navi n, int t, int videoFrame) {
  char fn[512];
  if (videoFrame >= 0)
    snprintf(fn, sizeof fn, "%s/%s_x_v%04d_t%d.mat",
             OUTDIR, NAME, videoFrame, t);
  else
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

static void dumpSlice(Formura_Navi n, int t, int videoFrame) {
  char fn[512];
  outputPath(fn, sizeof fn, "mat", t, videoFrame);
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
  int stripStep = 0;
#ifdef VIDEO_FRAMES
  int videoFrame = 0;
#endif
  while (stripStep <= STEPS
#ifdef VIDEO_FRAMES
         || videoFrame < VIDEO_FRAMES
#endif
        ) {
    int next = stripStep <= STEPS ? stripStep : 0x7fffffff;
#ifdef VIDEO_FRAMES
    int videoStep = videoFrame < VIDEO_FRAMES
      ? (int)(((long long)VIDEO_END * videoFrame) / (VIDEO_FRAMES - 1))
      : 0x7fffffff;
    if (videoStep < next) next = videoStep;
#endif
    while (n.time_step < next) Formura_Forward(&n);
    if (stripStep == next) {
      gatherLine(n);
      for (int c = 0; c < NAV_FIELD(n, total_grid_, AXIS_X); c++)
        fprintf(f, "%.10g ", a1[c]);
      fputc('\n', f);
      stripStep += STRIDE;
    }
#ifdef VIDEO_FRAMES
    if (videoFrame < VIDEO_FRAMES && videoStep == next) {
      dumpLine(n, next, videoFrame);
      videoFrame++;
    }
#endif
  }
  fclose(f);
#else
  int dumps[] = DUMPS;
  int nd = sizeof dumps / sizeof dumps[0];
  int d = 0;
#ifdef VIDEO_FRAMES
  int v = 0;
#endif
  while (d < nd
#ifdef VIDEO_FRAMES
         || v < VIDEO_FRAMES
#endif
        ) {
    int next = d < nd ? dumps[d] : 0x7fffffff;
#ifdef VIDEO_FRAMES
    int videoStep = v < VIDEO_FRAMES
      ? (int)(((long long)VIDEO_END * v) / (VIDEO_FRAMES - 1))
      : 0x7fffffff;
    if (videoStep < next) next = videoStep;
#endif
    while (n.time_step < next) Formura_Forward(&n);
    if (d < nd && dumps[d] == next) {
#ifdef SLICE
      dumpSlice(n, next, -1);
#endif
#ifdef SLICEX
      dumpSliceX(n, next, -1);
#endif
#if !defined(SLICE) && !defined(SLICEX)
      dumpLine(n, next, -1);
#endif
      d++;
    }
#ifdef VIDEO_FRAMES
    if (v < VIDEO_FRAMES && videoStep == next) {
#ifdef SLICE
      dumpSlice(n, next, v);
#endif
#ifdef SLICEX
      dumpSliceX(n, next, v);
#endif
#if !defined(SLICE) && !defined(SLICEX)
      dumpLine(n, next, v);
#endif
      v++;
    }
#endif
  }
#endif
  Formura_Finalize();
  return 0;
}
