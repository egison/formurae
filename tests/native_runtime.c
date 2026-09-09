#include "../runtime/formurae_native.h"
static void empty_init(NState *s){(void)s;}
int main(void){
 for(int n=4;n<=256;n*=2){double complex *a=n_alloc(n,sizeof(*a)),*b=n_alloc(n,sizeof(*b));
  for(int j=0;j<n;j++)a[j]=b[j]=sin(.31*j)+I*cos(.17*j);
  n_fft(a,n,0);
  for(int k=0;k<n;k++){double complex expected=0;for(int j=0;j<n;j++)expected+=b[j]*cexp(-2*I*N_PI*j*k/n);assert(cabs(a[k]-expected)<2e-11);}
  n_fft(a,n,1);for(int j=0;j<n;j++)assert(cabs(a[j]-b[j])<2e-13);free(a);free(b);
 }
 NModel model={.fields=6,.nx=25,.ny=64,.extent0=1,.extent1=2*N_PI,.halo=3,.init=empty_init};
 NState *s=n_create(&model,25,64);double *out=s->field[0],*rhs=s->field[1],*a=s->field[2],*b=s->field[3],*c=s->field[4],*w=s->field[5];
 double *exact=n_alloc(s->count,sizeof(double));
 for(int i=0;i<s->total;i++)for(int j=0;j<s->ny;j++){size_t p=(size_t)i*s->ny+j;double x=(i-s->halo)*s->spacing[0],R=1+x;
  a[p]=-1/pow(s->spacing[0],2)+1/(2*R*s->spacing[0]);b[p]=2/pow(s->spacing[0],2);c[p]=-1/pow(s->spacing[0],2)-1/(2*R*s->spacing[0]);w[p]=1/pow(R*s->spacing[1],2);
  exact[p]=sin(N_PI*x)*(cos(3*j*s->spacing[1])+.2*sin(7*j*s->spacing[1]));
 }
 for(int i=s->halo+1;i<s->halo+s->nx-1;i++)for(int j=0;j<s->ny;j++){size_t p=(size_t)i*s->ny+j;
  rhs[p]=a[p]*n_at(s,exact,i-1,j)+b[p]*exact[p]+c[p]*n_at(s,exact,i+1,j)+w[p]*(2*exact[p]-n_at(s,exact,i,j-1)-n_at(s,exact,i,j+1));
 }
 n_poisson(s,out,rhs,a,b,c,w);double error=0;
 for(int i=s->halo;i<s->halo+s->nx;i++)for(int j=0;j<s->ny;j++){size_t p=(size_t)i*s->ny+j;error=fmax(error,fabs(out[p]-exact[p]));}
 assert(error<2e-13);printf("native FFT and elliptic solve: error %.3g\n",error);
 /* A change to coefficients must invalidate the cached factorization. */
 for(size_t p=0;p<s->count;p++){b[p]+=2;rhs[p]+=2*exact[p];}
 n_poisson(s,out,rhs,a,b,c,w);
 for(int i=s->halo+1;i<s->halo+s->nx-1;i++)for(int j=0;j<s->ny;j++){size_t p=(size_t)i*s->ny+j;assert(fabs(out[p]-exact[p])<2e-13);}
 free(exact);n_destroy(s);return 0;
}
