#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "acoustic3d.h"

/* Impedance-matched pulse (p = Z vx) travels right at c = sqrt(kap/rho0)
 * = 1.  Checks: measured pulse speed from the circular mean of p^2,
 * acoustic energy conservation, and vy/vz staying exactly zero. */

static double centerOf(Formura_Navi n) {
  double C = 0, S = 0;
  int N = n.total_grid_x;
  for (int i = n.lower_x; i < n.upper_x; i++) {
    double w = formura_data.p[i][2][2] * formura_data.p[i][2][2];
    double th = 2.0 * M_PI * to_pos_x(i, n) / n.length_x;
    C += w * cos(th); S += w * sin(th);
  }
  double pos = atan2(S, C) / (2.0 * M_PI) * N;
  if (pos < 0) pos += N;
  return pos;
}

static double energy(Formura_Navi n) {
  double E = 0, kap = 1.0, rho0 = 1.0;
  for (int i = n.lower_x; i < n.upper_x; i++)
    for (int j = n.lower_y; j < n.upper_y; j++)
      for (int k = n.lower_z; k < n.upper_z; k++) {
        double p = formura_data.p[i][j][k];
        double v2 = formura_data.v_down1[i][j][k]*formura_data.v_down1[i][j][k]
                  + formura_data.v_down2[i][j][k]*formura_data.v_down2[i][j][k]
                  + formura_data.v_down3[i][j][k]*formura_data.v_down3[i][j][k];
        E += p*p/(2*kap) + 0.5*rho0*v2;
      }
  return E;
}

static double maxTrans(Formura_Navi n) {
  double m = 0;
  for (int i = n.lower_x; i < n.upper_x; i++)
    for (int j = n.lower_y; j < n.upper_y; j++)
      for (int k = n.lower_z; k < n.upper_z; k++) {
        double a = fabs(formura_data.v_down2[i][j][k]);
        double b = fabs(formura_data.v_down3[i][j][k]);
        if (a > m) m = a;
        if (b > m) m = b;
      }
  return m;
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 600;
  double dt = 0.0005;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  double x0 = centerOf(n), e0 = energy(n);

  while (n.time_step < steps) Formura_Forward(&n);

  double T = steps * dt;
  double d = centerOf(n) - x0;
  if (d < 0) d += n.total_grid_x;
  double c = d * n.space_interval_x / T;
  double edrift = fabs(energy(n) - e0) / e0;

  printf("t=%.2f  measured c=%.4f (exact 1)  energy drift=%.2e\n", T, c, edrift);
  printf("       max|vy,vz|=%.2e  pmax=%.3f\n", maxTrans(n), n.reduce_pmax);
  int ok = fabs(c - 1.0) < 0.05 && edrift < 0.02 && maxTrans(n) < 1e-12;
  printf("sound speed + energy conservation + transverse zero: [%s]\n", ok ? "OK" : "NG");
  Formura_Finalize();
  return ok ? 0 : 1;
}
