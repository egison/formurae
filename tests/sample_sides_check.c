/* An independent analytic oracle for sampling, including periodic halos. */
#include <math.h>
#include <stdio.h>
#include "model.h"
static int near(double a, double b) { return isfinite(a) && fabs(a-b)<1e-11; }
static int check(Formura_Navi n) {
  const double h=6.283185307179586/16;
  for (int i=n.lower_x; i<n.upper_x; ++i) {
    double x=(i+n.offset_x)*h;
    for (int j=n.lower_y; j<n.upper_y; ++j) {
      double y=(j+n.offset_y)*h;
      if (!near(formura_data.lower_down1[i][j], (sin(x)+cos(y))*cos(x)) ||
          !near(formura_data.upper_down1[i][j], (sin(x+h)+cos(y))*cos(x+h)) ||
          !near(formura_data.lower_down2[i][j], (sin(x)+cos(y))*cos(y)) ||
          !near(formura_data.upper_down2[i][j], (sin(x)+cos(y+h))*cos(y+h)) ||
          !near(formura_data.backLower_down1[i][j], sin(x-h/2)+cos(y)) ||
          !near(formura_data.backUpper_down1[i][j], sin(x+h/2)+cos(y)) ||
          !near(formura_data.backLower_down2[i][j], sin(x)+cos(y-h/2)) ||
          !near(formura_data.backUpper_down2[i][j], sin(x)+cos(y+h/2)) ||
          !near(formura_data.populations_down1_down9[i][j], 9*(sin(x)+cos(y))) ||
          !near(formura_data.populations_down2_down9[i][j], 9*(sin(x)+cos(y+h)))) {
        fprintf(stderr,"side sample mismatch at %d,%d step %d\n",i,j,n.time_step);
        return 0;
      }
    }
  }
  return 1;
}
int main(int argc,char **argv) {
  Formura_Navi n; Formura_Init(&argc,&argv,&n);
  int ok=1;
  while(ok && n.time_step<8) { Formura_Forward(&n); ok=check(n); }
  Formura_Finalize(); return ok?0:1;
}
