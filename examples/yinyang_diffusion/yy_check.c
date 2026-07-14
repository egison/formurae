#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "yinyang_diffusion.h"

/* Heat on the FULL unit sphere on the Yin-Yang overset grid
 * (Kageyama & Sato 2004).  The two panels are congruent under the
 * involution T(x,y,z) = (-x,z,y) (its own inverse, so one formula
 * converts either panel's coordinates into the other's), so ONE
 * compiled panel kernel serves both: the driver keeps two copies of
 * the grid struct, swaps each into formura_data around
 * Formura_Forward, and after every step overwrites the one-cell rim of
 * each panel with bilinear interpolation from the other panel.  With
 * the 2-cell panel margin every donor point sits >= ~4 cells inside
 * the source panel, so donors never touch the source rim and the
 * mutual exchange is order-independent.
 *
 * Checks:
 *  1. u0 = cos(theta_global) = Y_1^0 is an exact Laplace-Beltrami
 *     eigenmode: u(t) = e^{-2t} u0.  Compare against it pointwise and
 *     fit the decay rate (expected 2 + O(h^2)).
 *  2. Yin/Yang agreement on the overlap away from the rims.
 *  3. Max principle: dt is below the monotonicity bound and bilinear
 *     weights are convex, so extrema must shrink monotonically.
 */

#define NTH 29
#define NPH 77
#define NZ  4

_Static_assert(L1 == NTH && L2 == NPH && L3 == NZ, "grid mismatch with yaml");

#define TH0 0.6544984694978736   /* 5pi/24, must match the .fme embedding */

static Formura_Grid_Struct panel[2];   /* [0] = Yin, [1] = Yang */
static double h, ph0;

/* own-frame angles -> the other panel's angles through T */
static void to_other(double th, double ph, double *thp, double *php) {
  double x = sin(th) * cos(ph), y = sin(th) * sin(ph), z = cos(th);
  *thp = acos(fmax(-1.0, fmin(1.0, y)));  /* z' = y  */
  *php = atan2(z, -x);                    /* (x',y') = (-x, z) */
}

/* global colatitude cosine of a panel point (Yin frame = global) */
static double cosThetaG(int pnl, double th, double ph) {
  return pnl == 0 ? cos(th) : sin(th) * sin(ph);
}

/* one bilinear stencil per rim cell; by congruence + involution the
 * same table serves Yin->Yang and Yang->Yin */
typedef struct { int di, dj, si, sj; double w00, w10, w01, w11; } Stencil;
static Stencil tab[2 * NPH + 2 * (NTH - 2)];
static int ntab = 0;

static int buildTable(void) {
  double margin = 1e9;
  for (int i = 0; i < NTH; i++)
    for (int j = 0; j < NPH; j++) {
      if (i != 0 && i != NTH - 1 && j != 0 && j != NPH - 1) continue;
      double tp, pp;
      to_other(TH0 + i * h, ph0 + j * h, &tp, &pp);
      double p = (tp - TH0) / h, q = (pp - ph0) / h;
      int si = (int)floor(p), sj = (int)floor(q);
      double a = p - si, b = q - sj;
      double m = fmin(fmin(p, NTH - 1 - p), fmin(q, NPH - 1 - q));
      if (m < margin) margin = m;
      if (si < 1 || si + 1 > NTH - 2 || sj < 1 || sj + 1 > NPH - 2) {
        printf("donor outside safe region at rim (%d,%d): p=%g q=%g\n", i, j, p, q);
        return 0;
      }
      Stencil s = {i, j, si, sj,
                   (1 - a) * (1 - b), a * (1 - b), (1 - a) * b, a * b};
      tab[ntab++] = s;
    }
  printf("rim cells per panel: %d, worst donor margin: %.2f cells\n", ntab, margin);
  return 1;
}

static double interp(double (*su)[NPH][NZ], const Stencil *s) {
  return s->w00 * su[s->si][s->sj][1] + s->w10 * su[s->si + 1][s->sj][1]
       + s->w01 * su[s->si][s->sj + 1][1] + s->w11 * su[s->si + 1][s->sj + 1][1];
}

/* the overset boundary condition: mutual rim interpolation */
static void exchange(void) {
  static double buf[2][sizeof tab / sizeof tab[0]];
  for (int d = 0; d < 2; d++)
    for (int m = 0; m < ntab; m++)
      buf[d][m] = interp(panel[1 - d].u, &tab[m]);
  for (int d = 0; d < 2; d++)
    for (int m = 0; m < ntab; m++)
      for (int k = 0; k < NZ; k++)
        panel[d].u[tab[m].di][tab[m].dj][k] = buf[d][m];
}

