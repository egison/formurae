#ifndef FORMURAE_NATIVE_H
#define FORMURAE_NATIVE_H
/* Model-independent, serial execution of generated collocated C stages.
   The model owns all equations, integration stages, boundary values and
   elliptic coefficients. This runtime owns arrays, FFT/linear algebra and IO. */
#include <assert.h>
#include <complex.h>
#include <errno.h>
#include <float.h>
#include <math.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#define N_PI 3.141592653589793238462643383279502884

typedef struct {
  int nx,ny,halo,total,nfields,nscratch;
  size_t count;
  double spacing[2], **field, **scratch;
  double complex *fft,*modes;
  double *coeff,*factor,*upper;
  int factor_valid;
} NState;
typedef enum {N_min,N_max,N_maxabs,N_sum,N_first} NReduction;
typedef struct {const char *name;int field;NReduction operation;int margin;} NMonitor;
typedef struct {
  int fields;const char **names;
  int nx,ny;double extent0,extent1;int halo,time,dt,steps,every;
  const int *outputs;int noutputs;const NMonitor *monitors;int nmonitors;
  void (*init)(NState*),(*prepare)(NState*),(*advance)(NState*),(*observe)(NState*);
} NModel;
static void n_fail(const char *message){fprintf(stderr,"formurae-native: %s\n",message);exit(1);}
static void *n_alloc(size_t count,size_t size){void *p=calloc(count,size);if(!p)n_fail("allocation failed");return p;}
static NState *n_create(const NModel *model,int nx,int ny){
  if(!(model->extent0>0 && model->extent1>0 && isfinite(model->extent0) && isfinite(model->extent1)))n_fail("physical extents must be finite and positive");
  if(nx<2*model->halo+3 || ny<4 || (ny&(ny-1))) n_fail("grid needs enough radial points and a power-of-two periodic extent");
  NState *s=n_alloc(1,sizeof(*s));s->nx=nx;s->ny=ny;s->halo=model->halo;s->total=nx+2*s->halo;s->nfields=model->fields;
  s->count=(size_t)s->total*ny;s->spacing[0]=model->extent0/(nx-1);s->spacing[1]=model->extent1/ny;
  s->field=n_alloc(s->nfields,sizeof(double*));for(int f=0;f<s->nfields;f++)s->field[f]=n_alloc(s->count,sizeof(double));
  s->fft=n_alloc(ny,sizeof(double complex));s->modes=n_alloc((size_t)nx*ny,sizeof(double complex));
  s->coeff=n_alloc((size_t)nx*4,sizeof(double));s->factor=n_alloc((size_t)nx*ny,sizeof(double));s->upper=n_alloc((size_t)nx*ny,sizeof(double));
  model->init(s);return s;
}
static double *n_scratch(NState *s,int index){
  if(index>=s->nscratch){int old=s->nscratch;s->scratch=realloc(s->scratch,(index+1)*sizeof(double*));if(!s->scratch)n_fail("scratch allocation failed");
    for(int k=old;k<=index;k++)s->scratch[k]=n_alloc(s->count,sizeof(double));s->nscratch=index+1;}
  return s->scratch[index];
}
static void n_destroy(NState *s){for(int f=0;f<s->nfields;f++)free(s->field[f]);for(int f=0;f<s->nscratch;f++)free(s->scratch[f]);
 free(s->scratch);free(s->field);free(s->fft);free(s->modes);free(s->coeff);free(s->factor);free(s->upper);free(s);}
static inline double n_at(const NState *s,const double *a,int i,int j){if(i<0||i>=s->total)return 0; j%=s->ny;if(j<0)j+=s->ny;return a[(size_t)i*s->ny+j];}
static void n_mean(NState *s,const double *a,double *out){for(int i=0;i<s->total;i++){double sum=0;for(int j=0;j<s->ny;j++)sum+=a[(size_t)i*s->ny+j];
 for(int j=0;j<s->ny;j++)out[(size_t)i*s->ny+j]=sum/s->ny;}}
/* Transfer in the frame specified by a generated per-component scale.
   reflect: mirror about the generated boundary value; extend: constant value;
   odd: antisymmetric extension about a homogeneous Dirichlet boundary. */
