#include <stdio.h>
#include <math.h>
#define N 128
double ey[N], bz[N], eyn[N];
double g(double x){ double d=(x-N/2.0)/8.0; return exp(-d*d); }
int main(){
  double dt=0.1;
  for(int i=0;i<N;i++){ ey[i]=g(i); bz[i]=g(i); }
  for(int t=0;t<500;t++){
    for(int i=0;i<N;i++){ int im=(i+N-1)%N, ip=(i+1)%N; eyn[i]=ey[i]+dt*(bz[im]-bz[ip])/2.0; }
    for(int i=0;i<N;i++){ int im=(i+N-1)%N, ip=(i+1)%N; bz[i]=bz[i]+dt*(eyn[im]-eyn[ip])/2.0; }
    for(int i=0;i<N;i++) ey[i]=eyn[i];
  }
  double C=0,S=0,e=0,m=0; int mx=0;
  for(int i=0;i<N;i++){ double w=ey[i]*ey[i]+bz[i]*bz[i]; e+=w;
    if(fabs(ey[i])>m){m=fabs(ey[i]);mx=i;}
    C+=w*cos(2*M_PI*i/N); S+=w*sin(2*M_PI*i/N); }
  double pos=atan2(S,C)*N/(2*M_PI); if(pos<0)pos+=N;
  printf("1D colloc ref: center=%.2f peak|Ey|=%.3f at %d energy=%.4f (t=50dx)\n", pos, m, mx, e);
  return 0;
}
