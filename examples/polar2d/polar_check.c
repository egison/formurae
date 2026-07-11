#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "polar2d.h"

/* Heat on a flat annulus in polar coordinates, r_phys = 1 + r in
 * [1,2], mirror walls in r, periodic phi.  Checks: independent
 * reference agreement, exact conservation of sum((1+r) u), and the
 * max principle. */

#define NX 64
#define NY 128

static double ru[NX][NY], rn[NX][NY], f1[NX + 1][NY];

static double H(Formura_Navi n) {
  double s = 0;
  for (int i = n.lower_r; i < n.upper_r; i++)
    for (int j = n.lower_phi; j < n.upper_phi; j++)
      s += formura_data.FormuraeInternalMetricVolume[i][j][1]
           * formura_data.u[i][j][1];
  return s;
}

static void refRun(int steps, double dt, double hx, double hy) {
  for (int i = 0; i < NX; i++)
    for (int j = 0; j < NY; j++)
      ru[i][j] = exp(-4.0 * (i * hx - 0.5) * (i * hx - 0.5)) * exp(cos(j * hy) - 1.0);
  for (int t = 0; t < steps; t++) {
    for (int j = 0; j < NY; j++) { f1[0][j] = 0.0; f1[NX][j] = 0.0; }
    for (int i = 0; i + 1 < NX; i++)
      for (int j = 0; j < NY; j++)
        f1[i + 1][j] = (1.0 + (i + 0.5) * hx) * (ru[i + 1][j] - ru[i][j]) / hx;
    for (int i = 0; i < NX; i++) {
      double B = 1.0 / (1.0 + i * hx), sg = 1.0 + i * hx;
      for (int j = 0; j < NY; j++) {
        int jp = (j + 1) % NY, jm = (j + NY - 1) % NY;
        double fph = B * (ru[i][jp] - 2 * ru[i][j] + ru[i][jm]) / (hy * hy);
        rn[i][j] = ru[i][j] + dt * ((f1[i + 1][j] - f1[i][j]) / hx + fph) / sg;
      }
    }
    for (int i = 0; i < NX; i++)
      for (int j = 0; j < NY; j++) ru[i][j] = rn[i][j];
  }
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 2000;
  double dt = 0.0001;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  double hx = n.space_interval_r, hy = n.space_interval_phi;
  double H0 = H(n), mx0 = n.reduce_umax, mn0 = n.reduce_umin;

  while (n.time_step < steps) Formura_Forward(&n);

  refRun(steps, dt, hx, hy);
  double md = 0;
  for (int i = n.lower_r; i < n.upper_r; i++)
    for (int j = n.lower_phi; j < n.upper_phi; j++) {
      double d = fabs(formura_data.u[i][j][1] - ru[i][j]);
      if (d > md) md = d;
    }
  double hd = fabs(H(n) - H0) / fabs(H0);
  printf("t=%.2f  heat drift=%.2e  max|u-ref|=%.2e\n", steps * dt, hd, md);
  printf("        extrema: [%.4f, %.4f] -> [%.4f, %.4f]\n",
         mn0, mx0, n.reduce_umin, n.reduce_umax);
  int ok = hd < 1e-11 && md < 1e-11 && n.reduce_umax < mx0 && n.reduce_umin >= mn0;
  printf("polar annulus: conservation + reference + max principle: [%s]\n", ok ? "OK" : "NG");
  Formura_Finalize();
  return ok ? 0 : 1;
}
