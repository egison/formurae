/* This driver only invokes generated code, reports its reductions and writes
 * fields. No initial conditions or numerical state updates are implemented here. */
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "breaking_wave.h"

static int integer(const char *text) {
  char *end;
  errno = 0;
  long value = strtol(text, &end, 10);
  if (errno || *end || value < 0 || value > 100000000) exit(2);
  return (int)value;
}

static void dump(Formura_Navi n, const char *directory) {
  char path[4096];
  int length = snprintf(path, sizeof path, "%s/frame-%07d.bin", directory, n.time_step/5);
  if (length < 0 || (size_t)length >= sizeof path) exit(2);
  FILE *file = fopen(path, "wb");
  if (!file) { perror(path); exit(2); }
  int32_t header[] = {n.total_grid_x, n.total_grid_y, n.time_step/5};
  if (fwrite(header, sizeof header, 1, file) != 1) exit(2);
  for (int i=n.lower_x; i<n.upper_x; ++i)
    for (int j=n.lower_y; j<n.upper_y; ++j) {
      int32_t index[] = {((i+n.offset_x)%n.total_grid_x+n.total_grid_x)%n.total_grid_x,
                         ((j+n.offset_y)%n.total_grid_y+n.total_grid_y)%n.total_grid_y};
      double values[] = {formura_data.fraction[i][j], formura_data.speed[i][j],
                         formura_data.wall[i][j], formura_data.bank[i][j],
                         formura_data.kind[i][j], formura_data.mass[i][j], formura_data.density[i][j]};
      if (fwrite(index, sizeof index, 1, file) != 1) exit(2);
      if (fwrite(values, sizeof values, 1, file) != 1) exit(2);
    }
  if (fclose(file)) exit(2);
}

static int report(Formura_Navi n) {
  printf("%d,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g\n", n.time_step/5,
         n.reduce_water, n.reduce_bank, n.reduce_speed, n.reduce_rmin,
         n.reduce_rmax, n.reduce_overhang, n.reduce_bad);
  fflush(stdout);
  return isfinite(n.reduce_water) && isfinite(n.reduce_speed) && n.reduce_bad == 0;
}

int main(int argc, char **argv) {
  if (argc != 4) return 2;
  int steps=integer(argv[1]), every=integer(argv[2]);
  if (!every || steps % every) return 2;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  puts("step,water,bank,speed,rmin,rmax,overhang,bad");
  int ok=report(n);
  dump(n, argv[3]);
  struct timespec start, stop;
  timespec_get(&start, TIME_UTC);
  for (int target=every; ok && target<=steps; target+=every) {
    while (n.time_step < 5*target) Formura_Forward(&n);
    if (n.time_step != 5*target) { ok=0; break; }
    ok=report(n);
    dump(n, argv[3]);
  }
  timespec_get(&stop, TIME_UTC);
  fprintf(stderr, "steps=%d elapsed_seconds=%.3f bounds=%s\n", n.time_step/5,
          (double)(stop.tv_sec-start.tv_sec)+1e-9*(stop.tv_nsec-start.tv_nsec),
          ok ? "ok" : "failed");
  Formura_Finalize();
  return ok ? 0 : 1;
}
