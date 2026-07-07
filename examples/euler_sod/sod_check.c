#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "euler_sod.h"

/* Exact Sod solution (gamma = 1.4, standard left/right states), star
 * region constants from the exact Riemann solver:
 *   p* = 0.30313, u* = 0.92745, rho*L = 0.42632, rho*R = 0.26557,
 *   shock speed 1.75215, fan head -cL = -1.18322, fan tail -0.07027.
 * Density is compared in L1 around the x=12 diaphragm before the fans
 * from the two (periodic) diaphragms can interact; the sum reduces
 * check exact conservation of mass, momentum, and energy. */

#define GAM 1.4

static double rhoExact(double xi) {
  const double cL = 1.18322, tail = -0.07027;
  if (xi < -cL) return 1.0;
  if (xi < tail) {
    double c = (2.0 / (GAM + 1.0)) * (cL - (GAM - 1.0) / 2.0 * xi);
    return pow(c / cL, 2.0 / (GAM - 1.0));
  }
  if (xi < 0.92745) return 0.42632;
  if (xi < 1.75215) return 0.26557;
  return 0.125;
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 120;
  double dt = 0.01, x0 = 12.0;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  double m0 = n.reduce_mass, e0 = n.reduce_etot, p0 = n.reduce_momtot;

  while (n.time_step < steps) Formura_Forward(&n);

  double T = steps * dt, h = n.space_interval_x;
  double l1 = 0, rmin = 1e30, prmin = 1e30;
  int cnt = 0;
  for (int i = n.lower_x; i < n.upper_x; i++) {
    double x = to_pos_x(i, n);
    double rho = formura_data.rho[i][2][2];
    double mx = formura_data.mx[i][2][2];
    double en = formura_data.en[i][2][2];
    double pr = (GAM - 1.0) * (en - mx * mx / (2.0 * rho));
    if (rho < rmin) rmin = rho;
    if (pr < prmin) prmin = pr;
    if (x > 9.75 && x < 14.25) {
      l1 += fabs(rho - rhoExact((x - x0) / T));
      cnt++;
    }
  }
  l1 /= cnt;
  double md = fabs(n.reduce_mass - m0) / m0;
  double ed = fabs(n.reduce_etot - e0) / e0;
  double pd = fabs(n.reduce_momtot - p0);

  printf("t=%.2f  L1(rho) vs exact Riemann = %.4f  (window x in [9.75,14.25])\n", T, l1);
  printf("       mass drift=%.2e  energy drift=%.2e  |sum mx|=%.2e  rho_min=%.3f  p_min=%.3f\n",
         md, ed, pd, rmin, prmin);
  int ok = l1 < 0.03 && md < 1e-12 && ed < 1e-12 && pd < 1e-10 && rmin > 0 && prmin > 0;
  printf("Sod shock tube vs exact solution + conservation: [%s]\n", ok ? "OK" : "NG");
  Formura_Finalize();
  return ok ? 0 : 1;
}
