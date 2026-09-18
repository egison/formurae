#ifndef KINETIC_TRANSPORT_CONFIG_H
#define KINETIC_TRANSPORT_CONFIG_H
#include <stdlib.h>

extern double kineticTransportConfiguration[6];

/* Configuration lookup only; inlining avoids repeated external calls per cell. */
static inline double transportConfig(double key) {
  for (int k=0;k<6;k++) if(key==k) return kineticTransportConfiguration[k];
  exit(2);
}
#endif
