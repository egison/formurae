#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "lbm_d3q19.h"

/* D3Q19 BGK shear wave u_y = u0 sin(kk x): the amplitude decays at the
 * exact lattice viscosity nu = (tau - 1/2)/3 = 0.1.  Checks: measured
 * nu from the Fourier amplitude, exact mass conservation, and the
 * transverse velocities staying zero by symmetry. */

#define NX 64
#define Q 19

static const int CX[Q] = {0, 1,-1, 0, 0, 0, 0, 1,-1, 1,-1, 1,-1, 1,-1, 0, 0, 0, 0};
static const int CY[Q] = {0, 0, 0, 1,-1, 0, 0, 1,-1,-1, 1, 0, 0, 0, 0, 1,-1, 1,-1};
static const int CZ[Q] = {0, 0, 0, 0, 0, 1,-1, 0, 0, 0, 0, 1,-1,-1, 1, 1,-1,-1, 1};

static double fval(int a, int i, int j, int k) {
  switch (a) {
    case 0: return formura_data.f0[i][j][k];
    case 1: return formura_data.f1[i][j][k];
    case 2: return formura_data.f2[i][j][k];
    case 3: return formura_data.f3[i][j][k];
    case 4: return formura_data.f4[i][j][k];
    case 5: return formura_data.f5[i][j][k];
    case 6: return formura_data.f6[i][j][k];
    case 7: return formura_data.f7[i][j][k];
    case 8: return formura_data.f8[i][j][k];
    case 9: return formura_data.f9[i][j][k];
    case 10: return formura_data.f10[i][j][k];
    case 11: return formura_data.f11[i][j][k];
    case 12: return formura_data.f12[i][j][k];
    case 13: return formura_data.f13[i][j][k];
    case 14: return formura_data.f14[i][j][k];
    case 15: return formura_data.f15[i][j][k];
    case 16: return formura_data.f16[i][j][k];
    case 17: return formura_data.f17[i][j][k];
    default: return formura_data.f18[i][j][k];
  }
}

/* Fourier amplitude of u_y at wavenumber kk, plus symmetry probes */
static void probe(Formura_Navi n, double kk, double *amp, double *uxm, double *uzm) {
  double A = 0, mx = 0, mz = 0;
  for (int i = n.lower_x; i < n.upper_x; i++) {
    double rho = 0, muy = 0, mux = 0, muz = 0;
    for (int a = 0; a < Q; a++) {
      double f = fval(a, i, 2, 2);
      rho += f; mux += CX[a] * f; muy += CY[a] * f; muz += CZ[a] * f;
    }
    double xc = to_pos_x(i, n);
    A += (muy / rho) * sin(kk * xc);
    if (fabs(mux / rho) > mx) mx = fabs(mux / rho);
    if (fabs(muz / rho) > mz) mz = fabs(muz / rho);
  }
  *amp = 2.0 * A / NX; *uxm = mx; *uzm = mz;
}

static double mass(Formura_Navi n) {
  double m = 0;
  for (int i = n.lower_x; i < n.upper_x; i++)
    for (int j = n.lower_y; j < n.upper_y; j++)
      for (int k = n.lower_z; k < n.upper_z; k++)
        for (int a = 0; a < Q; a++)
          m += fval(a, i, j, k);
  return m;
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 1000;
  double kk = 0.09817477042468103, tau = 0.8;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  double a0, a1, uxm, uzm;
  probe(n, kk, &a0, &uxm, &uzm);
  double m0 = mass(n);

  while (n.time_step < steps) Formura_Forward(&n);

  probe(n, kk, &a1, &uxm, &uzm);
  double nu = -log(a1 / a0) / (kk * kk * steps);
  double nuth = (tau - 0.5) / 3.0;
  double mdrift = fabs(mass(n) - m0) / m0;

  printf("t=%d  amp %.5f -> %.5f  measured nu=%.5f (BGK exact %.5f, dev %.2e)\n",
         steps, a0, a1, nu, nuth, fabs(nu - nuth) / nuth);
  printf("      mass drift=%.2e  max|ux|=%.2e  max|uz|=%.2e\n", mdrift, uxm, uzm);
  int ok = fabs(nu - nuth) / nuth < 0.02 && mdrift < 1e-12 && uxm < 1e-10 && uzm < 1e-10;
  printf("BGK viscosity + exact mass conservation + symmetry: [%s]\n", ok ? "OK" : "NG");
  Formura_Finalize();
  return ok ? 0 : 1;
}
