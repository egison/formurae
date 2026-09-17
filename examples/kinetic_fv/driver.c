/* Configuration, generated-solver calls, and output only. */
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "kinetic_fv.h"
static double configuration[4];
double fvConfig(double key) {
  if(key==0) return configuration[0];
  if(key==1) return configuration[1];
  if(key==2) return configuration[2];
  if(key==3) return configuration[3];
  exit(2);
}
static double real(const char *s) {
  char *end; errno=0; double v=strtod(s,&end);
  if(errno || *end || !isfinite(v)) exit(2);
  return v;
}
static void report(Formura_Navi *n) {
  printf("%d,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g",n->time_step,
    n->reduce_elapsed,n->reduce_error,n->reduce_lowest,n->reduce_highest,
    n->reduce_cfl,n->reduce_closure,n->reduce_minArea);
  printf(",%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g,%.17g\n",
    n->reduce_m1,n->reduce_m2,n->reduce_m3,n->reduce_m4,n->reduce_m5,
    n->reduce_m6,n->reduce_m7,n->reduce_m8,n->reduce_m9);
}
int main(int argc,char **argv) {
  if(argc!=6) return 2;
  double requested=real(argv[1]);
  if(requested<1 || requested>100000 || requested!=floor(requested)) return 2;
  int steps=(int)requested;
  for(int k=0;k<4;++k) configuration[k]=real(argv[k+2]);
  Formura_Navi n; Formura_Init(&argc,&argv,&n);
  puts("step,time,error,lowest,highest,cfl,closure,minArea,m1,m2,m3,m4,m5,m6,m7,m8,m9");
  report(&n);
  while(n.time_step<steps) { Formura_Forward(&n); report(&n); }
  Formura_Finalize(); return 0;
}
