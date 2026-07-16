#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <limits.h>
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
 * Checks (run for the global Cartesian x, y, and z modes):
 *  1. Every l=1 Cartesian mode is an exact Laplace-Beltrami eigenmode:
 *     u(t) = e^{-2t} u0.  Compare against it pointwise and fit the
 *     decay rate (expected 2 + O(h^2)).
 *  2. Yin/Yang agreement on the overlap away from the rims.
 *  3. Max principle: dt is below the monotonicity bound and bilinear
 *     weights are convex, so extrema must shrink monotonically.
 *  4. Every cell is finite and all k slices remain identical.  The
 *     latter is the invariant subspace that makes the dummy z direction
 *     irrelevant to this spherical test.
 */

#define NTH 29
#define NPH 77
#define NZ  4

_Static_assert(L1 == NTH && L2 == NPH && L3 == NZ, "grid mismatch with yaml");

#define TH0 (5.0 * M_PI / 24.0)   /* must match the .fme symbolic 5π/24 */
#define PH0 (-19.0 * M_PI / 24.0) /* must match the .fme symbolic -19π/24 */
#define DT 0.0003

#define DONOR_MARGIN_MIN 4.0
#define ROUNDOFF_TOL 1e-12
#define MAX_PRINCIPLE_TOL 1e-13
#define LAYER_UNIFORMITY_TOL 1e-12
#define EIGENMODE_ERROR_TOL 5e-3
#define DECAY_RATE_TOL 0.04
#define OVERLAP_ERROR_TOL 5e-3

#define NTAB_MAX (2 * NPH + 2 * (NTH - 2))

static Formura_Grid_Struct panel[2];   /* [0] = Yin, [1] = Yang */
static double h, ph0;

typedef enum { MODE_X, MODE_Y, MODE_Z, MODE_COUNT } Mode;

static const char *modeName(Mode mode) {
  static const char *const names[MODE_COUNT] = {"x", "y", "z"};
  return names[mode];
}

/* own-frame angles -> the other panel's angles through T */
static void to_other(double th, double ph, double *thp, double *php) {
  double x = sin(th) * cos(ph), y = sin(th) * sin(ph), z = cos(th);
  *thp = acos(fmax(-1.0, fmin(1.0, y)));  /* z' = y  */
  *php = atan2(z, -x);                    /* (x',y') = (-x, z) */
}

/* Independent panel-to-global oracle.  Keep this explicit rather than
 * calling to_other: the eigenmode and transform checks must not share
 * the implementation whose signs and orientation they protect. */
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

static double modeValue(Mode mode, int pnl, double th, double ph) {
  double xyz[3];
  globalCartesian(pnl, th, ph, xyz);
  return xyz[mode];
}

/* one bilinear stencil per rim cell; by congruence + involution the
 * same table serves Yin->Yang and Yang->Yin */
typedef struct { int di, dj, si, sj; double w00, w10, w01, w11; } Stencil;
static Stencil tab[NTAB_MAX];
static int ntab = 0;

static int buildTable(void) {
  double margin = 1e9;
  ntab = 0;
  for (int i = 0; i < NTH; i++)
    for (int j = 0; j < NPH; j++) {
      if (i != 0 && i != NTH - 1 && j != 0 && j != NPH - 1) continue;
      double tp, pp;
      to_other(TH0 + i * h, ph0 + j * h, &tp, &pp);
      double p = (tp - TH0) / h, q = (pp - ph0) / h;
      if (!isfinite(p) || !isfinite(q)) {
        fprintf(stderr, "non-finite donor coordinate at rim (%d,%d)\n", i, j);
        return 0;
      }
      int si = (int)floor(p), sj = (int)floor(q);
      double a = p - si, b = q - sj;
      double m = fmin(fmin(p, NTH - 1 - p), fmin(q, NPH - 1 - q));
      if (m < margin) margin = m;
      if (si < 1 || si + 1 > NTH - 2 || sj < 1 || sj + 1 > NPH - 2) {
        fprintf(stderr, "donor outside safe region at rim (%d,%d): p=%g q=%g\n",
                i, j, p, q);
        return 0;
      }
      if (ntab >= NTAB_MAX) {
        fprintf(stderr, "internal error: rim stencil table overflow\n");
        return 0;
      }
      Stencil s = {i, j, si, sj,
                   (1 - a) * (1 - b), a * (1 - b), (1 - a) * b, a * b};
      double wsum = s.w00 + s.w10 + s.w01 + s.w11;
      if (!isfinite(wsum) || s.w00 < -ROUNDOFF_TOL || s.w10 < -ROUNDOFF_TOL ||
          s.w01 < -ROUNDOFF_TOL || s.w11 < -ROUNDOFF_TOL ||
          fabs(wsum - 1.0) > ROUNDOFF_TOL) {
        fprintf(stderr, "invalid bilinear weights at rim (%d,%d)\n", i, j);
        return 0;
      }
      tab[ntab++] = s;
    }
  if (ntab != NTAB_MAX) {
    fprintf(stderr, "internal error: expected %d rim stencils, built %d\n",
            NTAB_MAX, ntab);
    return 0;
  }
  printf("rim cells per panel: %d, worst donor margin: %.17g cells"
         " (required >= %.1f, roundoff tolerance %.1e)\n",
         ntab, margin, DONOR_MARGIN_MIN, ROUNDOFF_TOL);
  if (margin + ROUNDOFF_TOL < DONOR_MARGIN_MIN) {
    fprintf(stderr, "donor margin is below the required %.1f cells\n",
            DONOR_MARGIN_MIN);
    return 0;
  }
  return 1;
}

