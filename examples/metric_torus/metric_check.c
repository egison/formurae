#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "metric_torus.h"

/* Heat on a torus: the metric-weighted heat sum(sg*u) is conserved
 * exactly by the flux form; the extrema contract (maximum principle,
 * monitored via generated reductions); and the whole run must agree
 * with an independent reference implementation of the same
 * discretization written from the analytic coefficients. */

#define NX 128
#define NY 128

/* The volume weight is the analytic sqrt(g) of the declared embedding;
 * the compiler no longer materializes geometry arrays, it inlines the
 * coefficients into the generated flux stencils. */
static double H(Formura_Navi n) {
  double s = 0, h = 6.283185307179586 / 128;
  for (int i = n.lower_theta; i < n.upper_theta; i++) {
    int ci = ((i + n.offset_theta) % NX + NX) % NX;
    double sg = 2.0 + cos(ci * h);
    for (int j = n.lower_phi; j < n.upper_phi; j++)
      s += sg * formura_data.u[i][j][1];
  }
  return s;
}

static double ru[NX][NY], rn[NX][NY];

static void refRun(int steps, double dt, double h) {
  for (int i = 0; i < NX; i++)
    for (int j = 0; j < NY; j++)
      ru[i][j] = exp(cos(i*h) + cos(j*h) - 2.0);
  for (int t = 0; t < steps; t++) {
    for (int i = 0; i < NX; i++) {
      int ip = (i+1)%NX, im = (i-1+NX)%NX;
      double Ap = 2.0 + cos(i*h + h/2), Am = 2.0 + cos(i*h - h/2);
      double B = 1.0/(2.0 + cos(i*h)), sg = 2.0 + cos(i*h);
      for (int j = 0; j < NY; j++) {
        int jp = (j+1)%NY, jm = (j-1+NY)%NY;
        double fth = (Ap*(ru[ip][j]-ru[i][j]) - Am*(ru[i][j]-ru[im][j]))/(h*h);
        double fph = B*(ru[i][jp] - 2*ru[i][j] + ru[i][jm])/(h*h);
        rn[i][j] = ru[i][j] + dt*(fth + fph)/sg;
      }
    }
    for (int i = 0; i < NX; i++) for (int j = 0; j < NY; j++) ru[i][j] = rn[i][j];
  }
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 3000;
  double dt = 0.0005, h = 6.283185307179586/128;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  double H0 = H(n), mx0 = n.reduce_umax, mn0 = n.reduce_umin;

  while (n.time_step < steps) Formura_Forward(&n);

  refRun(steps, dt, h);
  double md = 0;
  for (int i = 0; i < NX; i++)
    for (int j = 0; j < NY; j++) {
      int ci = ((i + n.offset_theta) % NX + NX) % NX;
      int cj = ((j + n.offset_phi) % NY + NY) % NY;
      double d = fabs(formura_data.u[i][j][1] - ru[ci][cj]);
      if (d > md) md = d;
    }
  double hdrift = fabs(H(n) - H0)/fabs(H0);
  printf("t=%.2f  heat drift=%.2e  max|u-ref|=%.2e\n", steps*dt, hdrift, md);
  printf("        extrema: [%.4f, %.4f] -> [%.4f, %.4f]\n", mn0, mx0, n.reduce_umin, n.reduce_umax);
  int ok = hdrift < 1e-11 && md < 1e-11
        && n.reduce_umax < mx0 && n.reduce_umin > mn0;
  printf("metric-weighted conservation + reference + max principle: [%s]\n", ok ? "OK" : "NG");
  Formura_Finalize();
  return ok ? 0 : 1;
}
