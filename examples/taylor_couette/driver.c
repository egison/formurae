/* Demonstration driver: start the generated solver, print its reductions,
 * and dump the meridional plane.  The initial state, the projection, the
 * wall conditions and the two diagnostics are computed by the generated
 * code; nothing numerical is computed here.  Each MPI rank writes its own
 * records with global cell indices, so the renderer can merge them. */
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "taylor_couette.h"

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

/* Global cell index of a local slot: the physical position over the
 * spacing, reduced modulo the grid (the periodic z axis drifts under
 * temporal blocking; the walled r axis is anchored). */
static int cell_r(Formura_Navi n, int i) {
  int c = (int)floor(to_pos_r(i, n) / n.space_interval_r + 0.5);
  return ((c % n.total_grid_r) + n.total_grid_r) % n.total_grid_r;
}
static int cell_z(Formura_Navi n, int j) {
  int c = (int)floor(to_pos_z(j, n) / n.space_interval_z + 0.5);
  return ((c % n.total_grid_z) + n.total_grid_z) % n.total_grid_z;
}

/* One record per owned cell: (ci, cj) and ut, u_r (face ci), u_z (face cj), p. */
static void dump(Formura_Navi n, const char *directory) {
  char path[4096];
  int written = snprintf(path, sizeof path, "%s/state-%07d-rank-%03d.bin", directory,
                         n.time_step, n.my_rank);
  if (written < 0 || (size_t)written >= sizeof path) {
    fprintf(stderr, "output path too long\n"); exit(2);
  }
  FILE *file = fopen(path, "wb");
  if (!file) fail(path);
  int32_t header[] = {n.total_grid_r, n.total_grid_z, n.time_step};
  if (fwrite(header, sizeof header, 1, file) != 1) fail("write header");
  for (int i = n.lower_r; i < n.upper_r; ++i) {
    int32_t ci = cell_r(n, i);
    for (int j = n.lower_z; j < n.upper_z; ++j) {
      int32_t index[] = {ci, cell_z(n, j)};
      double values[] = {formura_data.ut[i][j], formura_data.u_down1[i][j],
                         formura_data.u_down2[i][j], formura_data.p[i][j]};
      if (fwrite(index, sizeof index, 1, file) != 1) fail("write index");
      if (fwrite(values, sizeof values, 1, file) != 1) fail("write values");
    }
  }
  if (fclose(file)) fail("close output");
}

static int report(Formura_Navi n) {
  if (n.my_rank == 0) {
    printf("%d,%.17g,%.17g,%.17g,%.17g\n", n.time_step, n.reduce_res, n.reduce_dv,
           n.reduce_ur, n.reduce_uz);
    fflush(stdout);
  }
  return isfinite(n.reduce_res) && isfinite(n.reduce_ur) && isfinite(n.reduce_uz) &&
         n.reduce_ur < 100 && n.reduce_uz < 100;
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? integer(argv[1]) : 1000;
  int interval = argc > 2 ? integer(argv[2]) : steps;
  const char *directory = argc > 3 ? argv[3] : NULL;
  if (interval < 1 || steps % interval) {
    fprintf(stderr, "usage: check STEPS INTERVAL [existing-output-directory]; "
                    "STEPS must be divisible by INTERVAL\n");
    return 2;
  }
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  if (n.my_rank == 0) printf("step,res,div,ur,uz\n");
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
            (double)(stop.tv_sec - start.tv_sec) +
            1e-9 * (double)(stop.tv_nsec - start.tv_nsec), ok ? "ok" : "failed");
  Formura_Finalize();
  return ok ? 0 : 1;
}
