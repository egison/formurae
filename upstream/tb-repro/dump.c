#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include HDR

/* Run N steps and dump every cell as (physical cell id, exact hex value).
 * Output is sorted by the caller; bitwise comparison across runs then
 * ignores any array-internal translation (cursor drift). */

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 8;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  while (n.time_step < steps) Formura_Forward(&n);
  for (int ix = n.lower_x; ix < n.upper_x; ix++) {
    int cell = (int)llround(to_pos_x(ix, n) / n.space_interval_x) % n.total_grid_x;
    if (cell < 0) cell += n.total_grid_x;
    printf("%03d %a\n", cell, formura_data.q[ix]);
  }
  Formura_Finalize();
  return 0;
}
