#include <stdio.h>
#include <stdlib.h>
#include HDR
int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 200;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  while (n.time_step < steps) Formura_Forward(&n);
  printf("# offset_x=%d\n", n.offset_x);
  for (int i = n.lower_x; i < n.upper_x; i++) {
    int cell = (i + n.offset_x) % n.total_grid_x;
    printf("%03d %.17e\n", cell, formura_data.q[i]);
  }
  return 0;
}
