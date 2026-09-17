/* Configuration, generated-solver calls and output; no model calculations. */
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "kinetic_hydrostatic.h"
static double configuration[5];
double hydrostaticConfig(double key) {
  for(int k=0;k<5;++k) if(key==k) return configuration[k];
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
  printf(",%.17g",n->reduce_speed);
  printf(",%.17g",n->reduce_densityError);
  printf(",%.17g",n->reduce_densityMode);
  printf(",%.17g",n->reduce_accelerationError);
  printf(",%.17g",n->reduce_lowest);
  printf(",%.17g",n->reduce_equilibriumLowest);
  printf(",%.17g",n->reduce_collisionResidual);
  printf(",%.17g",n->reduce_forceResidual);
  printf(",%.17g",n->reduce_wallMassFlux);
  printf(",%.17g",n->reduce_wallTangentialFlux);
  printf(",%.17g",n->reduce_minArea);
  putchar('\n');
}
int main(int argc,char **argv) {
  if(argc!=7) return 2;
  double requested=real(argv[1]);
  if(requested<1 || requested>100000 || requested!=floor(requested)) return 2;
  for(int k=0;k<5;++k) configuration[k]=real(argv[k+2]);
  if(configuration[4]<=0) return 2;
  Formura_Navi n; Formura_Init(&argc,&argv,&n);
  puts("update,time,mass,momentumX,momentumY,speed,densityError,densityMode,accelerationError,lowest,equilibriumLowest,collisionResidual,forceResidual,wallMassFlux,wallTangentialFlux,minArea");
  report(&n);
  while(n.time_step<2*(int)requested) { Formura_Forward(&n); report(&n); }
  Formura_Finalize(); return 0;
}
