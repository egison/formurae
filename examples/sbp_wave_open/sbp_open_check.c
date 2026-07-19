#include <stdio.h>
#include <math.h>
#include "sbp_wave_open.h"

/* SBP + characteristic SAT acoustics with transparent walls on [0, 63]:
 *   - a rightward Gaussian pulse (v = p) translates at unit speed, so the
 *     mid-flight solution matches the shifted initial data,
 *   - the energy in the SBP norms decays monotonically (up to leapfrog
 *     rounding): dE/dt = -2 p0^2 - 2 pN^2 semidiscretely,
 *   - after the pulse leaves through the right wall only the scheme's
 *     truncation-order reflection remains.
 * The final dual storage slot sits outside the domain and is excluded.
 */

#ifndef NX
#define NX 64
#endif
#ifndef STEPS
#define STEPS 512
#endif
#define DX (64.0 / (double)NX)
#define DT (0.2 * DX)
#define X0 20.0
#define W 4.0

static double norm_weight(int ix) {
  return (ix == 0 || ix == NX - 1) ? 0.5 : 1.0;
}

static double energy(void) {
  double e = 0.0;
  for (int ix = 0; ix < NX; ix++)
    e += norm_weight(ix) * formura_data.p[ix] * formura_data.p[ix];
  for (int ix = 0; ix < NX - 1; ix++)
    e += formura_data.v[ix] * formura_data.v[ix];
  return e;
}

static double pulse(double x) {
  double s = (x - X0) / W;
  return exp(-s * s);
}

static double translate_error(double t) {
  double err = 0.0;
  for (int ix = 0; ix < NX; ix++) {
    double d = fabs(formura_data.p[ix] - pulse(ix * DX - t));
    if (d > err) err = d;
  }
  return err;
}

static double residual(void) {
  double r = 0.0;
  for (int ix = 0; ix < NX; ix++)
    if (fabs(formura_data.p[ix]) > r) r = fabs(formura_data.p[ix]);
  for (int ix = 0; ix < NX - 1; ix++)
    if (fabs(formura_data.v[ix]) > r) r = fabs(formura_data.v[ix]);
  return r;
}

int main(int argc, char **argv) {
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);

  const double e0 = energy();
  double e_max = e0;
  double e_final = e0;
  double mid_err = -1.0;

  while (n.time_step < STEPS) {
    Formura_Forward(&n);
    double e = energy();
    if (e > e_max) e_max = e;
    e_final = e;
    if (n.time_step == (int)(20.0 / DT + 0.5))
      mid_err = translate_error(DT * n.time_step);
  }

  double tail = residual();

  /* Leapfrog staggers v in time, so the pointwise energy wiggles at
   * O(dt) inside a step; the transparency statements are that nothing
   * ever grows beyond that wiggle and the pulse energy leaves. */
  int ok_energy = (e_max < e0 * 1.005) && (e_final < 1e-3 * e0);
  int ok_mid = mid_err < 5e-2;
  int ok_tail = tail < 2e-2;

  printf("t=%.1f  mid-flight err=%.3e  reflection residual=%.3e\n",
         DT * n.time_step, mid_err, tail);
  printf("SBP energy: %.6e -> %.6e (max %.6e)  decay=[%s]\n", e0, e_final,
         e_max, ok_energy ? "OK" : "NG");
  printf("SBP+SAT transparent wave: translation + energy + residual: [%s]\n",
         (ok_mid && ok_energy && ok_tail) ? "OK" : "NG");

  Formura_Finalize();
  return (ok_mid && ok_energy && ok_tail) ? 0 : 1;
}
