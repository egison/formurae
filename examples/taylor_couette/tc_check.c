#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "taylor_couette.h"

/* Axisymmetric Taylor-Couette flow, projection with a fixed number of
 * Jacobi sweeps unrolled in the step (stage 0 of the nested-iteration
 * design).  The inner cylinder r = R1 rotates with angular velocity W1, the
 * outer one r = R2 with W2; the fluid starts at rest.  Checks:
 *   1. the azimuthal velocity settles on the laminar Couette profile
 *      A r + B / r (z-averaged, cell centres);
 *   2. the meridional velocity and the discrete divergence vanish;
 *   3. the projection identity div_h u' = dt * (rhs - L_h phi) holds to
 *      rounding (the state fields dv and res are both written in the step);
 *   4. the pressure balances the centrifugal force:
 *      p(r) - p(r0) = P(r) - P(r0) with P = A^2 r^2/2 + 2 A B ln r - B^2/(2 r^2).
 * The r axis is walled (no drift); the periodic z axis may drift under
 * temporal blocking, which the z averages do not see.  The last r slot lies
 * beyond the outer wall and is pinned to zero by the model, so the
 * comparisons stop at the last cell inside the gap. */

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 15000;
  /* dt must match the param of the model (a smaller value is used for
   * timing runs on finer grids) */
  const double dt = argc > 2 ? atof(argv[2]) : 0.002;
  const double R1 = 1.0, R2 = 2.0, W1 = 1.0, W2 = 0.0;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  const double dr = n.space_interval_r;
  int report = steps / 10;
  if (report < 1) report = 1;
  printf("t=%.3f  |res|=%.3e  |div|=%.3e  |ur|=%.3e  |uz|=%.3e\n", 0.0,
         n.reduce_res, n.reduce_dv, n.reduce_ur, n.reduce_uz);
  while (n.time_step < steps) {
    Formura_Forward(&n);
    if (n.time_step % report == 0)
      printf("t=%.3f  |res|=%.3e  |div|=%.3e  |ur|=%.3e  |uz|=%.3e\n",
             n.time_step * dt, n.reduce_res, n.reduce_dv, n.reduce_ur, n.reduce_uz);
  }

  const double A = (W2 * R2 * R2 - W1 * R1 * R1) / (R2 * R2 - R1 * R1);
  const double B = (W1 - W2) * R1 * R1 * R2 * R2 / (R2 * R2 - R1 * R1);
  const int nz = n.upper_z - n.lower_z;
  double errt = 0, iderr = 0, errp = 0, prange = 0, pm0 = 0, P0 = 0;
  const int last = n.upper_r - 1; /* the slot beyond the outer wall */
  for (int i = n.lower_r; i < last; i++) {
    const double rc = R1 + (i + 0.5) * dr;
    double ut = 0, pm = 0;
    for (int j = n.lower_z; j < n.upper_z; j++) {
      ut += formura_data.ut[i][j];
      pm += formura_data.p[i][j];
      double id = fabs(formura_data.dv[i][j] - dt * formura_data.res[i][j]);
      if (id > iderr) iderr = id;
    }
    ut /= nz;
    pm /= nz;
    const double exact = A * rc + B / rc;
    const double P = 0.5 * A * A * rc * rc + 2 * A * B * log(rc) - 0.5 * B * B / (rc * rc);
    if (i == n.lower_r) { pm0 = pm; P0 = P; }
    if (fabs(ut - exact) > errt) errt = fabs(ut - exact);
    if (fabs((pm - pm0) - (P - P0)) > errp) errp = fabs((pm - pm0) - (P - P0));
    if (fabs(P - P0) > prange) prange = fabs(P - P0);
    if (i == n.lower_r || i == last - 1 || i == (n.lower_r + last) / 2)
      printf("  r=%.4f  ut=%.6f  exact=%.6f  p-p0=%.6f  P-P0=%.6f\n", rc, ut, exact, pm - pm0, P - P0);
  }
  printf("max|ut-couette|=%.3e  max|p-P|/range=%.3e  max|dv-dt*res|=%.3e\n",
         errt, errp / prange, iderr);
  printf("final |res|=%.3e  |div|=%.3e  |ur|=%.3e  |uz|=%.3e\n",
         n.reduce_res, n.reduce_dv, n.reduce_ur, n.reduce_uz);
  int ok_profile = errt < 5e-3;
  int ok_pressure = errp / prange < 2e-2;
  int ok_identity = iderr < 1e-11;
  int ok_divergence = n.reduce_dv < 1e-8 && n.reduce_ur < 1e-6 && n.reduce_uz < 1e-6;
  printf("couette profile [%s]  centrifugal balance [%s]  projection identity [%s]  divergence-free [%s]\n",
         ok_profile ? "OK" : "NG", ok_pressure ? "OK" : "NG",
         ok_identity ? "OK" : "NG", ok_divergence ? "OK" : "NG");
  Formura_Finalize();
  return (ok_profile && ok_pressure && ok_identity && ok_divergence) ? 0 : 1;
}
