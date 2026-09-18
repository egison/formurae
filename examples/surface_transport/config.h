#ifndef SURFACE_TRANSPORT_CONFIG_H
#define SURFACE_TRANSPORT_CONFIG_H
#include <stdlib.h>

extern double surfaceTransportConfiguration[7];

/* Configuration lookup only; inlining avoids repeated external calls per cell. */
static inline double interfaceConfig(double key) {
  for (int k=0;k<7;k++) if(key==k) return surfaceTransportConfiguration[k];
  exit(2);
}
#endif
