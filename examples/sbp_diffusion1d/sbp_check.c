#include <stdio.h>
#include <math.h>
#include "sbp_diffusion1d.h"

/* SBP + SAT heat equation on the bounded interval [0, 63]:
 *   - the solution tracks the exact Dirichlet mode sin(pi x/L) e^{-k(pi/L)^2 t},
 *   - the energy in the SBP norm  E = sum_i H_i u_i^2  never grows,
 *   - the penalty keeps the walls pinned at zero.
 */

#define NX 64
#define KAPPA 1.0
#define DT (0.05)
#define LWALL 63.0

static double energy(void) {
  double e = 0.0;
  for (int ix = 0; ix < NX; ix++) {
    double w = (ix == 0 || ix == NX - 1) ? 0.5 : 1.0;
    e += w * formura_data.u[ix] * formura_data.u[ix];
  }
  return e;
}

static double mode_error(double t, double *amp) {
  double lambda = M_PI / LWALL;
  double decay = exp(-KAPPA * lambda * lambda * t);
  double err = 0.0;
  for (int ix = 0; ix < NX; ix++) {
    double exact = decay * sin(lambda * ix);
    double d = fabs(formura_data.u[ix] - exact);
    if (d > err) err = d;
  }
  *amp = decay;
  return err;
}

int main(int argc, char **argv) {
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);

  double e_prev = energy();
  const double e0 = e_prev;
  int ok_energy = 1;

  while (n.time_step < 2000) {
    Formura_Forward(&n);
    double e = energy();
    if (e > e_prev + 1e-12 * e0) ok_energy = 0;
    e_prev = e;
  }

  double amp;
  double err = mode_error(DT * n.time_step, &amp);
  double wall = fabs(formura_data.u[0]);
  double wallR = fabs(formura_data.u[NX - 1]);
  if (wallR > wall) wall = wallR;

  int ok_mode = err < 5e-3;
  int ok_wall = wall < 1e-3;

  printf("t=%.1f  exact amp=%.6f  max|u-exact|=%.3e  wall=%.3e\n",
         DT * n.time_step, amp, err, wall);
  printf("SBP energy: %.6e -> %.6e  monotone=[%s]\n", e0, e_prev,
         ok_energy ? "OK" : "NG");
  printf("SBP+SAT Dirichlet heat: mode error + energy + walls: [%s]\n",
         (ok_mode && ok_energy && ok_wall) ? "OK" : "NG");

  Formura_Finalize();
  return (ok_mode && ok_energy && ok_wall) ? 0 : 1;
}
