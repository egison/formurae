/* I/O only: no initializers, updates or physical diagnostics here. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "composite_ultrasound.h"
static void dump(Formura_Navi n, const char *directory) {
  char path[4096];
  snprintf(path, sizeof path, "%s/frame-%07d-rank-%03d.bin", directory, n.time_step, n.my_rank);
  FILE *f = fopen(path, "wb"); if (!f) { perror(path); exit(2); }
  int32_t header[] = {n.total_grid_x, n.total_grid_y, n.time_step, 6};
  if (fwrite(header, sizeof header, 1, f) != 1) exit(2);
  for (int i=n.lower_x; i<n.upper_x; ++i) for (int j=n.lower_y; j<n.upper_y; ++j) {
    int32_t index[] = {((i+n.offset_x)%n.total_grid_x+n.total_grid_x)%n.total_grid_x,
                       ((j+n.offset_y)%n.total_grid_y+n.total_grid_y)%n.total_grid_y};
    double values[] = {formura_data.speed[i][j], formura_data.v_up1[i][j], formura_data.v_up2[i][j], formura_data.E_down1_down1[i][j], formura_data.E_down1_down2[i][j], formura_data.E_down2_down2[i][j]};
    if (fwrite(index, sizeof index, 1, f)!=1 || fwrite(values, sizeof values, 1, f)!=1) exit(2);
  }
  if (fclose(f)) exit(2);
}
int main(int argc, char **argv) {
  int steps=argc>1?atoi(argv[1]):100, every=argc>2?atoi(argv[2]):steps;
  const char *directory=argc>3?argv[3]:NULL;
  if (steps<1 || every<1 || steps%every) return 2;
  Formura_Navi n; Formura_Init(&argc,&argv,&n);
  if (n.my_rank==0) puts("step,time,maximum,energy,modified,signal,error");
  for (int target=0; target<=steps; target+=every) {
    while(n.time_step<target) Formura_Forward(&n);
    if(n.time_step!=target || !isfinite(n.reduce_maximum)) return 1;
    if(n.my_rank==0) printf("%d,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g\n", n.time_step, n.reduce_time, n.reduce_maximum, n.reduce_energy, n.reduce_modified, n.reduce_signal, n.reduce_error);
    if(directory) dump(n,directory);
  }
  Formura_Finalize(); return 0;
}
