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
        double ex = formura_data.Ex[ix][iy][iz], ey = formura_data.Ey[ix][iy][iz],
               ez = formura_data.Ez[ix][iy][iz], bx = formura_data.Bx[ix][iy][iz],
               by = formura_data.By[ix][iy][iz], bz = formura_data.Bz[ix][iy][iz];
        s += ex*ex + ey*ey + ez*ez + bx*bx + by*by + bz*bz;
      }
  return s;
}

static double centerX(Formura_Navi n) {
  double s = 0, sx = 0;
  for (int ix = n.lower_x; ix < n.upper_x; ix++)
    for (int iy = n.lower_y; iy < n.upper_y; iy++)
      for (int iz = n.lower_z; iz < n.upper_z; iz++) {
        double ey = formura_data.Ey[ix][iy][iz], bz = formura_data.Bz[ix][iy][iz];
        double w = ey*ey + bz*bz;
        s += w; sx += w * ix;
      }
  return sx / s;
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
  double shift = x1 - x0;               /* ideal +dt/dx*100 = +10 cells; packet dispersion lowers it */
  int ok_energy = drift < 0.05;
  int ok_prop   = shift > 3.0 && shift < 20.0;
  printf("energy drift: %.3e  [%s]\n", drift, ok_energy ? "OK" : "NG");
  printf("pulse shift: %+.1f cells (expected ~+6..10)  [%s]\n", shift, ok_prop ? "OK" : "NG");

  Formura_Finalize();
  return (ok_energy && ok_prop) ? 0 : 1;
}
