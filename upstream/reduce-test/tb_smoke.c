#include <stdio.h>
#include <math.h>
#include "bc1d.h"
int main(int argc, char **argv) {
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  double t0 = n.reduce_tot;
  for (int i = 0; i < 5; i++) Formura_Forward(&n);
  double rel = fabs(n.reduce_tot - t0) / fabs(t0);
  printf("TB+reduce: tot %.9f -> %.9f (rel %.2e) t=%d [%s]\n",
         t0, n.reduce_tot, rel, n.time_step, rel < 1e-12 ? "OK" : "NG");
  return rel < 1e-12 ? 0 : 1;
}
