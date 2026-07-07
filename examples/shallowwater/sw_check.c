#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "shallowwater.h"

/* A 1% bump on still water splits into two gravity waves moving at
 * c = sqrt(g h0) = 1.  Checks: mass conserved exactly (flux form, via
 * the generated sum reduce), the y-momentum stays identically zero by
 * symmetry, the water stays positive, and the right-moving Riemann
 * invariant r = (h-1) + mx has centroid speed c. */

static double centroid(Formura_Navi n) {
  double C = 0, S = 0;
  int N = n.total_grid_x;
  for (int i = n.lower_x; i < n.upper_x; i++) {
    double r = (formura_data.h[i][2][2] - 1.0) + formura_data.mx[i][2][2];
    double th = 2.0 * M_PI * to_pos_x(i, n) / n.length_x;
    C += r * r * cos(th); S += r * r * sin(th);
  }
  double pos = atan2(S, C) / (2.0 * M_PI) * N;
  if (pos < 0) pos += N;
  return pos;
}

static double maxAbsMy(Formura_Navi n) {
  double m = 0;
  for (int i = n.lower_x; i < n.upper_x; i++)
    for (int j = n.lower_y; j < n.upper_y; j++)
      for (int k = n.lower_z; k < n.upper_z; k++) {
        double a = fabs(formura_data.my[i][j][k]);
        if (a > m) m = a;
      }
  return m;
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 400;
  double dt = 0.05;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  double m0 = n.reduce_mass, x0 = centroid(n);

  while (n.time_step < steps) Formura_Forward(&n);

  double T = steps * dt;
  double dx = centroid(n) - x0;
  if (dx < 0) dx += n.total_grid_x;
  double c = dx * n.space_interval_x / T;
  double mdrift = fabs(n.reduce_mass - m0) / m0;
  double my = maxAbsMy(n);

  printf("t=%.1f  gravity wave speed c=%.4f (exact 1)  mass drift=%.2e\n", T, c, mdrift);
  printf("       max|my|=%.2e (symmetry)  hmin=%.4f\n", my, n.reduce_hmin);
  int ok = fabs(c - 1.0) < 0.02 && mdrift < 1e-12 && my < 1e-10 && n.reduce_hmin > 0.9;
  printf("wave speed + exact mass conservation + symmetry: [%s]\n", ok ? "OK" : "NG");
  Formura_Finalize();
  return ok ? 0 : 1;
}
