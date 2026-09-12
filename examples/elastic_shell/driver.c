/* Only start/advance the generated solver, print its reductions, and dump
 * arrays.  Initial conditions, coefficient fields, updates, and the
 * diagnostics (indicators, energies, shell moments, exact-solution errors)
 * are FME.  Each MPI rank writes its own records; no numerical state is
 * computed here. */
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "elastic_shell.h"

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

static int wrap(int index, int offset, int total) {
  return ((index + offset) % total + total) % total;
}

/* Slice: the equatorial plane (global colatitude index total_theta / 2)
 * with the two wave indicators and the velocity.  Full: every cell with the
 * complete state. */
static void dump(Formura_Navi n, const char *directory, int full) {
  char path[4096];
  int written = snprintf(path, sizeof path, "%s/%s-%07d-rank-%03d.bin", directory,
                         full ? "state" : "slice", n.time_step, n.my_rank);
  if (written < 0 || (size_t)written >= sizeof path) {
    fprintf(stderr, "output path too long\n"); exit(2);
  }
  FILE *file = fopen(path, "wb");
  if (!file) fail(path);
  int32_t header[] = {n.total_grid_r, n.total_grid_theta, n.total_grid_phi, n.time_step, full};
  if (fwrite(header, sizeof header, 1, file) != 1) fail("write header");
  int mid = n.total_grid_theta / 2;
  for (int i = n.lower_r; i < n.upper_r; ++i) {
    int ci = wrap(i, n.offset_r, n.total_grid_r);
    for (int j = n.lower_theta; j < n.upper_theta; ++j) {
      int cj = wrap(j, n.offset_theta, n.total_grid_theta);
      if (!full && cj != mid) continue;
      for (int k = n.lower_phi; k < n.upper_phi; ++k) {
        int ck = wrap(k, n.offset_phi, n.total_grid_phi);
        int32_t index[] = {ci, cj, ck};
        if (fwrite(index, sizeof index, 1, file) != 1) fail("write index");
        if (full) {
          double values[] = {
            formura_data.v_up1[i][j][k], formura_data.v_up2[i][j][k], formura_data.v_up3[i][j][k],
            formura_data.sigma_up1_up1[i][j][k], formura_data.sigma_up2_up2[i][j][k],
            formura_data.sigma_up3_up3[i][j][k], formura_data.sigma_up1_up2[i][j][k],
            formura_data.sigma_up1_up3[i][j][k], formura_data.sigma_up2_up3[i][j][k],
            formura_data.compression[i][j][k], formura_data.shearing[i][j][k]};
          if (fwrite(values, sizeof values, 1, file) != 1) fail("write state");
        } else {
          double values[] = {
            formura_data.compression[i][j][k], formura_data.shearing[i][j][k],
            formura_data.v_up1[i][j][k], formura_data.v_up2[i][j][k], formura_data.v_up3[i][j][k]};
          if (fwrite(values, sizeof values, 1, file) != 1) fail("write slice");
        }
      }
    }
  }
  if (fclose(file)) fail("close output");
}

static int report(Formura_Navi n) {
  if (n.my_rank == 0) {
    printf("%d,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g", n.time_step,
           n.reduce_energy, n.reduce_modified, n.reduce_pw, n.reduce_pr, n.reduce_sw,
           n.reduce_sr, n.reduce_pfront, n.reduce_sfront, n.reduce_vmax);
#ifdef ACCURACY
    printf(",%.17g,%.17g", n.reduce_err, n.reduce_ref);
#endif
    printf("\n");
    fflush(stdout);
  }
  return isfinite(n.reduce_energy) && isfinite(n.reduce_pw) && isfinite(n.reduce_sw) &&
         n.reduce_vmax < 100;
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? integer(argv[1]) : 40;
  int interval = argc > 2 ? integer(argv[2]) : steps;
  const char *directory = argc > 3 ? argv[3] : NULL;
  int full = argc > 4 && strcmp(argv[4], "full") == 0;
  if (interval < 1 || steps % interval) {
    fprintf(stderr, "usage: check STEPS INTERVAL [existing-output-directory [full]]; "
                    "STEPS must be divisible by INTERVAL\n");
    return 2;
  }
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  if (n.my_rank == 0) {
    printf("step,energy,modified,pw,pr,sw,sr,pfront,sfront,vmax");
#ifdef ACCURACY
    printf(",err,ref");
#endif
    printf("\n");
  }
  int ok = report(n);
  if (directory) dump(n, directory, full);
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
    if (directory) dump(n, directory, full);
  }
  timespec_get(&stop, TIME_UTC);
  if (n.my_rank == 0)
    fprintf(stderr, "steps=%d elapsed_seconds=%.6f bounds=%s\n", n.time_step,
            (double)(stop.tv_sec-start.tv_sec) +
            1e-9*(double)(stop.tv_nsec-start.tv_nsec), ok ? "ok" : "failed");
  Formura_Finalize();
  return ok ? 0 : 1;
}
