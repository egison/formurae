#include <stdio.h>
#include <math.h>
#include "diffusion1d.h"

/* 1D heat equation: periodic mass is conserved and the pulse diffuses. */

static void stats(Formura_Navi n, double *sum, double *mx) {
  double s = 0.0, m = -1e300;
  for (int ix = n.lower_x; ix < n.upper_x; ix++) {
    double v = formura_data.u[ix];
    s += v;
    if (v > m) m = v;
  }
  *sum = s;
  *mx = m;
}

int main(int argc, char **argv) {
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);

  double sum0, max0, sum1, max1;
  stats(n, &sum0, &max0);
  printf("t=%d  sum=%.12e  max=%.12e\n", n.time_step, sum0, max0);

  while (n.time_step < 120) {
    Formura_Forward(&n);
  }

  stats(n, &sum1, &max1);
  printf("t=%d  sum=%.12e  max=%.12e\n", n.time_step, sum1, max1);

  double relmass = fabs(sum1 - sum0) / fabs(sum0);
  int ok_mass = relmass < 1e-10;
  int ok_decay = max1 < max0 && max1 > 0.1 * max0;
  printf("mass conservation: rel.err=%.3e  [%s]\n", relmass, ok_mass ? "OK" : "NG");
  printf("peak decay: %.6f -> %.6f  [%s]\n", max0, max1, ok_decay ? "OK" : "NG");

  Formura_Finalize();
  return (ok_mass && ok_decay) ? 0 : 1;
}