static double interp(double (*su)[NPH][NZ], const Stencil *s, int k) {
  return s->w00 * su[s->si][s->sj][k] + s->w10 * su[s->si + 1][s->sj][k]
       + s->w01 * su[s->si][s->sj + 1][k] + s->w11 * su[s->si + 1][s->sj + 1][k];
}

/* the overset boundary condition: mutual rim interpolation */
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

typedef struct {
  double mx, mn, layerDifference;
} FieldStats;

/* Inspect every stored value.  In particular, do not let comparisons
 * silently discard a NaN when computing extrema or error maxima. */
static int inspectField(const char *mode, int step, FieldStats *stats) {
  int nonfinite = 0, firstD = -1, firstI = -1, firstJ = -1, firstK = -1;
  stats->mx = -INFINITY;
  stats->mn = INFINITY;
  stats->layerDifference = 0.0;
  for (int d = 0; d < 2; d++)
    for (int i = 0; i < NTH; i++)
      for (int j = 0; j < NPH; j++)
        for (int k = 0; k < NZ; k++) {
          double v = panel[d].u[i][j][k];
          if (!isfinite(v)) {
            if (nonfinite == 0) {
              firstD = d; firstI = i; firstJ = j; firstK = k;
            }
            nonfinite++;
            continue;
          }
          if (v > stats->mx) stats->mx = v;
          if (v < stats->mn) stats->mn = v;
          if (isfinite(panel[d].u[i][j][0])) {
            double dz = fabs(v - panel[d].u[i][j][0]);
            if (dz > stats->layerDifference) stats->layerDifference = dz;
          }
        }
  if (nonfinite != 0) {
    fprintf(stderr, "[%s] step %d: %d non-finite field value(s); first at"
            " panel=%d i=%d j=%d k=%d\n", mode, step, nonfinite,
            firstD, firstI, firstJ, firstK);
    return 0;
  }
  return 1;
}

static int checkLayout(Formura_Navi n) {
  double th1 = TH0 + (NTH - 1) * h;
  double ph1 = PH0 + (NPH - 1) * h;
  if (!isfinite(h) || !isfinite(n.space_interval_phi) ||
      !isfinite(n.space_interval_z) || !isfinite(n.length_theta) ||
      !isfinite(n.length_phi) || !isfinite(n.length_z) ||
      n.lower_theta != 0 || n.upper_theta != NTH ||
      n.lower_phi != 0 || n.upper_phi != NPH ||
      n.lower_z != 0 || n.upper_z != NZ ||
      n.total_grid_theta != NTH || n.total_grid_phi != NPH ||
      n.total_grid_z != NZ ||
      fabs(n.space_interval_phi - h) > 1e-12 ||
      fabs(n.space_interval_z - h) > 1e-12 ||
      fabs(to_pos_theta(0, n)) > ROUNDOFF_TOL ||
      fabs(to_pos_theta(1, n) - h) > ROUNDOFF_TOL ||
      fabs(to_pos_phi(0, n)) > ROUNDOFF_TOL ||
      fabs(to_pos_phi(1, n) - h) > ROUNDOFF_TOL ||
      fabs(n.length_theta - NTH * h) > ROUNDOFF_TOL ||
      fabs(n.length_phi - NPH * h) > ROUNDOFF_TOL ||
      fabs(n.length_z - NZ * h) > ROUNDOFF_TOL ||
      fabs(TH0 - (0.25 * M_PI - 2.0 * h)) > ROUNDOFF_TOL ||
      fabs(th1 - (0.75 * M_PI + 2.0 * h)) > ROUNDOFF_TOL ||
      fabs(PH0 - (-0.75 * M_PI - 2.0 * h)) > ROUNDOFF_TOL ||
      fabs(ph1 - (0.75 * M_PI + 2.0 * h)) > ROUNDOFF_TOL) {
    fprintf(stderr, "unexpected grid layout or Yin-Yang panel extent\n");
    return 0;
  }
  return 1;
}

