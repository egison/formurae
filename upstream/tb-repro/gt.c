#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include HDR

/* Ground truth, layout-free: compare the VALUE MULTISET of q (and r)
 * against the closed-form solution q_n = q0 + n*c*Dy r0. */

#define NX 128
#define NY 16
#define NZ 16
#define NC (NX*NY*NZ)
static double q0f(int i,int j,int k){return 0.001*(i*(NX-i)+2.0*j*(NY-j)+3.0*k*(NZ-k));}
static double r0f(int i,int j,int k){return 0.002*(i*(NX-i)+1.0*j*(NY-j)+1.0*k*(NZ-k));}
static int cmpd(const void *a, const void *b){double x=*(const double*)a,y=*(const double*)b;return x<y?-1:x>y?1:0;}

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 8;
  double c = 0.05;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  while (n.time_step < steps) Formura_Forward(&n);

  static double expq[NC], actq[NC], expr_[NC], actr[NC];
  int m = 0;
  for (int i = 0; i < NX; i++) for (int j = 0; j < NY; j++) for (int k = 0; k < NZ; k++) {
    double dyr = r0f(i,(j+1)%NY,k) - r0f(i,(j-1+NY)%NY,k);
    expq[m] = q0f(i,j,k) + steps*c*dyr;
    expr_[m] = r0f(i,j,k);
    m++;
  }
  m = 0;
  for (int ix = n.lower_x; ix < n.upper_x; ix++)
    for (int iy = n.lower_y; iy < n.upper_y; iy++)
      for (int iz = n.lower_z; iz < n.upper_z; iz++) {
        actq[m] = formura_data.q[ix][iy][iz];
        actr[m] = formura_data.r[ix][iy][iz];
        m++;
      }
  qsort(expq,NC,8,cmpd); qsort(actq,NC,8,cmpd);
  qsort(expr_,NC,8,cmpd); qsort(actr,NC,8,cmpd);
  double mq=0, mr=0; int bq=0, br=0;
  for (int i = 0; i < NC; i++) {
    double dq = fabs(actq[i]-expq[i]), dr = fabs(actr[i]-expr_[i]);
    if (dq > mq) mq = dq;
    if (dr > mr) mr = dr;
    if (dq > 1e-9) bq++;
    if (dr > 1e-9) br++;
  }
  printf("q: max|act-exp| = %.3e, cells off = %d/%d\n", mq, bq, NC);
  printf("r: max|act-exp| = %.3e, cells off = %d/%d\n", mr, br, NC);
  return 0;
}
