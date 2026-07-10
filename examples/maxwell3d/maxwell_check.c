#include <stdio.h>
#include <math.h>
#include "maxwell3d.h"

/* Sanity driver for the Egison-generated Maxwell Formura program:
 * EM energy should be approximately conserved and the (Ey,Bz) pulse
 * should propagate toward +x (Poynting vector). */

static double energy(Formura_Navi n) {
  double s = 0;
  for (int ix = n.lower_x; ix < n.upper_x; ix++)
    for (int iy = n.lower_y; iy < n.upper_y; iy++)
      for (int iz = n.lower_z; iz < n.upper_z; iz++) {
        double ex = formura_data.E_down1[ix][iy][iz], ey = formura_data.E_down2[ix][iy][iz],
               ez = formura_data.E_down3[ix][iy][iz], bx = formura_data.B_down1[ix][iy][iz],
               by = formura_data.B_down2[ix][iy][iz], bz = formura_data.B_down3[ix][iy][iz];
        s += ex*ex + ey*ey + ez*ez + bx*bx + by*by + bz*bz;
      }
  return s;
}

/* circular mean of the pulse position in physical coordinates
 * (to_pos_x undoes the uniform per-step array translation) */
static double centerX(Formura_Navi n) {
  double C = 0, S = 0;
  for (int ix = n.lower_x; ix < n.upper_x; ix++)
    for (int iy = n.lower_y; iy < n.upper_y; iy++)
      for (int iz = n.lower_z; iz < n.upper_z; iz++) {
        double ey = formura_data.E_down2[ix][iy][iz], bz = formura_data.B_down3[ix][iy][iz];
        double w = ey*ey + bz*bz;
        double th = 2.0 * M_PI * to_pos_x(ix, n) / n.length_x;
        C += w * cos(th); S += w * sin(th);
      }
  double pos = atan2(S, C) / (2.0 * M_PI) * n.total_grid_x;
  if (pos < 0) pos += n.total_grid_x;
  return pos;
}

int main(int argc, char **argv) {
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);

  double e0 = energy(n), x0 = centerX(n);
  printf("t=%d  energy=%.6e  centerX=%.2f\n", n.time_step, e0, x0);

  while (n.time_step < 100) Formura_Forward(&n);

  double e1 = energy(n), x1 = centerX(n);
  printf("t=%d  energy=%.6e  centerX=%.2f\n", n.time_step, e1, x1);

  double drift = fabs(e1 - e0) / e0;
  double shift = x1 - x0;
  if (shift > n.total_grid_x / 2.0) shift -= n.total_grid_x;
  if (shift < -n.total_grid_x / 2.0) shift += n.total_grid_x;               /* ideal +dt/dx*100 = +10 cells; packet dispersion lowers it */
  int ok_energy = drift < 0.05;
  int ok_prop   = shift > 3.0 && shift < 20.0;
  printf("energy drift: %.3e  [%s]\n", drift, ok_energy ? "OK" : "NG");
  printf("pulse shift: %+.1f cells (expected ~+6..10)  [%s]\n", shift, ok_prop ? "OK" : "NG");

  Formura_Finalize();
  return (ok_energy && ok_prop) ? 0 : 1;
}
