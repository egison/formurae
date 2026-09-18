/* Configuration, generated-solver calls and diagnostic output only. */
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "surface_transport.h"
double surfaceTransportConfiguration[7];
static double real(const char *s) {
  char *end; errno=0; double value=strtod(s,&end);
  if(errno || end==s || *end || !isfinite(value)) exit(2);
  return value;
}
static void report(Formura_Navi *n) {
  printf("%d",n->time_step);
#define OUTPUT(name) printf(",%.17g",n->reduce_##name)
  OUTPUT(elapsed); OUTPUT(waterVolume); OUTPUT(initialVolumeError);
  OUTPUT(lowest); OUTPUT(highest); OUTPUT(mixing); OUTPUT(returnedL1);
  OUTPUT(returnedMaximum); OUTPUT(stationaryError); OUTPUT(movedArea);
  OUTPUT(boundCourant); OUTPUT(closure); OUTPUT(boundaryFlow); OUTPUT(minArea);
#undef OUTPUT
  putchar('\n');
}
int main(int argc,char **argv) {
  if(argc!=10) return 2;
  double requested=real(argv[1]), interval=real(argv[2]);
  if(requested<1 || requested>1000000 || requested!=floor(requested)) return 2;
  if(interval<1 || interval>1000000 || interval!=floor(interval)) return 2;
  for(int k=0;k<7;k++) surfaceTransportConfiguration[k]=real(argv[k+3]);
  if(surfaceTransportConfiguration[5]<=0 || surfaceTransportConfiguration[6]<=0) return 2;
  Formura_Navi n; Formura_Init(&argc,&argv,&n);
  puts("update,elapsed,waterVolume,initialVolumeError,lowest,highest,mixing,returnedL1,returnedMaximum,stationaryError,movedArea,boundCourant,closure,boundaryFlow,minArea");
  report(&n);
  while(n.time_step<2*(int)requested) {
    Formura_Forward(&n);
    if(n.time_step%(2*(int)interval)==0 || n.time_step==2*(int)requested) report(&n);
  }
  Formura_Finalize(); return 0;
}
