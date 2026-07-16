#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "spherical3d.h"

/* Heat in full 3D spherical coordinates on a shell: r_phys = 1 + r,
 * theta_phys = 1 + theta, mirror walls in r and theta, periodic phi.
 * Checks: independent 3D reference agreement, exact conservation of
 * sum((1+r)^2 sin(1+theta) u), max principle. */

#define NR 32
#define NT 32
#define NP 64

static double ru[NR][NT][NP], rn[NR][NT][NP];
static double fr[NR + 1][NT][NP], ft[NR][NT + 1][NP];

/* Analytic volume weight of the declared embedding,
 * sqrt(g) = (1+r)^2 sin(theta). */
static double H(Formura_Navi n) {
  double s = 0;
  for (int i = n.lower_r; i < n.upper_r; i++) {
    double rp = 1.0 + i * n.space_interval_r;
    for (int j = n.lower_theta; j < n.upper_theta; j++) {
      double sg = rp * rp * sin(1.0 + j * n.space_interval_theta);
      for (int k = n.lower_phi; k < n.upper_phi; k++)
        s += sg * formura_data.u[i][j][k];
    }
  }
  return s;
}

static void refRun(int steps, double dt, double hr, double ht, double hp) {
  for (int i = 0; i < NR; i++)
    for (int j = 0; j < NT; j++)
      for (int k = 0; k < NP; k++)
        ru[i][j][k] = exp(-4.0 * (i * hr - 0.5) * (i * hr - 0.5))
                    * exp(-4.0 * (j * ht - 0.5) * (j * ht - 0.5))
                    * exp(cos(k * hp) - 1.0);
  for (int t = 0; t < steps; t++) {
    for (int j = 0; j < NT; j++)
      for (int k = 0; k < NP; k++) { fr[0][j][k] = 0.0; fr[NR][j][k] = 0.0; }
    for (int i = 0; i + 1 < NR; i++)
      for (int j = 0; j < NT; j++) {
        double A = pow(1.0 + (i + 0.5) * hr, 2) * sin(1.0 + j * ht);
        for (int k = 0; k < NP; k++)
          fr[i + 1][j][k] = A * (ru[i + 1][j][k] - ru[i][j][k]) / hr;
      }
    for (int i = 0; i < NR; i++)
      for (int k = 0; k < NP; k++) { ft[i][0][k] = 0.0; ft[i][NT][k] = 0.0; }
    for (int i = 0; i < NR; i++)
      for (int j = 0; j + 1 < NT; j++) {
        double A = sin(1.0 + (j + 0.5) * ht);
        for (int k = 0; k < NP; k++)
          ft[i][j + 1][k] = A * (ru[i][j + 1][k] - ru[i][j][k]) / ht;
      }
    for (int i = 0; i < NR; i++)
      for (int j = 0; j < NT; j++) {
        double B = 1.0 / sin(1.0 + j * ht);
        double sg = pow(1.0 + i * hr, 2) * sin(1.0 + j * ht);
        for (int k = 0; k < NP; k++) {
          int kp = (k + 1) % NP, km = (k + NP - 1) % NP;
          double fph = B * (ru[i][j][kp] - 2 * ru[i][j][k] + ru[i][j][km]) / (hp * hp);
          rn[i][j][k] = ru[i][j][k] + dt * ((fr[i + 1][j][k] - fr[i][j][k]) / hr
                        + (ft[i][j + 1][k] - ft[i][j][k]) / ht + fph) / sg;
        }
      }
    for (int i = 0; i < NR; i++)
      for (int j = 0; j < NT; j++)
        for (int k = 0; k < NP; k++) ru[i][j][k] = rn[i][j][k];
  }
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 1000;
  double dt = 0.0002;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  double hr = n.space_interval_r, ht = n.space_interval_theta, hp = n.space_interval_phi;
  double H0 = H(n), mx0 = n.reduce_umax, mn0 = n.reduce_umin;

  while (n.time_step < steps) Formura_Forward(&n);

  refRun(steps, dt, hr, ht, hp);
  double md = 0;
  for (int i = n.lower_r; i < n.upper_r; i++)
    for (int j = n.lower_theta; j < n.upper_theta; j++)
      for (int k = n.lower_phi; k < n.upper_phi; k++) {
        double d = fabs(formura_data.u[i][j][k] - ru[i][j][k]);
        if (d > md) md = d;
      }
  double hd = fabs(H(n) - H0) / fabs(H0);
  printf("t=%.2f  heat drift=%.2e  max|u-ref|=%.2e\n", steps * dt, hd, md);
  printf("        extrema: [%.4f, %.4f] -> [%.4f, %.4f]\n",
         mn0, mx0, n.reduce_umin, n.reduce_umax);
  int ok = hd < 1e-11 && md < 1e-11 && n.reduce_umax < mx0 && n.reduce_umin >= mn0;
  printf("spherical shell (3D): conservation + reference + max principle: [%s]\n", ok ? "OK" : "NG");
  Formura_Finalize();
  return ok ? 0 : 1;
}
