/* Configuration, generated-solver calls and output; no model calculations. */
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "kinetic_surface.h"
static double configuration[6];
double surfaceConfig(double key) {
  for(int k=0;k<6;++k) if(key==k) return configuration[k];
  exit(2);
}
static double real(const char *s) {
  char *end; errno=0; double v=strtod(s,&end);
  if(errno || end==s || *end || !isfinite(v)) exit(2);
  return v;
}
static void report(Formura_Navi *n) {
  printf("%d",n->time_step);
  printf(",%.17g",n->reduce_elapsed);
  printf(",%.17g",n->reduce_waterMass);
  printf(",%.17g",n->reduce_surfaceMode);
  printf(",%.17g",n->reduce_surfaceMean);
  printf(",%.17g",n->reduce_surfaceMaximum);
  printf(",%.17g",n->reduce_speed);
  printf(",%.17g",n->reduce_lowest);
  printf(",%.17g",n->reduce_collisionResidual);
  printf(",%.17g",n->reduce_forceResidual);
  printf(",%.17g",n->reduce_wallMassFlux);
  printf(",%.17g",n->reduce_surfaceStressError);
  printf(",%.17g",n->reduce_surfaceShearError);
  printf(",%.17g",n->reduce_couplingError);
  printf(",%.17g",n->reduce_crossingTime);
  printf(",%.17g",n->reduce_period);
  printf(",%.17g",n->reduce_periodError);
  printf(",%.17g",n->reduce_referencePeriod);
  printf(",%.17g",n->reduce_minArea);
  putchar('\n');
}
int main(int argc,char **argv) {
  if(argc!=9) return 2;
  double requested=real(argv[1]);
  if(requested<0 || requested>1000000 || requested!=floor(requested)) return 2;
  double interval=real(argv[2]);
  if(interval<1 || interval!=floor(interval)) return 2;
  for(int k=0;k<6;++k) configuration[k]=real(argv[k+3]);
  if(configuration[4]<=0) return 2;
  Formura_Navi n; Formura_Init(&argc,&argv,&n);
  puts("update,elapsed,waterMass,surfaceMode,surfaceMean,surfaceMaximum,speed,lowest,collisionResidual,forceResidual,wallMassFlux,surfaceStressError,surfaceShearError,couplingError,crossingTime,period,periodError,referencePeriod,minArea");
  report(&n);
  while(n.time_step<2*(int)requested) { Formura_Forward(&n); if(n.time_step%(2*(int)interval)==0 || n.time_step==2*(int)requested) report(&n); }
  Formura_Finalize(); return 0;
}
