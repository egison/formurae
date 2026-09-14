/* Check initialization dependencies and retention at physical grid points. */
#include <math.h>
#include <stdio.h>
#include "model.h"

static int near(double actual, double expected, double tolerance) {
  return fabs(actual - expected) <= tolerance;
}

static int check(Formura_Navi n) {
  const double spacing = 6.283185307179586 / 16;
  for (int i = n.lower_theta; i < n.upper_theta; ++i) {
    int ci = ((i + n.offset_theta) % n.total_grid_theta + n.total_grid_theta)
             % n.total_grid_theta;
    double theta = ci * spacing;
    double jacobian = 4 * (3 + cos(theta));
    for (int j = n.lower_phi; j < n.upper_phi; ++j) {
      double expected = n.time_step * (2 * jacobian + 7);
      if (!near(formura_data.J[i][j], jacobian, 1e-12) ||
          !near(formura_data.doubled[i][j], 2 * jacobian, 1e-12) ||
          !near(formura_data.v_down1[i][j], sin(theta + spacing / 2), 1e-12) ||
          !near(formura_data.G_down2_down2[i][j], pow(3 + cos(theta), 2), 1e-12) ||
          !near(formura_data.u[i][j], expected, 1e-10)) {
        fprintf(stderr, "static field check failed at step %d, (%d,%d)\n",
                n.time_step, i, j);
        return 0;
      }
    }
  }
  return 1;
}

int main(int argc, char **argv) {
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  int ok = check(n);
  while (ok && n.time_step < 8) {
    Formura_Forward(&n);
    ok = check(n);
  }
  Formura_Finalize();
  return ok ? 0 : 1;
}