static void n_ghost(NState *s,double *a,const double *scale,int kind){
 for(int side=0;side<2;side++){int wall=side?s->halo+s->nx-1:s->halo,sign=side?1:-1;
  for(int k=1;k<=s->halo;k++)for(int j=0;j<s->ny;j++){
   size_t w=(size_t)wall*s->ny+j,g=(size_t)(wall+sign*k)*s->ny+j,in=(size_t)(wall-sign*k)*s->ny+j;
   double value=kind==0?a[w]*scale[w]:(kind<0?0:2*a[w]*scale[w])-a[in]*scale[in];
   if(scale[g]==0)n_fail("zero scale in ghost transfer");a[g]=value/scale[g];
  }
 }
}
/* Unnormalized forward FFT, inverse divided by n. */
static void n_fft(double complex *a,int n,int inverse){
 for(int i=1,j=0;i<n;i++){int bit=n>>1;for(;j&bit;bit>>=1)j^=bit;j^=bit;if(i<j){double complex t=a[i];a[i]=a[j];a[j]=t;}}
 for(int len=2;len<=n;len*=2){double angle=(inverse?2:-2)*N_PI/len;double complex root=cos(angle)+I*sin(angle);
  for(int i=0;i<n;i+=len){double complex w=1;for(int j=0;j<len/2;j++){double complex u=a[i+j],v=a[i+j+len/2]*w;a[i+j]=u+v;a[i+j+len/2]=u-v;w*=root;}}}
 if(inverse)for(int i=0;i<n;i++)a[i]/=n;
}
/* Solve a separable elliptic system with homogeneous radial Dirichlet data
   and zero periodic mean. Coefficients come from generated model fields:
   a_i u_{i-1} + (b_i + 4 sin^2(pi k/ny) w_i)u_i + c_i u_{i+1}=rhs_i.
   The zero Fourier mode is deliberately excluded by this explicit operation;
   models that need a mean degree of freedom evolve it in their own stages. */
