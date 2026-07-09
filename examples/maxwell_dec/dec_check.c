#include <stdio.h>
#include <math.h>
#include "maxwell_dec.h"

/* Sanity driver for the Egison-generated Yee-FDTD Formura program:
 * EM energy approximately conserved (leapfrog), the (E_2,B_1_2) pulse
 * propagates toward +x at ~c, and div B stays at rounding level. */

static double energy(Formura_Navi n) {
  double s = 0;
  for (int ix = n.lower_x; ix < n.upper_x; ix++)
    for (int iy = n.lower_y; iy < n.upper_y; iy++)
      for (int iz = n.lower_z; iz < n.upper_z; iz++) {
        double ex = formura_data.E_1[ix][iy][iz], ey = formura_data.E_2[ix][iy][iz],
               ez = formura_data.E_3[ix][iy][iz], bxy = formura_data.B_1_2[ix][iy][iz],
               bxz = formura_data.B_1_3[ix][iy][iz], byz = formura_data.B_2_3[ix][iy][iz];
        s += ex*ex + ey*ey + ez*ez + bxy*bxy + bxz*bxz + byz*byz;
      }
  return s;
}

/* Circular mean of the pulse position in PHYSICAL coordinates, robust on
 * the periodic domain.  Formura's Forward may translate the data inside
 * the array (by design); to_pos_x undoes that bookkeeping. */
static double centerX(Formura_Navi n) {
  double C = 0, S = 0;
  for (int ix = n.lower_x; ix < n.upper_x; ix++)
    for (int iy = n.lower_y; iy < n.upper_y; iy++)
      for (int iz = n.lower_z; iz < n.upper_z; iz++) {
        double ey = formura_data.E_2[ix][iy][iz], bxy = formura_data.B_1_2[ix][iy][iz];
        double w = ey*ey + bxy*bxy;
        double th = 2.0 * M_PI * to_pos_x(ix, n) / n.length_x;
        C += w * cos(th); S += w * sin(th);
      }
  double pos = atan2(S, C) / (2.0 * M_PI) * n.total_grid_x;
  if (pos < 0) pos += n.total_grid_x;
  return pos;   /* in cells */
}

/* discrete div B at cell centers (interior only, to avoid wrap logic) */
static double maxDivB(Formura_Navi n) {
  double m = 0;
  double dx = n.space_interval_x, dy = n.space_interval_y, dz = n.space_interval_z;
  for (int ix = n.lower_x; ix < n.upper_x - 1; ix++)
    for (int iy = n.lower_y; iy < n.upper_y - 1; iy++)
      for (int iz = n.lower_z; iz < n.upper_z - 1; iz++) {
        double d = (formura_data.B_2_3[ix+1][iy][iz] - formura_data.B_2_3[ix][iy][iz]) / dx
                 - (formura_data.B_1_3[ix][iy+1][iz] - formura_data.B_1_3[ix][iy][iz]) / dy
                 + (formura_data.B_1_2[ix][iy][iz+1] - formura_data.B_1_2[ix][iy][iz]) / dz;
        if (fabs(d) > m) m = fabs(d);
      }
  return m;
}

int main(int argc, char **argv) {
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);

  double e0 = energy(n), x0 = centerX(n), d0 = maxDivB(n);
  printf("t=%d  energy=%.6e  centerX=%.2f  maxDivB=%.3e\n", n.time_step, e0, x0, d0);

  while (n.time_step < 100) Formura_Forward(&n);

  double e1 = energy(n), x1 = centerX(n), d1 = maxDivB(n);
  printf("t=%d  energy=%.6e  centerX=%.2f  maxDivB=%.3e\n", n.time_step, e1, x1, d1);

  double drift = fabs(e1 - e0) / e0;
  double shift = x1 - x0;               /* ideal +dt/dx*100 = +50 cells */
  if (shift > n.total_grid_x / 2.0) shift -= n.total_grid_x;
  if (shift < -n.total_grid_x / 2.0) shift += n.total_grid_x;
  int ok_energy = drift < 0.02;
  int ok_prop   = shift > 40.0 && shift < 58.0;
  int ok_divb   = d1 < 1e-10;
  printf("energy drift: %.3e  [%s]\n", drift, ok_energy ? "OK" : "NG");
  printf("pulse shift: %+.1f cells (ideal +50)  [%s]\n", shift, ok_prop ? "OK" : "NG");
  printf("div B: %.3e -> %.3e  [%s]\n", d0, d1, ok_divb ? "OK" : "NG");

  Formura_Finalize();
  return (ok_energy && ok_prop && ok_divb) ? 0 : 1;
}
