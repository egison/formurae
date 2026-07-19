#include <stdio.h>
#include <math.h>
#include "sbp_highorder4.h"

/* Fourth-order SBP + SAT heat equation on the bounded interval [0, 63]:
 *   - the solution tracks the exact Dirichlet mode sin(pi x/L) e^{-k(pi/L)^2 t},
 *   - the energy in the fourth-order SBP norm  E = sum_i H_i u_i^2  never grows,
 *   - the penalty keeps the walls pinned at zero.
 */

#ifndef NX
#define NX 64
#endif
#ifndef STEPS
#define STEPS 8000
#endif
#define KAPPA 1.0
#define LWALL ((double)(NX - 1) * DX)
#define DX (64.0 / (double)NX)
#define DT (0.0125 * DX * DX)

/* Boundary weights of the fourth-order staggered SBP primal norm. */
static const double h_edge[4] = {7.0 / 18.0, 9.0 / 8.0, 1.0, 71.0 / 72.0};

static double energy(void) {
  double e = 0.0;
  for (int ix = 0; ix < NX; ix++) {
    double w = 1.0;
    if (ix < 4) w = h_edge[ix];
    if (NX - 1 - ix < 4) w = h_edge[NX - 1 - ix];
    e += w * formura_data.u[ix] * formura_data.u[ix];
  }
  return e;
}

static double mode_error(double t, double *amp) {
  double lambda = M_PI / LWALL;
  double decay = exp(-KAPPA * lambda * lambda * t);
  double err = 0.0;
  for (int ix = 0; ix < NX; ix++) {
    double exact = decay * sin(lambda * ix * DX);
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

  while (n.time_step < STEPS) {
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

  int ok_mode = err < 1e-5;
  int ok_wall = wall < 1e-5;

  printf("t=%.1f  exact amp=%.6f  max|u-exact|=%.3e  wall=%.3e\n",
         DT * n.time_step, amp, err, wall);
  printf("SBP4 energy: %.6e -> %.6e  monotone=[%s]\n", e0, e_prev,
         ok_energy ? "OK" : "NG");
  printf("SBP4+SAT Dirichlet heat: mode error + energy + walls: [%s]\n",
         (ok_mode && ok_energy && ok_wall) ? "OK" : "NG");

  Formura_Finalize();
  return (ok_mode && ok_energy && ok_wall) ? 0 : 1;
}
