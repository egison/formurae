#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "pearson3d.h"

/* Sanity driver for the mycorrhiza (Pearson) reproduction:
 * values stay bounded, no NaN, and the seeded V colony spreads.
 * Emits an ASCII rendering and a PGM image of the V midplane.
 * argv: [steps]                                                     */

static int countV(Formura_Navi n, double thr) {
  int c = 0;
  for (int ix = n.lower_x; ix < n.upper_x; ix++)
    for (int iy = n.lower_y; iy < n.upper_y; iy++)
      for (int iz = n.lower_z; iz < n.upper_z; iz++)
        if (formura_data.V[ix][iy][iz] > thr) c++;
  return c;
}

static void minmax(Formura_Navi n, double *mn, double *mx, int *bad,
                   double a[64][64][64]) {
  *mn = 1e300; *mx = -1e300; *bad = 0;
  for (int ix = n.lower_x; ix < n.upper_x; ix++)
    for (int iy = n.lower_y; iy < n.upper_y; iy++)
      for (int iz = n.lower_z; iz < n.upper_z; iz++) {
        double v = a[ix][iy][iz];
        if (!isfinite(v)) (*bad)++;
        if (v < *mn) *mn = v;
        if (v > *mx) *mx = v;
      }
}

static void ascii(Formura_Navi n) {
  const char *pal = " .:-=+*#%@";
  int mid = (n.lower_z + n.upper_z) / 2;
  for (int iy = n.lower_y; iy < n.upper_y; iy += 2) {
    for (int ix = n.lower_x; ix < n.upper_x; ix++) {
      double v = formura_data.V[ix][iy][mid];
      int c = (int)(v * 25.0); if (c < 0) c = 0; if (c > 9) c = 9;
      putchar(pal[c]);
    }
    putchar('\n');
  }
}

static void pgm(Formura_Navi n, const char *fn) {
  FILE *fp = fopen(fn, "w");
  int mid = (n.lower_z + n.upper_z) / 2;
  fprintf(fp, "P2\n%d %d\n255\n", n.upper_x - n.lower_x, n.upper_y - n.lower_y);
  for (int iy = n.lower_y; iy < n.upper_y; iy++) {
    for (int ix = n.lower_x; ix < n.upper_x; ix++) {
      double v = formura_data.V[ix][iy][mid];
      int c = (int)(v * 640.0); if (c < 0) c = 0; if (c > 255) c = 255;
      fprintf(fp, "%d ", c);
    }
    fprintf(fp, "\n");
  }
  fclose(fp);
  printf("wrote %s\n", fn);
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 20000;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);

  int seed0 = countV(n, 0.05);
  printf("t=0  V-cells(>0.05)=%d\n", seed0);

  while (n.time_step < steps) {
    Formura_Forward(&n);
    if (n.time_step % (steps / 5) < 4)
      printf("t=%d  V-cells=%d\n", n.time_step, countV(n, 0.05));
  }

  double mnU, mxU, mnV, mxV; int badU, badV;
  minmax(n, &mnU, &mxU, &badU, formura_data.U);
  minmax(n, &mnV, &mxV, &badV, formura_data.V);
  int grown = countV(n, 0.05);
  printf("t=%d  U in [%.4f, %.4f]  V in [%.4f, %.4f]  nan=%d\n",
         n.time_step, mnU, mxU, mnV, mxV, badU + badV);
  printf("V colony: %d -> %d cells (x%.1f)\n", seed0, grown,
         (double)grown / seed0);
  ascii(n);
  pgm(n, "pearson_V.pgm");

  int ok_finite = (badU + badV) == 0;
  int ok_range  = mnU > -0.01 && mxU < 1.3 && mnV > -0.01 && mxV < 1.0;
  int ok_grow   = grown > 3 * seed0;
  printf("finite [%s]  range [%s]  growth [%s]\n",
         ok_finite ? "OK" : "NG", ok_range ? "OK" : "NG", ok_grow ? "OK" : "NG");
  Formura_Finalize();
  return (ok_finite && ok_range && ok_grow) ? 0 : 1;
}
