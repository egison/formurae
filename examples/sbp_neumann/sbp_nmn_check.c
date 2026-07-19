#include <stdio.h>
#include <math.h>
#include "sbp_neumann.h"

/* SBP + SAT heat equation with adiabatic (Neumann) walls on [0, 63]:
 *   - the solution tracks the exact mode cos(pi x/L) e^{-k(pi/L)^2 t},
 *   - the energy in the SBP norm  E = sum_i H_i u_i^2  never grows,
 *   - the heat content  Q = sum_i H_i u_i  is conserved to rounding
 *     (the flux substitution is exact, no penalty parameter exists).
 */

#ifndef NX
#define NX 64
#endif
#ifndef STEPS
#define STEPS 2000
#endif
#define KAPPA 1.0
#define DX (64.0 / (double)NX)
#define DT (0.05 * DX * DX)
#define LWALL ((double)(NX - 1) * DX)

static double norm_weight(int ix) {
  return (ix == 0 || ix == NX - 1) ? 0.5 : 1.0;
}

static double energy(void) {
  double e = 0.0;
  for (int ix = 0; ix < NX; ix++)
    e += norm_weight(ix) * formura_data.u[ix] * formura_data.u[ix];
  return e;
}

static double heat(void) {
  double q = 0.0;
  for (int ix = 0; ix < NX; ix++)
    q += norm_weight(ix) * formura_data.u[ix];
  return q;
}

static double mode_error(double t, double *amp) {
  double lambda = M_PI / LWALL;
  double decay = exp(-KAPPA * lambda * lambda * t);
  double err = 0.0;
  for (int ix = 0; ix < NX; ix++) {
    double exact = decay * cos(lambda * ix * DX);
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
  const double q0 = heat();
  int ok_energy = 1;

  while (n.time_step < STEPS) {
    Formura_Forward(&n);
    double e = energy();
    if (e > e_prev + 1e-12 * e0) ok_energy = 0;
    e_prev = e;
  }

  double amp;
  double err = mode_error(DT * n.time_step, &amp);
  double drift = fabs(heat() - q0);

  int ok_mode = err < 5e-3;
  int ok_heat = drift < 1e-11;

  printf("t=%.1f  exact amp=%.6f  max|u-exact|=%.3e  heat drift=%.3e\n",
         DT * n.time_step, amp, err, drift);
  printf("SBP energy: %.6e -> %.6e  monotone=[%s]\n", e0, e_prev,
         ok_energy ? "OK" : "NG");
  printf("SBP+SAT Neumann heat: mode error + energy + conservation: [%s]\n",
         (ok_mode && ok_energy && ok_heat) ? "OK" : "NG");

  Formura_Finalize();
  return (ok_mode && ok_energy && ok_heat) ? 0 : 1;
}
