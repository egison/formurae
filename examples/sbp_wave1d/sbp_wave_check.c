#include <stdio.h>
#include <math.h>
#include "sbp_wave1d.h"

/* SBP + SAT acoustic wave with pressure-release walls on [0, 63]:
 *   - the standing mode sin(pi x/L) returns to its initial shape after one
 *     period T = 2L (c = 1),
 *   - the SBP energy stays inside a tight band around its initial value
 *     (leapfrog time-staggering allows a small oscillation, the penalty
 *     only dissipates),
 *   - the walls stay pinned.
 */

#define NX 64
#define DT 0.2
#define LWALL 63.0

static double energy(void) {
  double e = 0.0;
  for (int ix = 0; ix < NX; ix++) {
    double w = (ix == 0 || ix == NX - 1) ? 0.5 : 1.0;
    e += 0.5 * w * formura_data.p[ix] * formura_data.p[ix];
  }
  for (int ix = 0; ix < NX - 1; ix++)
    e += 0.5 * formura_data.v[ix] * formura_data.v[ix];
  return e;
}

int main(int argc, char **argv) {
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);

  const double e0 = energy();
  double emax = e0, emin = e0;

  /* one full period: T = 2 L = 126, dt = 0.2 -> 630 steps */
  while (n.time_step < 630) {
    Formura_Forward(&n);
    double e = energy();
    if (e > emax) emax = e;
    if (e < emin) emin = e;
  }

  double lambda = M_PI / LWALL;
  double err = 0.0, wall = 0.0;
  for (int ix = 0; ix < NX; ix++) {
    double d = fabs(formura_data.p[ix] - sin(lambda * ix));
    if (d > err) err = d;
  }
  if (fabs(formura_data.p[0]) > wall) wall = fabs(formura_data.p[0]);
  if (fabs(formura_data.p[NX - 1]) > wall) wall = fabs(formura_data.p[NX - 1]);

  int ok_return = err < 2e-2;
  int ok_energy = emax < 1.02 * e0 && emin > 0.90 * e0;
  int ok_wall = wall < 5e-3;

  printf("t=%.1f  period return max|p-p0|=%.3e  wall=%.3e\n",
         DT * n.time_step, err, wall);
  printf("SBP energy band: [%.6e, %.6e] around %.6e  [%s]\n",
         emin, emax, e0, ok_energy ? "OK" : "NG");
  printf("SBP+SAT pressure-release wave: return + energy + walls: [%s]\n",
         (ok_return && ok_energy && ok_wall) ? "OK" : "NG");

  Formura_Finalize();
  return (ok_return && ok_energy && ok_wall) ? 0 : 1;
}
