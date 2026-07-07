#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#define NX 32
#define NY 16
#define NZ 16
/* reference 3D heat: x=mirror, y=periodic, z=fixed 0.0 ; argv[1]=steps */
static double q[NX][NY][NZ], qn[NX][NY][NZ];
static double at(int i,int j,int k){
  if (i<0) i=0; else if (i>=NX) i=NX-1;              /* mirror x */
  j=(j+NY)%NY;                                        /* periodic y */
  if (k<0||k>=NZ) return 0.0;                         /* fixed z */
  return q[i][j][k];
}
int main(int argc, char **argv) {
  int steps = atoi(argv[1]);
  double c = 0.05;
  for (int i=0;i<NX;i++) for (int j=0;j<NY;j++) for (int k=0;k<NZ;k++)
    q[i][j][k]=0.001*((i+1)*(32-i)+2.0*j*(16-j)+(k+2)*(k+5));
  for (int t=0;t<steps;t++){
    for (int i=0;i<NX;i++) for (int j=0;j<NY;j++) for (int k=0;k<NZ;k++)
      qn[i][j][k]=q[i][j][k]+c*(at(i+1,j,k)+at(i-1,j,k)+at(i,j+1,k)+at(i,j-1,k)+at(i,j,k+1)+at(i,j,k-1)-6.0*q[i][j][k]);
    memcpy(q,qn,sizeof q);
  }
  for (int i=0;i<NX;i++) for (int j=0;j<NY;j++) for (int k=0;k<NZ;k++)
    printf("%d %d %d %.17e\n",i,j,k,q[i][j][k]);
  return 0;
}