static void n_poisson(NState *s,double *out,const double *rhs,const double *a,const double *b,const double *c,const double *w){
 int nx=s->nx,ny=s->ny,h=s->halo,changed=!s->factor_valid;
 const double *coef[4]={a,b,c,w};
 for(int i=0;i<nx;i++)for(int k=0;k<4;k++){
  double value=coef[k][(size_t)(i+h)*ny];if(s->coeff[4*i+k]!=value)changed=1;s->coeff[4*i+k]=value;
  for(int j=1;j<ny;j++)if(fabs(coef[k][(size_t)(i+h)*ny+j]-value)>1e-12*fmax(1,fabs(value)))n_fail("elliptic coefficients must be constant along the periodic axis");
 }
 if(changed){
  for(int k=1;k<ny;k++){double eigen=4*pow(sin(N_PI*k/ny),2);
   for(int i=1;i<nx-1;i++){size_t p=(size_t)k*nx+i;double d=s->coeff[4*i+1]+eigen*s->coeff[4*i+3];if(i>1)d-=s->coeff[4*i]*s->upper[p-1];
    if(!isfinite(d)||fabs(d)<DBL_MIN)n_fail("singular elliptic factorization");s->factor[p]=1/d;s->upper[p]=s->coeff[4*i+2]/d;
   }
  }s->factor_valid=1;
 }
 for(int i=0;i<nx;i++){for(int j=0;j<ny;j++)s->fft[j]=rhs[(size_t)(i+h)*ny+j];n_fft(s->fft,ny,0);for(int k=0;k<ny;k++)s->modes[(size_t)k*nx+i]=s->fft[k];}
 for(int k=0;k<ny;k++){
  double complex *v=s->modes+(size_t)k*nx;v[0]=v[nx-1]=0;
  if(k==0){memset(v,0,nx*sizeof(*v));continue;}
  for(int i=1;i<nx-1;i++)v[i]=(v[i]-s->coeff[4*i]*v[i-1])*s->factor[(size_t)k*nx+i];
  for(int i=nx-3;i>=1;i--)v[i]-=s->upper[(size_t)k*nx+i]*v[i+1];
 }
 for(int i=0;i<nx;i++){for(int k=0;k<ny;k++)s->fft[k]=s->modes[(size_t)k*nx+i];n_fft(s->fft,ny,1);for(int j=0;j<ny;j++)out[(size_t)(i+h)*ny+j]=creal(s->fft[j]);}
}
static double n_reduce(const NState *s,const NMonitor *m){
 if(m->margin*2>=s->nx)n_fail("monitor margin leaves no physical cells");
 const double *a=s->field[m->field];double value=m->operation==N_min?INFINITY:m->operation==N_max?-INFINITY:0;
 if(m->operation==N_first){double x=a[(size_t)s->halo*s->ny];if(!isfinite(x))n_fail("non-finite observed value");return x;}
 for(int i=s->halo+m->margin;i<s->halo+s->nx-m->margin;i++)for(int j=0;j<s->ny;j++){
  double x=a[(size_t)i*s->ny+j];if(!isfinite(x))n_fail("non-finite observed value");
  switch(m->operation){case N_min:value=fmin(value,x);break;case N_max:value=fmax(value,x);break;case N_maxabs:value=fmax(value,fabs(x));break;case N_sum:value+=x;break;case N_first:break;}
 }return value;
}
static void n_require(NState *s,const char *name,int field,NReduction operation,int margin,double bound,int less){
 NMonitor monitor={name,field,operation,margin};double value=n_reduce(s,&monitor);
 if(!(less?value<bound:value>bound)){fprintf(stderr,"required %s %s %.17g; got %.17g\n",name,less?"<":">",bound,value);n_fail("model condition failed");}
}
static void n_snapshot(NState *s,const NModel *m,const char *folder,int frame){
 char path[4096],header[512];snprintf(path,sizeof path,"%s/frame-%04d.npy",folder,frame);FILE *f=fopen(path,"wb");if(!f)n_fail("cannot create snapshot");
 const uint16_t endian=1;if(*(const unsigned char*)&endian!=1)n_fail("NPY writer currently requires a little-endian host");
 int n=snprintf(header,sizeof header,"{'descr': '<f8', 'fortran_order': False, 'shape': (%d, %d, %d), }",m->noutputs,s->nx,s->ny);
 int length=((n+1+10+63)/64)*64-10;if(length>=(int)sizeof header)n_fail("NPY header too long");memset(header+n,' ',length-n);header[length-1]='\n';
 unsigned char magic[]={0x93,'N','U','M','P','Y',1,0,(unsigned char)length,(unsigned char)(length>>8)};
 if(fwrite(magic,1,10,f)!=10||fwrite(header,1,length,f)!=(size_t)length)n_fail("snapshot header write failed");
 for(int k=0;k<m->noutputs;k++)if(fwrite(s->field[m->outputs[k]]+(size_t)s->halo*s->ny,sizeof(double),(size_t)s->nx*s->ny,f)!=(size_t)s->nx*s->ny)n_fail("snapshot write failed");
 if(fclose(f))n_fail("snapshot close failed");
}
static void n_uniform(NState *s,int field,double value){for(size_t p=0;p<s->count;p++)s->field[field][p]=value;}
static int n_integer(const char *text){
 char *end;errno=0;long value=strtol(text,&end,10);
 if(errno||end==text||*end||value<0||value>INT_MAX)n_fail("expected a nonnegative integer option");return (int)value;
}
static double n_timestep(const char *text){
 char *end;errno=0;double value=strtod(text,&end);
 if(errno||end==text||*end||!(value>0)||!isfinite(value))n_fail("expected a positive finite time step");return value;
}
static int n_main(int argc,char **argv,const NModel *m){
 int nx=m->nx,ny=m->ny,steps=m->steps,every=m->every;double dt=0;const char *folder="native-output";
 for(int i=1;i<argc;i++){
  if(!strcmp(argv[i],"--grid")&&i+2<argc){nx=n_integer(argv[++i]);ny=n_integer(argv[++i]);}
  else if(!strcmp(argv[i],"--steps")&&i+1<argc)steps=n_integer(argv[++i]);
  else if(!strcmp(argv[i],"--every")&&i+1<argc)every=n_integer(argv[++i]);
  else if(!strcmp(argv[i],"--dt")&&i+1<argc)dt=n_timestep(argv[++i]);
  else if(!strcmp(argv[i],"--output")&&i+1<argc)folder=argv[++i];
  else n_fail("usage: simulation [--grid NX NY] [--steps N] [--every N] [--dt DT] [--output DIRECTORY]");
 }
 if(steps<0||every<1||steps%every)n_fail("steps must be nonnegative and divisible by every");
 if(mkdir(folder,0777)&&errno!=EEXIST)n_fail("cannot create output directory");
 NState *s=n_create(m,nx,ny);if(dt>0)n_uniform(s,m->dt,dt);dt=s->field[m->dt][(size_t)s->halo*s->ny];if(!(dt>0&&isfinite(dt)))n_fail("invalid timestep");m->prepare(s);
 char path[4096];snprintf(path,sizeof path,"%s/report.json",folder);FILE *f=fopen(path,"w");if(!f)n_fail("cannot create report");
 fprintf(f,"{\n\"backend\":\"formurae-native-c\",\"radial\":%d,\"angular\":%d,\"dt\":%.17g,\"steps\":%d,\"outputs\":[",nx-1,ny,dt,steps);
 for(int k=0;k<m->noutputs;k++)fprintf(f,"%s\"%s\"",k?",":"",m->names[m->outputs[k]]);fprintf(f,"],\n\"frames\":[\n");
 for(int step=0;step<=steps;step++){
  if(step%every==0){m->observe(s);n_snapshot(s,m,folder,step/every);double t=s->field[m->time][(size_t)s->halo*ny];
   fprintf(f,"%s{\"time\":%.17g",step?",\n":"",t);
   for(int k=0;k<m->nmonitors;k++)fprintf(f,",\"%s\":%.17g",m->monitors[k].name,n_reduce(s,m->monitors+k));fprintf(f,"}");fflush(f);
   if(step%(every*10)==0)fprintf(stderr,"native step %d/%d, t=%.9g\n",step,steps,t);
  }
  if(step<steps)m->advance(s);
 }
 fprintf(f,"\n]}\n");if(fclose(f))n_fail("report close failed");n_destroy(s);return 0;
}
#endif