/* The compiler no longer materializes geometry arrays: the metric
 * coefficients are inlined into the generated flux stencils, so their
 * finiteness and z-uniformity are exercised implicitly by the field
 * evolution checks below. */


static int checkTransform(void) {
  /* Analytic anchors make the oracle independent of both implementations
   * below.  They fix the branch and signs of T, and the meaning of the
   * three global Cartesian axes used as eigenmodes. */
  const double angleAnchors[][4] = {
    {M_PI / 3.0, 0.0,         M_PI / 2.0,  5.0 * M_PI / 6.0},
    {M_PI / 3.0, M_PI / 2.0, M_PI / 6.0,  M_PI / 2.0},
    {M_PI / 3.0, -M_PI / 2.0, 5.0 * M_PI / 6.0, M_PI / 2.0},
    {2.0 * M_PI / 3.0, 0.0,  M_PI / 2.0, -5.0 * M_PI / 6.0}
  };
  for (size_t a = 0; a < sizeof angleAnchors / sizeof angleAnchors[0]; a++) {
    double tp, pp;
    to_other(angleAnchors[a][0], angleAnchors[a][1], &tp, &pp);
    double thError = fabs(tp - angleAnchors[a][2]);
    double phError = fabs(atan2(sin(pp - angleAnchors[a][3]),
                                 cos(pp - angleAnchors[a][3])));
    if (!isfinite(thError) || !isfinite(phError) ||
        thError > ROUNDOFF_TOL || phError > ROUNDOFF_TOL) {
      fprintf(stderr, "coordinate-transform analytic anchor %zu failed\n", a);
      return 0;
    }
  }

  const double cartesianAnchors[][6] = {
    {0, M_PI / 2.0, 0.0,        1.0,  0.0, 0.0},
    {1, M_PI / 2.0, 0.0,       -1.0,  0.0, 0.0},
    {1, 0.0,        0.0,        0.0,  1.0, 0.0},
    {1, M_PI / 2.0, M_PI / 2.0, 0.0,  0.0, 1.0}
  };
  for (size_t a = 0; a < sizeof cartesianAnchors / sizeof cartesianAnchors[0]; a++) {
    double xyz[3];
    globalCartesian((int)cartesianAnchors[a][0], cartesianAnchors[a][1],
                    cartesianAnchors[a][2], xyz);
    for (int q = 0; q < 3; q++)
      if (!isfinite(xyz[q]) || fabs(xyz[q] - cartesianAnchors[a][q + 3]) > ROUNDOFF_TOL) {
        fprintf(stderr, "global Cartesian analytic anchor %zu failed\n", a);
        return 0;
      }
  }

  double maxError = 0.0;
  for (int d = 0; d < 2; d++)
    for (int i = 0; i < NTH; i++)
      for (int j = 0; j < NPH; j++) {
        double th = TH0 + i * h, ph = ph0 + j * h;
        double tp, pp, from[3], throughOther[3];
        to_other(th, ph, &tp, &pp);
        globalCartesian(d, th, ph, from);
        globalCartesian(1 - d, tp, pp, throughOther);
        for (int q = 0; q < 3; q++) {
          double er = fabs(from[q] - throughOther[q]);
          if (!isfinite(er)) {
            fprintf(stderr, "coordinate transform produced a non-finite value"
                    " at panel=%d i=%d j=%d\n", d, i, j);
            return 0;
          }
          if (er > maxError) maxError = er;
        }
      }
  printf("coordinate-transform analytic anchors + Cartesian oracle: %.2e\n",
         maxError);
  if (maxError > ROUNDOFF_TOL) {
    fprintf(stderr, "coordinate transform has the wrong sign or orientation\n");
    return 0;
  }
  return 1;
}

