#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include HDR
int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 8;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  while (n.time_step < steps) Formura_Forward(&n);
  for (int ix = n.lower_x; ix < n.upper_x; ix++)
    for (int iy = n.lower_y; iy < n.upper_y; iy++)
      for (int iz = n.lower_z; iz < n.upper_z; iz++) {
        int cx = (int)llround(to_pos_x(ix, n) / n.space_interval_x) % n.total_grid_x;
        int cy = (int)llround(to_pos_y(iy, n) / n.space_interval_y) % n.total_grid_y;
        int cz = (int)llround(to_pos_z(iz, n) / n.space_interval_z) % n.total_grid_z;
        if (cx < 0) cx += n.total_grid_x;
        if (cy < 0) cy += n.total_grid_y;
        if (cz < 0) cz += n.total_grid_z;
        printf("q %03d %02d %02d %a\n", cx, cy, cz, formura_data.q[ix][iy][iz]);
      }
  Formura_Finalize();
  return 0;
}
