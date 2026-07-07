#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "mhd_ot.h"

/* Orszag-Tang sanity: exact conservation of all summed conserved
 * variables (via generated reductions), div B preserved at rounding
 * level by the central-difference induction, positive density and
 * pressure throughout, and a PGM snapshot of rho for the eye. */

static double divBmax(Formura_Navi n) {
  double m = 0, tp = 6.283185307179586; (void)tp;
  int NX = n.total_grid_x, NY = n.total_grid_y;
  int k = 1;
  for (int i = n.lower_x; i < n.upper_x; i++)
    for (int j = n.lower_y; j < n.upper_y; j++) {
      int ip = (i+1)%NX, im = (i-1+NX)%NX, jp = (j+1)%NY, jm = (j-1+NY)%NY;
      double d = (formura_data.bx[ip][j][k] - formura_data.bx[im][j][k]) / (2*n.space_interval_x)
               + (formura_data.by[i][jp][k] - formura_data.by[i][jm][k]) / (2*n.space_interval_y);
      if (fabs(d) > m) m = fabs(d);
    }
  return m;
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 1250;
  double gam = 5.0/3.0;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  double srho0 = n.reduce_srho, sen0 = n.reduce_sen;
  printf("t=0     srho=%.12e sen=%.12e divB=%.2e\n", srho0, sen0, divBmax(n));

  while (n.time_step < steps) Formura_Forward(&n);

  double rmin = 1e300, pmin = 1e300;
  for (int i = n.lower_x; i < n.upper_x; i++)
    for (int j = n.lower_y; j < n.upper_y; j++) {
      int k = 1;
      double r = formura_data.rho[i][j][k];
      double m2 = formura_data.mx[i][j][k]*formura_data.mx[i][j][k]
                + formura_data.my[i][j][k]*formura_data.my[i][j][k]
                + formura_data.mz[i][j][k]*formura_data.mz[i][j][k];
      double b2 = formura_data.bx[i][j][k]*formura_data.bx[i][j][k]
                + formura_data.by[i][j][k]*formura_data.by[i][j][k]
                + formura_data.bz[i][j][k]*formura_data.bz[i][j][k];
      double p = (gam-1)*(formura_data.en[i][j][k] - 0.5*m2/r - 0.5*b2);
      if (r < rmin) rmin = r;
      if (p < pmin) pmin = p;
    }
  double drho = fabs(n.reduce_srho - srho0)/fabs(srho0);
  double den  = fabs(n.reduce_sen - sen0)/fabs(sen0);
  double db   = divBmax(n);
  printf("t=%.3f srho drift=%.2e sen drift=%.2e |smx|=%.2e |smy|=%.2e\n",
         steps*0.0004, drho, den, fabs(n.reduce_smx), fabs(n.reduce_smy));
  printf("        divB=%.2e  rho_min=%.4f  p_min=%.4f\n", db, rmin, pmin);

  /* PGM of rho midplane */
  FILE *fp = fopen("mhd_rho.pgm", "w");
  fprintf(fp, "P2\n%d %d\n255\n", 128, 128);
  double lo = 1e300, hi = -1e300;
  for (int j = 0; j < 128; j++) for (int i = 0; i < 128; i++) {
    double v = formura_data.rho[i][j][1];
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  for (int j = 0; j < 128; j++) {
    for (int i = 0; i < 128; i++) {
      int c = (int)(255.0*(formura_data.rho[i][j][1]-lo)/(hi-lo+1e-300));
      fprintf(fp, "%d ", c);
    }
    fprintf(fp, "\n");
  }
  fclose(fp);
  printf("wrote mhd_rho.pgm (rho in [%.4f, %.4f])\n", lo, hi);

  int ok = drho < 1e-10 && den < 1e-10 && fabs(n.reduce_smx) < 1e-9 && fabs(n.reduce_smy) < 1e-9
        && db < 1e-8 && rmin > 0.02 && pmin > 0.001 && isfinite(drho+den+db);
  printf("conservation/divB/positivity: [%s]\n", ok ? "OK" : "NG");
  Formura_Finalize();
  return ok ? 0 : 1;
}
