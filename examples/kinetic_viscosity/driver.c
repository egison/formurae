/* Runtime configuration, generated-solver calls, and diagnostic output only. */
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "kinetic_viscosity.h"
static double configuration[6];
double viscosityConfig(double key) {
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
  printf(",%.17g",n->reduce_mass);
  printf(",%.17g",n->reduce_momentumX);
  printf(",%.17g",n->reduce_momentumY);
  printf(",%.17g",n->reduce_mode);
  printf(",%.17g",n->reduce_referenceMode);
  printf(",%.17g",n->reduce_modeError);
  printf(",%.17g",n->reduce_velocityError);
  printf(",%.17g",n->reduce_velocityErrorL1);
  printf(",%.17g",n->reduce_populationError);
  printf(",%.17g",n->reduce_densityError);
  printf(",%.17g",n->reduce_lowest);
  printf(",%.17g",n->reduce_equilibriumLowest);
  printf(",%.17g",n->reduce_cfl);
  printf(",%.17g",n->reduce_positivityBound);
  printf(",%.17g",n->reduce_collisionResidual);
  printf(",%.17g",n->reduce_minArea);
  printf(",%.17g",n->reduce_relaxationTime);
  printf(",%.17g",n->reduce_decayRate);
  printf(",%.17g",n->reduce_hydrodynamicViscosity);
  putchar('\n');
}
int main(int argc,char **argv) {
  if(argc!=8) return 2;
  double requested=real(argv[1]);
  if(requested<1 || requested>100000 || requested!=floor(requested)) return 2;
  for(int k=0;k<6;++k) configuration[k]=real(argv[k+2]);
  if(configuration[4]<=0 || configuration[4]>=1.0/3 || configuration[5]<=0) return 2;
  Formura_Navi n; Formura_Init(&argc,&argv,&n);
  puts("update,time,mass,momentumX,momentumY,mode,referenceMode,modeError,velocityError,velocityErrorL1,populationError,densityError,lowest,equilibriumLowest,cfl,positivityBound,collisionResidual,minArea,relaxationTime,decayRate,hydrodynamicViscosity");
  report(&n);
  while(n.time_step<2*(int)requested) { Formura_Forward(&n); report(&n); }
  Formura_Finalize(); return 0;
}
