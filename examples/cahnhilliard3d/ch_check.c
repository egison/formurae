#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "cahnhilliard3d.h"

/* Spinodal decomposition sanity: mass (sum c, via the generated global
 * reduction) conserved to rounding, free energy monotonically
 * decreasing, phases separating toward c = +-1, values bounded. */

static double freeEnergy(Formura_Navi n) {
  double F = 0, kap = 2.0;
  for (int i = n.lower_x; i < n.upper_x; i++)
    for (int j = n.lower_y; j < n.upper_y; j++)
      for (int k = n.lower_z; k < n.upper_z; k++) {
        double v = formura_data.c[i][j][k];
        int ip = (i+1) % n.total_grid_x, jp = (j+1) % n.total_grid_y, kp = (k+1) % n.total_grid_z;
        double gx = formura_data.c[ip][j][k] - v;
        double gy = formura_data.c[i][jp][k] - v;
        double gz = formura_data.c[i][j][kp] - v;
        F += 0.25*(v*v-1)*(v*v-1) + 0.5*kap*(gx*gx+gy*gy+gz*gz);
      }
  return F;
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 25000;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  double tot0 = n.reduce_tot, F0 = freeEnergy(n), Fprev = F0;
  printf("t=0  tot=%.12e  F=%.4f\n", tot0, F0);
  int mono = 1;
  for (int b = 0; b < 10; b++) {
    while (n.time_step < steps*(b+1)/10) Formura_Forward(&n);
    double F = freeEnergy(n);
    if (F > Fprev + 1e-9) mono = 0;
    Fprev = F;
  }
  double mn = 1e300, mx = -1e300;
  for (int i = n.lower_x; i < n.upper_x; i++)
    for (int j = n.lower_y; j < n.upper_y; j++)
      for (int k = n.lower_z; k < n.upper_z; k++) {
        double v = formura_data.c[i][j][k];
        if (v < mn) mn = v;
        if (v > mx) mx = v;
      }
  double drift = fabs(n.reduce_tot - tot0) / (fabs(tot0) > 1 ? fabs(tot0) : 1);
  printf("t=%d  tot=%.12e  F=%.4f  c in [%.3f, %.3f]\n", n.time_step, n.reduce_tot, Fprev, mn, mx);
  int ok_mass = drift < 1e-9;
  int ok_sep  = mx > 0.6 && mn < -0.6 && mx < 1.4 && mn > -1.4;
  printf("mass [%s]  energy monotone [%s]  separation [%s]\n",
         ok_mass ? "OK" : "NG", mono ? "OK" : "NG", ok_sep ? "OK" : "NG");
  Formura_Finalize();
  return (ok_mass && mono && ok_sep) ? 0 : 1;
}
