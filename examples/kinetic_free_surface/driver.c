/* Configuration, generated-solver calls and output; no model calculations. */
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "kinetic_free_surface.h"
double surfaceConfiguration[28];
int surfaceFrameInterval;
static double real(const char *s) {
  char *end; errno=0; double v=strtod(s,&end);
  if(errno || end==s || *end || !isfinite(v)) exit(2);
  return v;
}
static void report(Formura_Navi *n) {
  if (n->my_rank != 0) return;
  printf("%d",n->time_step);
  printf(",%.17g",n->reduce_elapsed);
  printf(",%.17g",n->reduce_waterMass);
  printf(",%.17g",n->reduce_waterVolume);
  printf(",%.17g",n->reduce_lowest);
  printf(",%.17g",n->reduce_highest);
  printf(",%.17g",n->reduce_densityLowest);
  printf(",%.17g",n->reduce_densityHighest);
  printf(",%.17g",n->reduce_populationLowest);
  printf(",%.17g",n->reduce_peakSpeed);
  printf(",%.17g",n->reduce_restingError);
  printf(",%.17g",n->reduce_wetting);
  printf(",%.17g",n->reduce_drying);
  printf(",%.17g",n->reduce_movedAmount);
  printf(",%.17g",n->reduce_waterMomentumX);
  printf(",%.17g",n->reduce_waterMomentumY);
  printf(",%.17g",n->reduce_kineticEnergy);
  printf(",%.17g",n->reduce_surfaceHeight);
  printf(",%.17g",n->reduce_wetFront);
  printf(",%.17g",n->reduce_shoreFlux);
  printf(",%.17g",n->reduce_minimumArea);
  printf(",%.17g",n->reduce_overhangCells);
  printf(",%.17g",n->reduce_bulkFront);
  printf(",%.17g",n->reduce_fractionCourant);
  printf(",%.17g",n->reduce_pressureResidual);
  printf(",%.17g",n->reduce_waveMoment);
  printf(",%.17g",n->reduce_gravityEnergy);
  printf(",%.17g",n->reduce_waterCentroidX);
  printf(",%.17g",n->reduce_waterCentroidY);
  printf(",%.17g",n->reduce_collisionResidual);
  printf(",%.17g",n->reduce_stateConsistencyError);
  printf(",%.17g",n->reduce_thinFront);
  printf(",%.17g",n->reduce_shoreWaterMass);
  printf(",%.17g",n->reduce_thinWaterMass);
  printf(",%.17g",n->reduce_surfaceGauge);
  printf(",%.17g",n->reduce_firstCrossing);
  printf(",%.17g",n->reduce_wavePeriod);
  printf(",%.17g",n->reduce_expectedPeriod);
  printf(",%.17g",n->reduce_heightReconstructions);
  printf(",%.17g",n->reduce_surfaceReconstructions);
  printf(",%.17g",n->reduce_gaugeSamples);
  printf(",%.17g",n->reduce_wallMassResidual);
  printf(",%.17g",n->reduce_wallSlipResidual);
  printf(",%.17g",n->reduce_relaxationError);
  printf(",%.17g",n->reduce_shearError);
  printf(",%.17g",n->reduce_shearProjection);
  printf(",%.17g",n->reduce_shearExpected);
  printf(",%.17g,%.17g",n->reduce_expectedFallingMomentum,n->reduce_expectedFallingCentroid);
  printf(",%.17g",n->reduce_surfaceMassResidual);
  printf(",%.17g",n->reduce_resolvedCentroidY);
  putchar('\n');
}
int main(int argc,char **argv) {
  if(argc!=31) return 2;
  double requested=real(argv[1]);
  if(requested<0 || requested>1000000 || requested!=floor(requested)) return 2;
  double interval=real(argv[2]);
  if(interval<1 || interval!=floor(interval)) return 2;
  for(int k=0;k<28;++k) surfaceConfiguration[k]=real(argv[k+3]);
  if(surfaceConfiguration[14]<=0) return 2;
  surfaceFrameInterval=8*(int)interval;
  setvbuf(stdout,NULL,_IOLBF,0);
  Formura_Navi n; Formura_Init(&argc,&argv,&n);
  if (n.my_rank == 0) puts("update,elapsed,waterMass,waterVolume,lowest,highest,densityLowest,densityHighest,populationLowest,peakSpeed,restingError,wetting,drying,movedAmount,waterMomentumX,waterMomentumY,kineticEnergy,surfaceHeight,wetFront,shoreFlux,minimumArea,overhangCells,bulkFront,fractionCourant,pressureResidual,waveMoment,gravityEnergy,waterCentroidX,waterCentroidY,collisionResidual,stateConsistencyError,thinFront,shoreWaterMass,thinWaterMass,surfaceGauge,firstCrossing,wavePeriod,expectedPeriod,heightReconstructions,surfaceReconstructions,gaugeSamples,wallMassResidual,wallSlipResidual,relaxationError,shearError,shearProjection,shearExpected,expectedFallingMomentum,expectedFallingCentroid,surfaceMassResidual,resolvedCentroidY");
  report(&n);
  while(n.time_step<8*(int)requested) { Formura_Forward(&n); if(n.time_step%(8*(int)interval)==0 || n.time_step==8*(int)requested) report(&n); }
#ifdef FRAME_FIELDS
  if(frame_last!=n.time_step) frame_dump(&n);
#endif
  Formura_Finalize(); return 0;
}
