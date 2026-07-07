#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "tdgl3d.h"

/* TDGL sanity: the bulk saturates to |psi|^2 ~ 1, while vortex cores
 * (|psi|^2 near 0) persist as topological defects. */

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 4000;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  while (n.time_step < steps) Formura_Forward(&n);

  double sum = 0, mn = 1e300, mx = -1e300;
  long cnt = 0, cores = 0;
  int k = 2;
  for (int i = n.lower_x; i < n.upper_x; i++)
    for (int j = n.lower_y; j < n.upper_y; j++) {
      double av = formura_data.a[i][j][k], bv = formura_data.b[i][j][k];
      double p = av*av + bv*bv;
      sum += p; cnt++;
      if (p < mn) mn = p;
      if (p > mx) mx = p;
      if (p < 0.3) cores++;
    }
  double mean = sum / cnt;
  printf("t=%d  |psi|^2: mean=%.3f  min=%.4f  max=%.3f  core cells=%ld\n",
         n.time_step, mean, mn, mx, cores);
  int ok_bulk  = mean > 0.7 && mean < 1.05 && mx < 1.3;
  int ok_cores = mn < 0.2 && cores > 0;
  printf("bulk saturation [%s]  vortex cores [%s]\n",
         ok_bulk ? "OK" : "NG", ok_cores ? "OK" : "NG");
  Formura_Finalize();
  return (ok_bulk && ok_cores) ? 0 : 1;
}
