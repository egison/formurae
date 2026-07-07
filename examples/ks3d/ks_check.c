#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "ks3d.h"

/* Kuramoto-Sivashinsky, L=22 chaotic attractor.  Phase 1 (t=5, inside
 * the Lyapunov horizon): the generated code must agree with an
 * independent reference implementation of the same discretization.
 * Phase 2 (t=90): chaos statistics -- bounded amplitude, rms inside the
 * attractor band, exact conservation of sum u (all terms telescope). */

#define NX 64

static double ru[NX], rn[NX], rw[NX];

static void refStep(int steps, double dt, double h) {
  for (int t = 0; t < steps; t++) {
    for (int i = 0; i < NX; i++) {
      int ip = (i+1)%NX, im = (i-1+NX)%NX;
      rw[i] = (ru[ip] - 2*ru[i] + ru[im])/(h*h);
    }
    for (int i = 0; i < NX; i++) {
      int ip = (i+1)%NX, im = (i-1+NX)%NX;
      double fl = (ru[ip]*ru[ip]/2 - ru[im]*ru[im]/2)/(2*h);
      double w4 = (rw[ip] - 2*rw[i] + rw[im])/(h*h);
      rn[i] = ru[i] - dt*(fl + rw[i] + w4);
    }
    for (int i = 0; i < NX; i++) ru[i] = rn[i];
  }
}

static double maxDiff(Formura_Navi n) {
  double md = 0;
  for (int i = n.lower_x; i < n.upper_x; i++) {
    int c = (int)floor(to_pos_x(i, n)/n.space_interval_x + 0.5);
    c = ((c % NX) + NX) % NX;
    double d = fabs(formura_data.u[i][2][2] - ru[c]);
    if (d > md) md = d;
  }
  return md;
}

static double rms(Formura_Navi n) {
  double s = 0;
  for (int i = n.lower_x; i < n.upper_x; i++) {
    double v = formura_data.u[i][2][2];
    s += v*v;
  }
  return sqrt(s/NX);
}

int main(int argc, char **argv) {
  int s1 = 33334, s2 = 600000;             /* t=5 and t=90 */
  double dt = 0.00015, h = 22.0/NX;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  double us0 = n.reduce_usum;
  for (int i = 0; i < NX; i++)
    ru[i] = cos(0.28559933214452665*i*h) + 0.1*cos(0.5711986642890533*i*h);

  while (n.time_step < s1) Formura_Forward(&n);
  refStep(s1, dt, h);
  double md = maxDiff(n);

  while (n.time_step < s2) Formura_Forward(&n);
  double r = rms(n), udrift = fabs(n.reduce_usum - us0);

  printf("t=%.1f  max|u-ref|=%.2e   (Lyapunov-horizon comparison)\n", s1*dt, md);
  printf("t=%.1f  rms=%.3f (attractor band [0.8,2.2])  |u|max=%.3f  sum-u drift=%.2e\n",
         s2*dt, r, n.reduce_umax, udrift);
  int ok = md < 1e-10 && isfinite(r) && r > 0.8 && r < 2.2
        && n.reduce_umax < 6.0 && udrift < 1e-9;
  printf("reference agreement + chaotic attractor statistics: [%s]\n", ok ? "OK" : "NG");
  Formura_Finalize();
  return ok ? 0 : 1;
}
