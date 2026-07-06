#include <stdio.h>
#include <math.h>
#include "diffusion3d.h"

/* Sanity driver for the Egison-generated diffusion3d Formura program:
 * total mass must be conserved (periodic BC) and the peak must decay. */

static void stats(Formura_Navi n, double *sum, double *mx) {
  double s = 0, m = -1e300;
  for (int ix = n.lower_x; ix < n.upper_x; ix++)
    for (int iy = n.lower_y; iy < n.upper_y; iy++)
      for (int iz = n.lower_z; iz < n.upper_z; iz++) {
        double v = formura_data.u[ix][iy][iz];
        s += v;
        if (v > m) m = v;
      }
  *sum = s; *mx = m;
}

int main(int argc, char **argv) {
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);

  double sum0, max0, sum1, max1;
  stats(n, &sum0, &max0);
  printf("t=%d  sum=%.12e  max=%.12e\n", n.time_step, sum0, max0);

  while (n.time_step < 100) {
    Formura_Forward(&n);
  }
  stats(n, &sum1, &max1);
  printf("t=%d  sum=%.12e  max=%.12e\n", n.time_step, sum1, max1);

  double relmass = fabs(sum1 - sum0) / fabs(sum0);
  int ok_mass  = relmass < 1e-9;
  int ok_decay = max1 < max0 && max1 > 0.1 * max0;
  printf("mass conservation: rel.err=%.3e  [%s]\n", relmass, ok_mass ? "OK" : "NG");
  printf("peak decay: %.6f -> %.6f  [%s]\n", max0, max1, ok_decay ? "OK" : "NG");

  Formura_Finalize();
  return (ok_mass && ok_decay) ? 0 : 1;
}
