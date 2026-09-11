/* Only start/advance the generated solver, inspect its reductions, and dump
 * arrays. Initial conditions, the covariant relaxation and all diagnostics
 * (order, energy, defect winding) are FME. No numerical state is written here. */
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "nematic_torus.h"

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

static void dump(Formura_Navi n, const char *directory) {
  char path[4096];
  int written = snprintf(path, sizeof path, "%s/frame-%07d-rank-%03d.bin",
                         directory, n.time_step, n.my_rank);
  if (written < 0 || (size_t)written >= sizeof path) {
    fprintf(stderr, "output path too long\n"); exit(2);
  }
  FILE *file = fopen(path, "wb");
  if (!file) fail(path);
  int32_t header[] = {n.total_grid_theta, n.total_grid_phi, n.time_step};
  if (fwrite(header, sizeof header, 1, file) != 1) fail("write header");
  for (int i = n.lower_theta; i < n.upper_theta; ++i) {
    int ci = ((i + n.offset_theta) % n.total_grid_theta + n.total_grid_theta)
             % n.total_grid_theta;
    for (int j = n.lower_phi; j < n.upper_phi; ++j) {
      int cj = ((j + n.offset_phi) % n.total_grid_phi + n.total_grid_phi)
               % n.total_grid_phi;
      int32_t index[] = {ci, cj};
      double values[] = {formura_data.Q_up1_up1[i][j], formura_data.Q_up1_up2[i][j],
                         formura_data.Q_up2_up2[i][j], formura_data.order[i][j],
                         formura_data.winding[i][j]};
      if (fwrite(index, sizeof index, 1, file) != 1 ||
          fwrite(values, sizeof values, 1, file) != 1) fail("write field");
    }
  }
  if (fclose(file)) fail("close output");
}

static int report(Formura_Navi n) {
  if (n.my_rank == 0) {
    printf("%d,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g\n",
           n.time_step, n.reduce_energy, n.reduce_omin, n.reduce_omax,
           n.reduce_plus, n.reduce_minus, n.reduce_plusOuter, n.reduce_minusOuter,
           n.reduce_tr, n.reduce_asym);
    fflush(stdout);
#ifdef ACCURACY
    fprintf(stderr, "accuracy step=%d error=%.17g reference=%.17g\n",
            n.time_step, n.reduce_error, n.reduce_reference);
#endif
  }
  return isfinite(n.reduce_energy) && isfinite(n.reduce_omax) &&
         n.reduce_omax < 100 && n.reduce_omin > -1;
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
    puts("step,energy,omin,omax,plus,minus,plusOuter,minusOuter,trace,asym");
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
