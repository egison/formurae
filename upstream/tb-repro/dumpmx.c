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
        printf("Ex . %a\n", formura_data.Ex[ix][iy][iz]);
        printf("Ey . %a\n", formura_data.Ey[ix][iy][iz]);
        printf("Ez . %a\n", formura_data.Ez[ix][iy][iz]);
        printf("Bx . %a\n", formura_data.Bx[ix][iy][iz]);
        printf("By . %a\n", formura_data.By[ix][iy][iz]);
        printf("Bz . %a\n", formura_data.Bz[ix][iy][iz]);
      }
  Formura_Finalize();
  return 0;
}
