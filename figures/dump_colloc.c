#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "maxwell3d.h"

/* Emit plot data for the collocated Maxwell run (same format as dump_yee).
 * argv: [steps] [dt_in_dx_units]                                   */

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

static void profile(const char *tag, Formura_Navi n) {
  for (int ix = n.lower_x; ix < n.upper_x; ix++)
    printf("%s %.4f %.6e\n", tag, to_pos_x(ix, n) / n.space_interval_x,
           formura_data.Ey[ix][8][8]);
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 100;
  double tfac = argc > 2 ? atof(argv[2]) : 0.1;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  profile("P0", n);
  printf("EN %.2f %.6e\n", 0.0, energy(n));
  while (n.time_step < steps) {
    Formura_Forward(&n);
    printf("EN %.2f %.6e\n", n.time_step * tfac, energy(n));
  }
  profile("P1", n);
  Formura_Finalize();
  return 0;
}
