#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "burgers3d.h"

/* Compare the generated viscous-Burgers solver against the exact
 * Cole-Hopf solution
 *   u(x,t) = 2 nu k B E sin(kx) / (A + B E cos(kx)),  E = exp(-nu k^2 t)
 * with A=2, B=1, k=2pi, nu=0.05.  This validates the nonlinear u*du/dx
 * term end to end. */

static double exact(double x, double t) {
  double nu = 0.05, k = 2.0 * M_PI, A = 2.0, B = 1.0;
  double E = exp(-nu * k * k * t);
  return 2.0 * nu * k * B * E * sin(k * x) / (A + B * E * cos(k * x));
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 5000;
  double dt = 0.0001;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);

  double err0 = 0;
  for (int i = n.lower_x; i < n.upper_x; i++) {
    double e = fabs(formura_data.u[i][4][4] - exact(to_pos_x(i, n), 0.0));
    if (e > err0) err0 = e;
  }
  printf("t=0     max|u-exact| = %.3e\n", err0);

  while (n.time_step < steps) Formura_Forward(&n);

  double t = steps * dt, err = 0, umax = 0;
  for (int i = n.lower_x; i < n.upper_x; i++) {
    double v = formura_data.u[i][4][4];
    double e = fabs(v - exact(to_pos_x(i, n), t));
    if (e > err) err = e;
    if (fabs(v) > umax) umax = fabs(v);
  }
  printf("t=%.2f  max|u-exact| = %.3e  (umax=%.3f)\n", t, err, umax);
  int ok = err < 2e-3 && isfinite(err);
  printf("burgers vs Cole-Hopf exact: [%s]\n", ok ? "OK" : "NG");
  Formura_Finalize();
  return ok ? 0 : 1;
}
