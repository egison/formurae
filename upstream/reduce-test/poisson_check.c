#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "poisson1d.h"

/* Drive Jacobi to convergence using the generated residual reduction,
 * then compare against the exact discrete solution
 *   q_i = (h2f/2) * (i+1) * (N-i)   for ghosts fixed to zero. */

int main(int argc, char **argv) {
  double tol = argc > 1 ? atof(argv[1]) : 1e-13;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  printf("t=0 res=%.3e tot=%.6f\n", n.reduce_res, n.reduce_tot);

  while (n.reduce_res > tol && n.time_step < 500000) Formura_Forward(&n);

  int N = n.total_grid_x;
  double h2f = 0.001, maxerr = 0;
  for (int i = n.lower_x; i < n.upper_x; i++) {
    double exact = 0.5 * h2f * (i + 1) * (N - i);
    double e = fabs(formura_data.q[i] - exact);
    if (e > maxerr) maxerr = e;
  }
  printf("converged at t=%d  res=%.3e  max|q-exact|=%.3e  tot=%.9f\n",
         n.time_step, n.reduce_res, maxerr, n.reduce_tot);
  int ok = n.reduce_res <= tol && maxerr < 1e-9;
  printf("poisson via [fixed 0.0] boundaries + reduce residual: [%s]\n", ok ? "OK" : "NG");
  return ok ? 0 : 1;
}
