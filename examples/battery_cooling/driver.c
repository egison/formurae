/* I/O only: no initializers, updates or physical diagnostics here. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "battery_cooling.h"
static void dump(Formura_Navi n, const char *directory) {
  char path[4096];
  snprintf(path, sizeof path, "%s/frame-%07d-rank-%03d.bin", directory, n.time_step, n.my_rank);
  FILE *f = fopen(path, "wb"); if (!f) { perror(path); exit(2); }
  int32_t header[] = {n.total_grid_r, n.total_grid_z, n.time_step, 1};
  if (fwrite(header, sizeof header, 1, f) != 1) exit(2);
  for (int i=n.lower_r; i<n.upper_r; ++i) for (int j=n.lower_z; j<n.upper_z; ++j) {
    int32_t index[] = {((i+n.offset_r)%n.total_grid_r+n.total_grid_r)%n.total_grid_r,
                       ((j+n.offset_z)%n.total_grid_z+n.total_grid_z)%n.total_grid_z};
    double values[] = {formura_data.T[i][j]};
    if (fwrite(index, sizeof index, 1, f)!=1 || fwrite(values, sizeof values, 1, f)!=1) exit(2);
  }
  if (fclose(f)) exit(2);
}
int main(int argc, char **argv) {
  int steps=argc>1?atoi(argv[1]):100, every=argc>2?atoi(argv[2]):steps;
  const char *directory=argc>3?argv[3]:NULL;
  if (steps<1 || every<1 || steps%every) return 2;
  Formura_Navi n; Formura_Init(&argc,&argv,&n);
  if (n.my_rank==0) puts("step,time,maximum,minimum,heat,supplied,removed,balance,error");
  for (int target=0; target<=steps; target+=every) {
    while(n.time_step<target) Formura_Forward(&n);
    if(n.time_step!=target || !isfinite(n.reduce_maximum)) return 1;
    if(n.my_rank==0) printf("%d,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g\n", n.time_step, n.reduce_time, n.reduce_maximum, n.reduce_minimum, n.reduce_heat, n.reduce_supplied, n.reduce_removed, n.reduce_balance, n.reduce_error);
    if(directory) dump(n,directory);
  }
  Formura_Finalize(); return 0;
}
