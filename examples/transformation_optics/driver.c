/* Only start/advance the generated solver, inspect its reductions, and dump
 * arrays. Initial conditions, materials, updates and diagnostics are FME.
 * Each MPI rank writes its own records; no numerical state is written here. */
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "transformation_optics.h"

static void fail(const char *message) {
  perror(message);
  exit(2);
}

static int integer(const char *value) {
  char *end;
  errno = 0;
  long n = strtol(value, &end, 10);
  if (errno || *end || n < 0 || n > 100000000) {
    fprintf(stderr, "invalid nonnegative integer: %s\n", value);
    exit(2);
  }
  return (int)n;
}

/* One z layer of the dummy axis holds the whole two-dimensional state. */
static void dump(Formura_Navi n, const char *directory) {
  char path[4096];
  int written = snprintf(path, sizeof path, "%s/frame-%07d-rank-%03d.bin",
                         directory, n.time_step, n.my_rank);
  if (written < 0 || (size_t)written >= sizeof path) {
    fprintf(stderr, "output path too long\n"); exit(2);
  }
  FILE *file = fopen(path, "wb");
  if (!file) fail(path);
  int32_t header[] = {n.total_grid_x, n.total_grid_y, n.time_step};
  if (fwrite(header, sizeof header, 1, file) != 1) fail("write header");
  int k = n.lower_z;
  for (int i = n.lower_x; i < n.upper_x; ++i) {
    int ci = ((i + n.offset_x) % n.total_grid_x + n.total_grid_x) % n.total_grid_x;
    for (int j = n.lower_y; j < n.upper_y; ++j) {
      int cj = ((j + n.offset_y) % n.total_grid_y + n.total_grid_y) % n.total_grid_y;
      int32_t index[] = {ci, cj};
      double values[] = {formura_data.E_down3[i][j][k], formura_data.Ev_down3[i][j][k]};
      if (fwrite(index, sizeof index, 1, file) != 1 ||
          fwrite(values, sizeof values, 1, file) != 1) fail("write field");
    }
  }
  if (fclose(file)) fail("close output");
}

static int report(Formura_Navi n) {
  if (n.my_rank == 0) {
    printf("%d,%.17g,%.17g,%.17g,%.17g\n", n.time_step, n.reduce_emax,
           n.reduce_scatter, n.reduce_incident, n.reduce_energy);
    fflush(stdout);
  }
  return isfinite(n.reduce_energy) && isfinite(n.reduce_scatter) &&
         n.reduce_emax < 20;
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? integer(argv[1]) : 400;
  int interval = argc > 2 ? integer(argv[2]) : steps;
  const char *directory = argc > 3 ? argv[3] : NULL;
  if (interval < 1 || steps % interval) {
    fprintf(stderr, "usage: check STEPS INTERVAL [existing-output-directory]; "
                    "STEPS must be divisible by INTERVAL\n");
    return 2;
  }
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  if (n.my_rank == 0)
    puts("step,emax,scatter,incident,energy");
  int ok = report(n);
  if (directory) dump(n, directory);
  struct timespec start, stop;
  timespec_get(&start, TIME_UTC);
  for (int target = interval; ok && target <= steps; target += interval) {
    while (n.time_step < target) Formura_Forward(&n);
    if (n.time_step != target) {
      fprintf(stderr, "sample interval must align with temporal blocking\n");
      ok = 0;
      break;
    }
    ok = report(n);
    if (directory) dump(n, directory);
  }
  timespec_get(&stop, TIME_UTC);
  if (n.my_rank == 0)
    fprintf(stderr, "steps=%d elapsed_seconds=%.6f bounds=%s\n", n.time_step,
            (double)(stop.tv_sec-start.tv_sec) +
            1e-9*(double)(stop.tv_nsec-start.tv_nsec), ok ? "ok" : "failed");
  Formura_Finalize();
  return ok ? 0 : 1;
}
