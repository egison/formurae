/* Numerical updates and diagnostics are generated from FME. This driver
 * only advances the solver and prints its reductions. */
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "kinetic_coordinates.h"

static double kinetic_stretch, kinetic_shear, kinetic_scenario;

/* Input parameters only: no geometry or physical quantities are computed. */
double kineticConfig(double key) {
  if (key == 0) return kinetic_stretch;
  if (key == 1) return kinetic_shear;
  if (key == 2) return kinetic_scenario;
  exit(2);
}

static double real(const char *text) {
  char *end;
  errno = 0;
  double value = strtod(text, &end);
  if (errno || *end || !isfinite(value)) exit(2);
  return value;
}

static int positive(const char *text) {
  char *end;
  errno = 0;
  long value = strtol(text, &end, 10);
  if (errno || *end || value <= 0 || value > 10000000) exit(2);
  return (int)value;
}

static int report(Formura_Navi *n) {
  printf("%d,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g\n",
         n->time_step/3, n->reduce_elapsed, n->reduce_mass,
         n->reduce_momentum_x, n->reduce_momentum_y, n->reduce_mode,
         n->reduce_energy, n->reduce_error, n->reduce_rmin,
         n->reduce_rmax, n->reduce_bad);
  fflush(stdout);
  return isfinite(n->reduce_mass) && isfinite(n->reduce_error) &&
         isfinite(n->reduce_energy) && n->reduce_bad == 0;
}

int main(int argc, char **argv) {
  if (argc != 6) return 2;
  int steps = positive(argv[1]), every = positive(argv[2]);
  if (steps % every) return 2;
  kinetic_stretch = real(argv[3]);
  kinetic_shear = real(argv[4]);
  kinetic_scenario = real(argv[5]);
  if (fabs(kinetic_stretch) >= 1 || kinetic_scenario < 0 || kinetic_scenario > 2) return 2;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  puts("step,time,mass,momentum_x,momentum_y,mode,energy,error,rmin,rmax,bad");
  int ok = report(&n);
  for (int target = every; ok && target <= steps; target += every) {
    while (n.time_step < 3*target) Formura_Forward(&n);
    ok = n.time_step == 3*target && report(&n);
  }
  Formura_Finalize();
  return ok ? 0 : 1;
}
