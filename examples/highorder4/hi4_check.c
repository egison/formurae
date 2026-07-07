#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "highorder4.h"

/* Single Fourier mode sin(4x) under the derived 4th-order Laplacian.
 * Explicit Euler on one mode is exact: after n steps the amplitude is
 * A0 * (1 + lam4*dt)^n where lam4 is the discrete symbol of the derived
 * stencil.  Checks: (1) the run reproduces that to machine precision
 * (i.e. the generated stencil is exactly the derived one), (2) the
 * residual |lam4 + k^2| matches the theoretical 4th-order size
 * k^6 h^4 / 90 and is far below the 2nd-order size k^4 h^2 / 12. */

#define K 4.0

static double amp(Formura_Navi n) {
  double A = 0;
  int N = n.total_grid_x;
  for (int i = n.lower_x; i < n.upper_x; i++)
    A += formura_data.u[i][2][2] * sin(K * to_pos_x(i, n));
  return 2.0 * A / N;
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 100;
  double dt = 0.0005;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  double h = n.space_interval_x, kh = K * h;
  double a0 = amp(n);

  while (n.time_step < steps) Formura_Forward(&n);

  double lam4 = (-2.5 + (8.0/3.0)*cos(kh) - (1.0/6.0)*cos(2.0*kh)) / (h*h);
  double rExact = pow(1.0 + lam4*dt, steps);
  double rMeas = amp(n) / a0;
  double symErr = fabs(rMeas - rExact);

  double e4 = fabs(lam4 + K*K);
  double th4 = pow(K, 6.0) * pow(h, 4.0) / 90.0;
  double e2 = pow(K, 4.0) * h*h / 12.0;

  printf("t=%.3f  amp ratio %.12f vs exact discrete %.12f  |diff|=%.2e\n",
         steps*dt, rMeas, rExact, symErr);
  printf("        |lam4 + k^2| = %.4e  (4th-order theory k^6 h^4/90 = %.4e, 2nd-order size = %.4e)\n",
         e4, th4, e2);
  int ok = symErr < 1e-11 && e4 > 0.5*th4 && e4 < 1.5*th4 && e4 < e2/10.0;
  printf("derived stencil symbol (machine precision) + 4th-order residual: [%s]\n", ok ? "OK" : "NG");
  Formura_Finalize();
  return ok ? 0 : 1;
}
