/* Gallery dumper for the Yin-Yang overset sphere.  Same twin-panel drive
 * as yy_check.c -- two copies of the grid struct swapped through
 * formura_data around Formura_Forward, mutual bilinear rim interpolation
 * after every step -- but initialized with one localized Gaussian bump
 * written in GLOBAL coordinates (so the panels agree on their overlap)
 * and placed near the Yin panel's phi edge, so the heat visibly crosses
 * the seam onto Yang.  Dumps each panel's z-mid theta-phi matrix at the
 * requested steps.  Build like the check driver:
 *   cc -O2 -std=c11 -I. -Impistub -DOUTDIR='"..."' \
 *      yinyang_dump.c yinyang_diffusion.c -lm */
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "yinyang_diffusion.h"

#define NTH 29
#define NPH 77
#define NZ  4
#define TH0 (5.0 * M_PI / 24.0)
#define PH0 (-19.0 * M_PI / 24.0)
#define NTAB_MAX (2 * NPH + 2 * (NTH - 2))

static const int DUMPS[] = {0, 600};
#define NDUMP ((int)(sizeof DUMPS / sizeof DUMPS[0]))
#ifndef VIDEO_FRAMES
#define VIDEO_FRAMES 36
#endif
#ifndef VIDEO_END
#define VIDEO_END 600
#endif
#if VIDEO_FRAMES < 2
#error VIDEO_FRAMES must be at least 2
#endif

static Formura_Grid_Struct panel[2];
static double h, ph0;

static void to_other(double th, double ph, double *thp, double *php) {
  double x = sin(th) * cos(ph), y = sin(th) * sin(ph), z = cos(th);
  *thp = acos(fmax(-1.0, fmin(1.0, y)));
  *php = atan2(z, -x);
}

typedef struct { int di, dj, si, sj; double w00, w10, w01, w11; } Stencil;
static Stencil tab[NTAB_MAX];
static int ntab = 0;

static void buildTable(void) {
  ntab = 0;
  for (int i = 0; i < NTH; i++)
    for (int j = 0; j < NPH; j++) {
      if (i != 0 && i != NTH - 1 && j != 0 && j != NPH - 1) continue;
      double tp, pp;
      to_other(TH0 + i * h, ph0 + j * h, &tp, &pp);
      double p = (tp - TH0) / h, q = (pp - ph0) / h;
      int si = (int)floor(p), sj = (int)floor(q);
      double a = p - si, b = q - sj;
      if (si < 1 || si + 1 > NTH - 2 || sj < 1 || sj + 1 > NPH - 2) {
        fprintf(stderr, "donor outside safe region at rim (%d,%d)\n", i, j);
        exit(1);
      }
      Stencil s = {i, j, si, sj,
                   (1 - a) * (1 - b), a * (1 - b), (1 - a) * b, a * b};
      tab[ntab++] = s;
    }
}

static double interp(double (*su)[NPH][NZ], const Stencil *s, int k) {
  return s->w00 * su[s->si][s->sj][k] + s->w10 * su[s->si + 1][s->sj][k]
       + s->w01 * su[s->si][s->sj + 1][k] + s->w11 * su[s->si + 1][s->sj + 1][k];
}

static void exchange(void) {
  static double buf[2][NTAB_MAX][NZ];
  for (int d = 0; d < 2; d++)
    for (int m = 0; m < ntab; m++)
      for (int k = 0; k < NZ; k++)
        buf[d][m][k] = interp(panel[1 - d].u, &tab[m], k);
  for (int d = 0; d < 2; d++)
    for (int m = 0; m < ntab; m++)
      for (int k = 0; k < NZ; k++)
        panel[d].u[tab[m].di][tab[m].dj][k] = buf[d][m][k];
}

static void globalCartesian(int pnl, double th, double ph, double xyz[3]) {
  double lx = sin(th) * cos(ph);
  double ly = sin(th) * sin(ph);
  double lz = cos(th);
  if (pnl == 0) {
    xyz[0] = lx; xyz[1] = ly; xyz[2] = lz;
  } else {
    xyz[0] = -lx; xyz[1] = lz; xyz[2] = ly;
  }
}

/* bump center: on the equator at global phi = 2.2 rad, inside Yin but
 * close to its phi edge, so the spread has to cross onto Yang */
static double bump(int pnl, double th, double ph) {
  static const double c[3] = {-0.5885011172553458, 0.8084964038195899, 0.0};
  double xyz[3];
  globalCartesian(pnl, th, ph, xyz);
  double dot = xyz[0] * c[0] + xyz[1] * c[1] + xyz[2] * c[2];
  return exp(12.0 * (dot - 1.0));
}

static void dump(int step, int videoFrame) {
  static const char *const names[2] = {"yin", "yang"};
  for (int d = 0; d < 2; d++) {
    char path[512];
    if (videoFrame >= 0)
      snprintf(path, sizeof path, OUTDIR "/yy_%s_v%04d_t%d.mat",
               names[d], videoFrame, step);
    else
      snprintf(path, sizeof path, OUTDIR "/yy_%s_t%d.mat", names[d], step);
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); exit(1); }
    for (int i = 0; i < NTH; i++) {
      for (int j = 0; j < NPH; j++)
        fprintf(f, "%.10g ", panel[d].u[i][j][NZ / 2]);
      fputc('\n', f);
    }
    fclose(f);
  }
}

int main(int argc, char **argv) {
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  h = n.space_interval_theta;
  ph0 = PH0;
  buildTable();

  Formura_Grid_Struct geometry = formura_data;
  panel[0] = geometry;
  panel[1] = geometry;
  for (int d = 0; d < 2; d++)
    for (int i = 0; i < NTH; i++)
      for (int j = 0; j < NPH; j++)
        for (int k = 0; k < NZ; k++)
          panel[d].u[i][j][k] = bump(d, TH0 + i * h, ph0 + j * h);
  exchange();

  Formura_Navi nav[2];
  nav[0] = n; nav[1] = n;
  int next = 0, videoFrame = 0, last = DUMPS[NDUMP - 1];
  if (VIDEO_END > last) last = VIDEO_END;
  if (DUMPS[next] == 0) { dump(0, -1); next++; }
  if (videoFrame < VIDEO_FRAMES) { dump(0, videoFrame); videoFrame++; }
  for (int t = 1; t <= last; t++) {
    for (int d = 0; d < 2; d++) {
      formura_data = panel[d];
      Formura_Forward(&nav[d]);
      panel[d] = formura_data;
    }
    exchange();
    if (next < NDUMP && t == DUMPS[next]) { dump(t, -1); next++; }
    if (videoFrame < VIDEO_FRAMES
        && t == (int)(((long long)VIDEO_END * videoFrame) / (VIDEO_FRAMES - 1))) {
      dump(t, videoFrame);
      videoFrame++;
    }
  }
  printf("yinyang gallery dump: ok\n");
  Formura_Finalize();
  return 0;
}
