#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#define N 64
/* reference 1D heat with ghost semantics: argv[1]=steps argv[2]=bc(mirror|fixed|periodic) argv[3]=v */
int main(int argc, char **argv) {
  int steps = atoi(argv[1]);
  const char *bc = argv[2];
  double v = argc > 3 ? atof(argv[3]) : 0.0, c = 0.2;
  static double q[N], qn[N];
  for (int i = 0; i < N; i++) q[i] = 0.001*(i+1)*(i+3);
  for (int t = 0; t < steps; t++) {
    for (int i = 0; i < N; i++) {
      double lo = (i > 0)   ? q[i-1] : (!strcmp(bc,"mirror") ? q[0]   : (!strcmp(bc,"fixed") ? v : q[N-1]));
      double hi = (i < N-1) ? q[i+1] : (!strcmp(bc,"mirror") ? q[N-1] : (!strcmp(bc,"fixed") ? v : q[0]));
      qn[i] = q[i] + c*(hi - 2.0*q[i] + lo);
    }
    memcpy(q, qn, sizeof q);
  }
  for (int i = 0; i < N; i++) printf("%d %.17e\n", i, q[i]);
  return 0;
}
