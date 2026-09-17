/* Drawing-only recorder, included into an existing driver translation unit.
 * The solver is compiled separately, WITHOUT this header. No state is changed.
 * F1..F4 select generated fields; DIM is 2 or 3. FRAME_EVERY counts generated
 * updates and must include only complete time-integration steps.
 * Output: native-endian float64 arrays [field,y,x], at the middle z slice.
 * The Python capture script records dimensions, time and byte order separately.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include HDR

static int frame_last = -1;
static double *frame_values;
static const char *frame_directory;

static void frame_fail(const char *message) {
  fprintf(stderr, "field recorder: %s\n", message);
  exit(2);
}

static void frame_dump(Formura_Navi *n) {
  if (n->time_step == frame_last) return;
  const int nx = n->total_grid_x, ny = n->total_grid_y;
  const size_t plane = (size_t)nx * ny;
#if DIM == 3
  int k = -1;
  for (int candidate = n->lower_z; candidate < n->upper_z; ++candidate) {
    int z = (int)llround(to_pos_z(candidate, *n) / n->space_interval_z);
    if ((z % n->total_grid_z + n->total_grid_z) % n->total_grid_z == n->total_grid_z / 2)
      k = candidate;
  }
  if (k < 0) frame_fail("middle z slice is not local");
#endif
  for (size_t p = 0; p < FRAME_FIELDS * plane; ++p) frame_values[p] = NAN;
  for (int j = n->lower_y; j < n->upper_y; ++j) {
    int y = (int)llround(to_pos_y(j, *n) / n->space_interval_y);
    y = (y % ny + ny) % ny;
    for (int i = n->lower_x; i < n->upper_x; ++i) {
      int x = (int)llround(to_pos_x(i, *n) / n->space_interval_x);
      x = (x % nx + nx) % nx;
      size_t p = (size_t)y * nx + x;
      frame_values[p] = F1;
#if FRAME_FIELDS > 1
      frame_values[plane + p] = F2;
#endif
#if FRAME_FIELDS > 2
      frame_values[2 * plane + p] = F3;
#endif
#if FRAME_FIELDS > 3
      frame_values[3 * plane + p] = F4;
#endif
    }
  }
  for (size_t p = 0; p < FRAME_FIELDS * plane; ++p)
    if (!isfinite(frame_values[p])) frame_fail("missing or nonfinite field value");
  char path[4096];
  int count = snprintf(path, sizeof(path), "%s/%08d.bin", frame_directory, n->time_step);
  if (count < 0 || (size_t)count >= sizeof(path)) frame_fail("output path too long");
  FILE *file = fopen(path, "wb");
  if (!file) frame_fail("cannot open output file");
  if (fwrite(frame_values, sizeof(double), FRAME_FIELDS * plane, file) != FRAME_FIELDS * plane)
    frame_fail("cannot write complete frame");
  if (fclose(file)) frame_fail("cannot close output file");
  frame_last = n->time_step;
}

static void frame_init(int *argc, char ***argv, Formura_Navi *n) {
  Formura_Init(argc, argv, n);
  frame_directory = getenv("FORMURAE_FRAME_DIR");
  if (!frame_directory) frame_fail("FORMURAE_FRAME_DIR is required");
  if (n->upper_x - n->lower_x != n->total_grid_x ||
      n->upper_y - n->lower_y != n->total_grid_y)
    frame_fail("recorder requires a single MPI rank");
  frame_values = malloc((size_t)FRAME_FIELDS * n->total_grid_x * n->total_grid_y * sizeof(double));
  if (!frame_values) frame_fail("cannot allocate frame");
  frame_dump(n);
}

static void frame_forward(Formura_Navi *n) {
  Formura_Forward(n);
  if (n->time_step % FRAME_EVERY == 0) frame_dump(n);
}

static void frame_finalize(void) {
  free(frame_values);
  Formura_Finalize();
}

#define Formura_Init frame_init
#define Formura_Forward frame_forward
#define Formura_Finalize frame_finalize
