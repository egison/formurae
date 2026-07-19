#include <stdio.h>
#include <math.h>
#include "sbp_diffusion2d.h"

/* SBP + SAT heat equation on the bounded square [0, 31]^2:
 *   - the solution tracks the product mode sin(pi x/L) sin(pi y/L) with
 *     decay rate 2 kappa (pi/L)^2,
 *   - the energy in the tensor SBP norm never grows,
 *   - all four edges (and in particular the corners, which receive both
 *     axis closures and both penalties) stay pinned.
 */

#define NX 32
#define KAPPA 1.0
#define DT 0.025
#define LWALL 31.0

static double weight(int ix) {
  return (ix == 0 || ix == NX - 1) ? 0.5 : 1.0;
}

static double energy(void) {
  double e = 0.0;
  for (int iy = 0; iy < NX; iy++)
    for (int ix = 0; ix < NX; ix++) {
      double v = formura_data.u[ix][iy];
      e += weight(ix) * weight(iy) * v * v;
    }
  return e;
}

int main(int argc, char **argv) {
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);

  double e_prev = energy();
  const double e0 = e_prev;
  int ok_energy = 1;

  while (n.time_step < 1000) {
    Formura_Forward(&n);
    double e = energy();
    if (e > e_prev + 1e-12 * e0) ok_energy = 0;
    e_prev = e;
  }

  double lambda = M_PI / LWALL;
  double decay = exp(-2.0 * KAPPA * lambda * lambda * DT * n.time_step);
  double err = 0.0, edge = 0.0;
  for (int iy = 0; iy < NX; iy++)
    for (int ix = 0; ix < NX; ix++) {
      double exact = decay * sin(lambda * ix) * sin(lambda * iy);
      double d = fabs(formura_data.u[ix][iy] - exact);
      if (d > err) err = d;
      if (ix == 0 || ix == NX - 1 || iy == 0 || iy == NX - 1)
        if (fabs(formura_data.u[ix][iy]) > edge)
          edge = fabs(formura_data.u[ix][iy]);
    }
  double corner = fabs(formura_data.u[0][0]);
  if (fabs(formura_data.u[0][NX - 1]) > corner)
    corner = fabs(formura_data.u[0][NX - 1]);
  if (fabs(formura_data.u[NX - 1][0]) > corner)
    corner = fabs(formura_data.u[NX - 1][0]);
  if (fabs(formura_data.u[NX - 1][NX - 1]) > corner)
    corner = fabs(formura_data.u[NX - 1][NX - 1]);

  int ok_mode = err < 5e-3;
  int ok_edge = edge < 1e-3;

  printf("t=%.1f  exact amp=%.6f  max|u-exact|=%.3e  edge=%.3e  corner=%.3e\n",
         DT * n.time_step, decay, err, edge, corner);
  printf("SBP energy: %.6e -> %.6e  monotone=[%s]\n", e0, e_prev,
         ok_energy ? "OK" : "NG");
  printf("SBP+SAT 2D Dirichlet heat: mode + energy + edges/corners: [%s]\n",
         (ok_mode && ok_energy && ok_edge) ? "OK" : "NG");

  Formura_Finalize();
  return (ok_mode && ok_energy && ok_edge) ? 0 : 1;
}
