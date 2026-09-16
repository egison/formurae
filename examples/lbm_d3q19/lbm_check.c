/* The FME model computes density, velocity and the Fourier projection.
 * Formura supplies their global reductions; this driver checks the decay
 * against the analytic viscosity and reports conservation and symmetry. */
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "lbm_d3q19.h"

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 1000;
  const double kk = 0.09817477042468103, tau = 0.8;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  double a0 = n.reduce_amplitude, m0 = n.reduce_mass;
  while (n.time_step < steps) Formura_Forward(&n);
  double a1 = n.reduce_amplitude;
  double nu = -log(a1 / a0) / (kk * kk * n.time_step);
  double nuth = (tau - 0.5) / 3.0;
  double mdrift = fabs(n.reduce_mass - m0) / m0;
  printf("t=%d  amp %.5f -> %.5f  measured nu=%.5f (BGK exact %.5f, dev %.2e)\n",
         n.time_step, a0, a1, nu, nuth, fabs(nu - nuth) / nuth);
  printf("      mass drift=%.2e  max|ux|=%.2e  max|uz|=%.2e\n",
         mdrift, n.reduce_ux, n.reduce_uz);
  int ok = isfinite(nu) && fabs(nu - nuth) / nuth < 0.02 &&
           mdrift < 1e-12 && n.reduce_ux < 1e-10 && n.reduce_uz < 1e-10;
  printf("BGK viscosity + exact mass conservation + symmetry: [%s]\n", ok ? "OK" : "NG");
  Formura_Finalize();
  return ok ? 0 : 1;
}
