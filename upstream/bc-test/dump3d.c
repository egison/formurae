#include <stdio.h>
#include <stdlib.h>
#include HDR
int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 50;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  while (n.time_step < steps) Formura_Forward(&n);
  printf("# offsets %d %d %d\n", n.offset_x, n.offset_y, n.offset_z);
  for (int i = n.lower_x; i < n.upper_x; i++)
    for (int j = n.lower_y; j < n.upper_y; j++)
      for (int k = n.lower_z; k < n.upper_z; k++)
        printf("%d %d %d %.17e\n", i, j, k, formura_data.q[i][j][k]);
  return 0;
}
