#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "kleingordon.h"

/* phi^4 kink-antikink pair boosted toward each other at v = +-0.2.
 * Checks: (1) both center velocities measured from zero crossings,
 * (2) total energy equals the relativistic 2*gamma*E_kink with
 * E_kink = 2*sqrt(2)/3, (3) leapfrog energy drift stays small,
 * (4) no blowup (reduce_pmax bounded). */

#define NX 256

static double bp[NX], bw[NX];

static void logicalCopy(Formura_Navi n) {
  for (int i = n.lower_x; i < n.upper_x; i++) {
    int c = (int)floor(to_pos_x(i, n) / n.space_interval_x + 0.5);
    c = ((c % NX) + NX) % NX;
    bp[c] = formura_data.phi[i][2][2];
    bw[c] = formura_data.w[i][2][2];
  }
}

/* unique up-crossing (kink, dir>0) or down-crossing (antikink) in cells */
static double crossing(int dir) {
  for (int c = 0; c < NX; c++) {
    double a = bp[c], b = bp[(c + 1) % NX];
    if (dir > 0 ? (a < 0 && b >= 0) : (a >= 0 && b < 0))
      return c + a / (a - b);
  }
  return -1;
}

static double energy(double h) {
  double E = 0;
  for (int c = 0; c < NX; c++) {
    double g = (bp[(c + 1) % NX] - bp[c]) / h;
    double v = bp[c] * bp[c] - 1.0;
    E += h * (0.5 * bw[c] * bw[c] + 0.5 * g * g + 0.25 * v * v);
  }
  return E;
}

static double wrapd(double d, double L) {
  while (d >= L / 2) d -= L;
  while (d < -L / 2) d += L;
  return d;
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 800;
  double dt = 0.05;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  double h = n.space_interval_x, L = n.length_x;

  logicalCopy(n);
  double xk0 = crossing(+1) * h, xa0 = crossing(-1) * h, E0 = energy(h);

  while (n.time_step < steps) Formura_Forward(&n);

  logicalCopy(n);
  double T = steps * dt;
  double vk = wrapd(crossing(+1) * h - xk0, L) / T;
  double va = wrapd(crossing(-1) * h - xa0, L) / T;
  double E1 = energy(h);
  double Eth = 2.0 * (2.0 * sqrt(2.0) / 3.0) / sqrt(1.0 - 0.2 * 0.2);
  double edrift = fabs(E1 - E0) / E0, eth = fabs(E1 - Eth) / Eth;

  printf("t=%.1f  vk=%.4f (exact +0.2)  va=%.4f (exact -0.2)\n", T, vk, va);
  printf("       E=%.5f (relativistic 2*gamma*E_kink=%.5f, dev %.2e)  drift=%.2e  pmax=%.3f\n",
         E1, Eth, eth, edrift, n.reduce_pmax);
  int ok = fabs(vk - 0.2) < 0.015 && fabs(va + 0.2) < 0.015
        && eth < 0.02 && edrift < 5e-3 && n.reduce_pmax < 1.5;
  printf("kink velocities + relativistic energy + conservation: [%s]\n", ok ? "OK" : "NG");
  Formura_Finalize();
  return ok ? 0 : 1;
}
