#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "dirichlet_diffusion.h"

/* Diffusion between fixed-0 walls (the fork's boundary support).
 * The initial condition is the fundamental discrete Dirichlet mode, an
 * exact eigenvector of the discrete Laplacian with ghost-cell walls:
 *   lam = -(4 kappa / h^2) sin^2(pi / (2 (N+1))).
 * Explicit Euler then gives amplitude (1 + lam dt)^n exactly, and the
 * profile must stay proportional to the mode (all other modes decay
 * faster).  The anchored non-periodic path has no array drift, so raw
 * indices address the physical cells directly. */

#define NX 64

static double phi(int i) { return sin(M_PI * (i + 1.0) / (NX + 1.0)); }

static double amp(Formura_Navi n) {
  double a = 0, w = 0;
  for (int i = n.lower_x; i < n.upper_x; i++) {
    a += formura_data.u[i][2][2] * phi(i);
    w += phi(i) * phi(i);
  }
  return a / w;
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 5000;
  double dt = 0.00002;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  double h = n.space_interval_x;
  double a0 = amp(n);

  while (n.time_step < steps) Formura_Forward(&n);

  double lam = -(4.0 / (h * h)) * pow(sin(M_PI / (2.0 * (NX + 1.0))), 2);
  double rExact = pow(1.0 + lam * dt, steps);
  double rMeas = amp(n) / a0;

  /* mode purity: pointwise ratio to the eigenvector must be uniform */
  double dev = 0;
  for (int i = n.lower_x; i < n.upper_x; i++)
    if (phi(i) > 0.1) {
      double d = fabs(formura_data.u[i][2][2] / phi(i) - rMeas * a0);
      if (d > dev) dev = d;
    }

  printf("t=%.2f  amp ratio %.12f vs exact discrete (1+lam*dt)^n %.12f  |diff|=%.2e\n",
         steps * dt, rMeas, rExact, fabs(rMeas - rExact));
  printf("       mode purity max dev=%.2e   umax(reduce)=%.4f\n", dev, n.reduce_umax);
  int ok = fabs(rMeas - rExact) < 1e-11 && dev < 1e-9 && n.reduce_umax < 1.0;
  printf("Dirichlet walls: exact discrete eigen-decay + mode purity: [%s]\n", ok ? "OK" : "NG");
  Formura_Finalize();
  return ok ? 0 : 1;
}
