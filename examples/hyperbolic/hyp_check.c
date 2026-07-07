#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "hyperbolic.h"

/* Heat on the Poincare half-plane (curvature -1), y_phys = 1 + y in
 * [1,2], mirror walls in y, periodic in x.  The hyperbolic Laplacian
 * is (1+y)^2 (u_xx + u_yy).  Checks: independent reference agreement,
 * exact conservation of sum(u / (1+y)^2), max principle. */

#define NX 128
#define NY 64

static double ru[NX][NY], rn[NX][NY], f2[NX][NY + 1];

static double H(Formura_Navi n) {
  double s = 0;
  for (int i = n.lower_x; i < n.upper_x; i++)
    for (int j = n.lower_y; j < n.upper_y; j++)
      s += formura_data.sg[i][j][1] * formura_data.u[i][j][1];
  return s;
}

static void refRun(int steps, double dt, double hx, double hy) {
  for (int i = 0; i < NX; i++)
    for (int j = 0; j < NY; j++)
      ru[i][j] = exp(cos(i * hx) - 1.0) * exp(-4.0 * (j * hy - 0.5) * (j * hy - 0.5));
  for (int t = 0; t < steps; t++) {
    for (int i = 0; i < NX; i++) {
      f2[i][0] = 0.0;
      f2[i][NY] = 0.0;
      for (int j = 0; j + 1 < NY; j++)
        f2[i][j + 1] = (ru[i][j + 1] - ru[i][j]) / hy;
    }
    for (int i = 0; i < NX; i++) {
      int ip = (i + 1) % NX, im = (i + NX - 1) % NX;
      for (int j = 0; j < NY; j++) {
        double yp = 1.0 + j * hy, sg = 1.0 / (yp * yp);
        double fx = (ru[ip][j] - 2 * ru[i][j] + ru[im][j]) / (hx * hx);
        rn[i][j] = ru[i][j] + dt * (fx + (f2[i][j + 1] - f2[i][j]) / hy) / sg;
      }
    }
    for (int i = 0; i < NX; i++)
      for (int j = 0; j < NY; j++) ru[i][j] = rn[i][j];
  }
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 5000;
  double dt = 0.00002;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  double hx = n.space_interval_x, hy = n.space_interval_y;
  double H0 = H(n), mx0 = n.reduce_umax, mn0 = n.reduce_umin;

  while (n.time_step < steps) Formura_Forward(&n);

  refRun(steps, dt, hx, hy);
  double md = 0;
  for (int i = n.lower_x; i < n.upper_x; i++)
    for (int j = n.lower_y; j < n.upper_y; j++) {
      double d = fabs(formura_data.u[i][j][1] - ru[i][j]);
      if (d > md) md = d;
    }
  double hd = fabs(H(n) - H0) / fabs(H0);
  printf("t=%.2f  heat drift=%.2e  max|u-ref|=%.2e\n", steps * dt, hd, md);
  printf("        extrema: [%.4f, %.4f] -> [%.4f, %.4f]\n",
         mn0, mx0, n.reduce_umin, n.reduce_umax);
  int ok = hd < 1e-11 && md < 1e-11 && n.reduce_umax < mx0 && n.reduce_umin >= mn0;
  printf("hyperbolic plane: conservation + reference + max principle: [%s]\n", ok ? "OK" : "NG");
  Formura_Finalize();
  return ok ? 0 : 1;
}
