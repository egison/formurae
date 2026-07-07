#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "elastic3d.h"

/* Two pulses launched from x=0.3: a P pulse (vx, sxx) and an S pulse
 * (vy, sxy), both right-moving.  With la=2, mu=1, rho=1 they travel at
 * vp=2 and vs=1; the driver measures both speeds in one run and checks
 * elastic energy conservation. */

static double centerOf(Formura_Navi n, int which) {
  double C = 0, S = 0;
  int N = n.total_grid_x;
  for (int i = n.lower_x; i < n.upper_x; i++) {
    double v = (which == 0) ? formura_data.vx[i][2][2] : formura_data.vy[i][2][2];
    double w = v * v;
    double th = 2.0 * M_PI * to_pos_x(i, n) / n.length_x;
    C += w * cos(th); S += w * sin(th);
  }
  double pos = atan2(S, C) / (2.0 * M_PI) * N;
  if (pos < 0) pos += N;
  return pos;
}

static double energy(Formura_Navi n) {
  double E = 0, la = 2.0, mu = 1.0, rho = 1.0;
  for (int i = n.lower_x; i < n.upper_x; i++)
    for (int j = n.lower_y; j < n.upper_y; j++)
      for (int k = n.lower_z; k < n.upper_z; k++) {
        double v2 = formura_data.vx[i][j][k]*formura_data.vx[i][j][k]
                  + formura_data.vy[i][j][k]*formura_data.vy[i][j][k]
                  + formura_data.vz[i][j][k]*formura_data.vz[i][j][k];
        double tr = formura_data.sxx[i][j][k] + formura_data.syy[i][j][k] + formura_data.szz[i][j][k];
        double ss = formura_data.sxx[i][j][k]*formura_data.sxx[i][j][k]
                  + formura_data.syy[i][j][k]*formura_data.syy[i][j][k]
                  + formura_data.szz[i][j][k]*formura_data.szz[i][j][k]
                  + 2*(formura_data.sxy[i][j][k]*formura_data.sxy[i][j][k]
                     + formura_data.sxz[i][j][k]*formura_data.sxz[i][j][k]
                     + formura_data.syz[i][j][k]*formura_data.syz[i][j][k]);
        E += 0.5*rho*v2 + ss/(4*mu) - la*tr*tr/(4*mu*(3*la+2*mu));
      }
  return E;
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 600;
  double dt = 0.0005;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  double xp0 = centerOf(n, 0), xs0 = centerOf(n, 1), e0 = energy(n);

  while (n.time_step < steps) Formura_Forward(&n);

  double T = steps * dt;
  double dp = centerOf(n, 0) - xp0, ds = centerOf(n, 1) - xs0;
  if (dp < 0) dp += n.total_grid_x;
  if (ds < 0) ds += n.total_grid_x;
  double vp = dp * n.space_interval_x / T, vs = ds * n.space_interval_x / T;
  double edrift = fabs(energy(n) - e0) / e0;
  printf("t=%.2f  measured vp=%.3f (exact 2)  vs=%.3f (exact 1)  energy drift=%.2e\n",
         T, vp, vs, edrift);
  int ok = fabs(vp - 2.0) < 0.15 && fabs(vs - 1.0) < 0.1 && edrift < 0.02;
  printf("P/S wave speeds + energy: [%s]\n", ok ? "OK" : "NG");
  Formura_Finalize();
  return ok ? 0 : 1;
}
