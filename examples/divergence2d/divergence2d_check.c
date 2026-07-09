#include <stdio.h>
#include <math.h>
#include "divergence2d.h"

/* divg should work in a coordinate context whose dimension is 2. */

int main(int argc, char **argv) {
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);

  Formura_Forward(&n);

  const double lx = n.total_grid_x * n.space_interval_x;
  const double ly = n.total_grid_y * n.space_interval_y;
  const double kx = 2.0 * M_PI / lx;
  const double ky = 2.0 * M_PI / ly;
  const double ax = sin(kx * n.space_interval_x) / n.space_interval_x;
  const double ay = sin(ky * n.space_interval_y) / n.space_interval_y;

  double max_err = 0.0;
  double max_ref = 0.0;
  for (int ix = n.lower_x; ix < n.upper_x; ix++) {
    for (int iy = n.lower_y; iy < n.upper_y; iy++) {
      double x = to_pos_x(ix, n);
      double y = to_pos_y(iy, n);
      double ref = ax * cos(kx * x) + ay * cos(ky * y);
      double err = fabs(formura_data.q[ix][iy] - ref);
      if (err > max_err) max_err = err;
      if (fabs(ref) > max_ref) max_ref = fabs(ref);
    }
  }

  double rel = max_err / (max_ref + 1e-30);
  int ok = rel < 1e-11;
  printf("2D divg discrete symbol: max.err=%.3e rel=%.3e [%s]\n",
         max_err, rel, ok ? "OK" : "NG");

  Formura_Finalize();
  return ok ? 0 : 1;
}
