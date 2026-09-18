/* Configuration, generated-solver calls and output; no model calculations. */
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "kinetic_transport.h"
double kineticTransportConfiguration[6];
static double real(const char *s) {
  char *end; errno=0; double v=strtod(s,&end);
  if(errno || end==s || *end || !isfinite(v)) exit(2);
  return v;
}
static void report(Formura_Navi *n) {
  printf("%d",n->time_step);
  printf(",%.17g",n->reduce_elapsed);
  printf(",%.17g",n->reduce_totalMass);
  printf(",%.17g",n->reduce_waterMass);
  printf(",%.17g",n->reduce_waterVolume);
  printf(",%.17g",n->reduce_momentumX);
  printf(",%.17g",n->reduce_momentumY);
  printf(",%.17g",n->reduce_lowest);
  printf(",%.17g",n->reduce_highest);
  printf(",%.17g",n->reduce_densityLowest);
  printf(",%.17g",n->reduce_densityHighest);
  printf(",%.17g",n->reduce_populationLowest);
  printf(",%.17g",n->reduce_equilibriumLowest);
  printf(",%.17g",n->reduce_collisionResidual);
  printf(",%.17g",n->reduce_consistencyError);
  printf(",%.17g",n->reduce_fractionCourant);
  printf(",%.17g",n->reduce_populationCourant);
  printf(",%.17g",n->reduce_stationaryError);
  printf(",%.17g",n->reduce_translationL1);
  printf(",%.17g",n->reduce_translationMaximum);
  printf(",%.17g",n->reduce_movedAmount);
  printf(",%.17g",n->reduce_mixing);
  printf(",%.17g",n->reduce_velocityChange);
  printf(",%.17g",n->reduce_minArea);
  putchar('\n');
}
int main(int argc,char **argv) {
  if(argc!=9) return 2;
  double requested=real(argv[1]);
  if(requested<0 || requested>1000000 || requested!=floor(requested)) return 2;
  double interval=real(argv[2]);
  if(interval<1 || interval!=floor(interval)) return 2;
  for(int k=0;k<6;++k) kineticTransportConfiguration[k]=real(argv[k+3]);
  if(kineticTransportConfiguration[5]<=0) return 2;
  Formura_Navi n; Formura_Init(&argc,&argv,&n);
  puts("update,elapsed,totalMass,waterMass,waterVolume,momentumX,momentumY,lowest,highest,densityLowest,densityHighest,populationLowest,equilibriumLowest,collisionResidual,consistencyError,fractionCourant,populationCourant,stationaryError,translationL1,translationMaximum,movedAmount,mixing,velocityChange,minArea");
  report(&n);
  while(n.time_step<2*(int)requested) { Formura_Forward(&n); if(n.time_step%(2*(int)interval)==0 || n.time_step==2*(int)requested) report(&n); }
  Formura_Finalize(); return 0;
}
