#ifndef FREE_SURFACE_CONFIG_H
#define FREE_SURFACE_CONFIG_H
#include <stdlib.h>
extern double surfaceConfiguration[27];
extern int surfaceFrameInterval;
static inline double surfaceConfig(double key) {
  for(int k=0;k<27;k++) if(key==k) return surfaceConfiguration[k];
  exit(2);
}
#endif