static int runMode(Mode mode, int steps, Formura_Navi n,
                   const Formura_Grid_Struct *geometry) {
  const char *name = modeName(mode);

  /* both panels share the geometry (and hence the metric fields) that
   * Formura_Init just computed; only u differs, set here in GLOBAL
   * coordinates */
  panel[0] = *geometry;
  panel[1] = *geometry;
  for (int d = 0; d < 2; d++)
    for (int i = 0; i < NTH; i++)
      for (int j = 0; j < NPH; j++)
        for (int k = 0; k < NZ; k++)
          panel[d].u[i][j][k] = modeValue(mode, d, TH0 + i * h, ph0 + j * h);

  Formura_Navi nav[2]; nav[0] = n; nav[1] = n;
  FieldStats stats;
  if (!inspectField(name, 0, &stats)) return 0;
  double pmx = stats.mx, pmn = stats.mn, mx0 = stats.mx;
  double maxPrincipleRaw = 0.0;
  double layerDifference = stats.layerDifference;

  for (int t = 0; t < steps; t++) {
    for (int d = 0; d < 2; d++) {
      formura_data = panel[d];
      Formura_Forward(&nav[d]);
      panel[d] = formura_data;
    }
    exchange();
    if (!inspectField(name, t + 1, &stats)) return 0;
    maxPrincipleRaw = fmax(maxPrincipleRaw, fmax(stats.mx - pmx, pmn - stats.mn));
    layerDifference = fmax(layerDifference, stats.layerDifference);
    pmx = stats.mx; pmn = stats.mn;
  }

  /* 1. pointwise error against the exact eigenmode decay */
  double T = steps * DT, decay = exp(-2.0 * T), errmax = 0;
  for (int d = 0; d < 2; d++)
    for (int i = 0; i < NTH; i++)
      for (int j = 0; j < NPH; j++)
        for (int k = 0; k < NZ; k++) {
          double ex = decay * modeValue(mode, d, TH0 + i * h, ph0 + j * h);
          double er = fabs(panel[d].u[i][j][k] - ex);
          if (er > errmax) errmax = er;
        }
  double rate = -log(stats.mx / mx0) / T;

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
        for (int k = 0; k < NZ; k++) {
          double v = (1 - a) * (1 - b) * su[si][sj][k]
                   + a * (1 - b) * su[si + 1][sj][k]
                   + (1 - a) * b * su[si][sj + 1][k]
                   + a * b * su[si + 1][sj + 1][k];
          double er = fabs(panel[d].u[i][j][k] - v);
          if (er > ovlmax) ovlmax = er;
        }
        novl++;
      }

  printf("[%s] t=%.2f  max|u-exact e^{-2t}Y1|=%.2e  decay rate=%.4f/2\n",
         name, T, errmax, rate);
  printf("    overlap agreement (%d points, all %d k slices)=%.2e"
         "  k-slice difference=%.1e\n", novl, NZ, ovlmax, layerDifference);
  printf("    raw max-principle violation=%.17g  acceptance tolerance=%.1e\n",
         maxPrincipleRaw, MAX_PRINCIPLE_TOL);
  int ok = isfinite(errmax) && isfinite(rate) && isfinite(ovlmax) &&
           errmax < EIGENMODE_ERROR_TOL && fabs(rate - 2.0) < DECAY_RATE_TOL &&
           ovlmax < OVERLAP_ERROR_TOL &&
           maxPrincipleRaw <= MAX_PRINCIPLE_TOL &&
           layerDifference <= LAYER_UNIFORMITY_TOL;
  printf("[%s] eigenmode decay + overlap + max principle + finite k slices: [%s]\n",
         name, ok ? "OK" : "NG");
  return ok;
}

static int parseSteps(int argc, char **argv, int *steps) {
  *steps = 1000;
  if (argc <= 1) return 1;
  char *end;
  long n = strtol(argv[1], &end, 10);
  if (*argv[1] == '\0' || *end != '\0' || n <= 0 || n > INT_MAX) {
    fprintf(stderr, "usage: %s [positive-step-count]\n", argv[0]);
    return 0;
  }
  *steps = (int)n;
  return 1;
}

int main(int argc, char **argv) {
  int steps;
  if (!parseSteps(argc, argv, &steps)) return 2;

  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  h = n.space_interval_theta;
  ph0 = PH0;

  int setupOk = checkLayout(n) && checkTransform() && buildTable();
  if (!setupOk) {
    Formura_Finalize();
    return 1;
  }

  Formura_Grid_Struct geometry = formura_data;
  int ok = 1;
  for (Mode mode = MODE_X; mode < MODE_COUNT; mode++)
    if (!runMode(mode, steps, n, &geometry)) ok = 0;

  printf("yin-yang sphere: all global x/y/z l=1 modes: [%s]\n", ok ? "OK" : "NG");
  Formura_Finalize();
  return ok ? 0 : 1;
}
