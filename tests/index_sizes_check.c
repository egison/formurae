/* Independent Fourier-mode oracle; the evolving solution is generated from FME. */
#include <math.h>
#include <stdio.h>
#include "model.h"

static int near(double value, double expected) {
  return isfinite(value) && fabs(value - expected) < 1e-9;
}

static int check(Formura_Navi n) {
  const double h = 6.283185307179586 / 16;
  const double decay = pow(1 - 0.001 * 4 * pow(sin(h/2), 2)/(h*h), n.time_step);
  const double previous = n.time_step == 0 ? 0 :
    pow(1 - 0.001 * 4 * pow(sin(h/2), 2)/(h*h), n.time_step - 1);
  for (int i = n.lower_x; i < n.upper_x; ++i) {
    int xi = ((i + n.offset_x) % n.total_grid_x + n.total_grid_x) % n.total_grid_x;
    double x = xi*h;
    for (int j = n.lower_y; j < n.upper_y; ++j) {
      int yj = ((j + n.offset_y) % n.total_grid_y + n.total_grid_y) % n.total_grid_y;
      double y = yj*h, mode = sin(x)*decay;
      if (!near(formura_data.f_down1[i][j], mode) ||
          !near(formura_data.f_down9[i][j], 9*mode) ||
          !near(formura_data.total[i][j], 45*mode) ||
          !near(formura_data.selected[i][j], 9*mode) ||
          !near(formura_data.moment_down1[i][j], 285*mode) ||
          !near(formura_data.moment_down2[i][j], 570*mode) ||
          !near(formura_data.gradient_down9_down1[i][j],
                9*cos(x)*previous*sin(h)/h) ||
          !near(formura_data.gradient_down9_down2[i][j], 0) ||
          !near(formura_data.M_down3_down2[i][j], 8) ||
          !near(formura_data.S_down2_down3[i][j], 5) ||
          !near(formura_data.A_down2_down3[i][j], 5) ||
          !near(formura_data.face_down9_down1[i][j], sin(x+h/2)) ||
          !near(formura_data.face_down9_down2[i][j], cos(y+h/2)) ||
          !near(formura_data.pair_down1[i][j], sin(x)) ||
          !near(formura_data.pair_down2[i][j], cos(y))) {
        fprintf(stderr, "index size/placement check failed: step=%d cell=(%d,%d)\n",
                n.time_step, xi, yj);
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