static void extrema(double *mx, double *mn) {
  *mx = -1e30; *mn = 1e30;
  for (int d = 0; d < 2; d++)
    for (int i = 0; i < NTH; i++)
      for (int j = 0; j < NPH; j++) {
        double v = panel[d].u[i][j][1];
        if (v > *mx) *mx = v;
        if (v < *mn) *mn = v;
      }
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 1000;
  double dt = 0.0003;                     /* must match the .fme param */
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  h = n.space_interval_theta;
  ph0 = -0.75 * M_PI - 2.0 * h;

  if (n.lower_theta != 0 || n.upper_theta != NTH ||
      fabs(n.space_interval_phi - h) > 1e-12 ||
      fabs(to_pos_theta(1, n) - h) > 1e-12) {
    printf("unexpected grid layout\n");
    return 1;
  }
  if (!buildTable()) return 1;

  /* both panels share the geometry (and hence the metric fields) that
   * Formura_Init just computed; only u differs, set here in GLOBAL
   * coordinates */
  panel[0] = formura_data;
  panel[1] = formura_data;
  for (int d = 0; d < 2; d++)
    for (int i = 0; i < NTH; i++)
      for (int j = 0; j < NPH; j++)
        for (int k = 0; k < NZ; k++)
          panel[d].u[i][j][k] = cosThetaG(d, TH0 + i * h, ph0 + j * h);

  Formura_Navi nav[2]; nav[0] = n; nav[1] = n;
  double mx, mn, pmx, pmn, monVio = 0;
  extrema(&pmx, &pmn);
  double mx0 = pmx;

  for (int t = 0; t < steps; t++) {
    for (int d = 0; d < 2; d++) {
      formura_data = panel[d];
      Formura_Forward(&nav[d]);
      panel[d] = formura_data;
    }
    exchange();
    extrema(&mx, &mn);
    if (mx > pmx + 1e-13) monVio = fmax(monVio, mx - pmx);
    if (mn < pmn - 1e-13) monVio = fmax(monVio, pmn - mn);
    pmx = mx; pmn = mn;
  }

  /* 1. pointwise error against the exact eigenmode decay */
  double T = steps * dt, decay = exp(-2.0 * T), errmax = 0;
  for (int d = 0; d < 2; d++)
    for (int i = 0; i < NTH; i++)
      for (int j = 0; j < NPH; j++) {
        double ex = decay * cosThetaG(d, TH0 + i * h, ph0 + j * h);
        double er = fabs(panel[d].u[i][j][1] - ex);
        if (er > errmax) errmax = er;
      }
  double rate = -log(mx / mx0) / T;

  /* 2. Yin/Yang agreement on the overlap, away from both rims */
  double ovlmax = 0; int novl = 0;
  for (int d = 0; d < 2; d++)
    for (int i = 1; i < NTH - 1; i++)
      for (int j = 1; j < NPH - 1; j++) {
        double tp, pp;
        to_other(TH0 + i * h, ph0 + j * h, &tp, &pp);
        double p = (tp - TH0) / h, q = (pp - ph0) / h;
        int si = (int)floor(p), sj = (int)floor(q);
        if (si < 1 || si + 1 > NTH - 2 || sj < 1 || sj + 1 > NPH - 2) continue;
        double a = p - si, b = q - sj;
        double (*su)[NPH][NZ] = panel[1 - d].u;
        double v = (1 - a) * (1 - b) * su[si][sj][1] + a * (1 - b) * su[si + 1][sj][1]
                 + (1 - a) * b * su[si][sj + 1][1] + a * b * su[si + 1][sj + 1][1];
        double er = fabs(panel[d].u[i][j][1] - v);
        if (er > ovlmax) ovlmax = er;
        novl++;
      }

  printf("t=%.2f  max|u-exact e^{-2t}Y1|=%.2e  decay rate=%.4f/2\n", T, errmax, rate);
  printf("        overlap agreement (%d pts)=%.2e  max-principle violation=%.1e\n",
         novl, ovlmax, monVio);
  int ok = errmax < 5e-3 && fabs(rate - 2.0) < 0.04 && ovlmax < 5e-3 && monVio == 0;
  printf("yin-yang sphere: eigenmode decay + overlap + max principle: [%s]\n",
         ok ? "OK" : "NG");
  Formura_Finalize();
  return ok ? 0 : 1;
}
