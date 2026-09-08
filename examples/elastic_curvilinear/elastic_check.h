/* Shared, independent verification of the generated cylindrical/spherical
 * solvers. All nine physical components participate in the reference and
 * energy checks. The torsional eigenfunction is a continuum Bessel mode. */
#define _DEFAULT_SOURCE
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef DT_FACTOR
#define DT_FACTOR 0.05
#endif
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
extern double j0(double), j1(double), y0(double), y1(double);
static int dims[3], count;
static double h[3], dt, wave_number, amplitude;
static double *fields[9];
static const int pair_i[6] = {0,1,2,0,0,1};
static const int pair_j[6] = {0,1,2,1,2,2};
static int stress_id(int i, int j) {
  if (i == j) return 3+i;
  if (i > j) { int t=i; i=j; j=t; }
  return (i == 0) ? 6+j-1 : 8;
}
static int offset(int i,int j,int k) { return (i*dims[1]+j)*dims[2]+k; }
static void indices(int p,int q[3]) {
  q[2]=p%dims[2]; p/=dims[2]; q[1]=p%dims[1]; q[0]=p/dims[1];
}
static int bounded(int a) { return a == 0 || a == (SPHERICAL ? 1 : 2); }
static int wall(int a,int q) { return q == 0 || q == dims[a]-1; }
static int velocity_allowed(int c,const int q[3]) {
  return !wall(0,q[0]) && !(bounded(c) && c != 0 && wall(c,q[c]));
}
static int stress_allowed(int i,int j,const int q[3]) {
  int b=SPHERICAL ? 1 : 2;
  return i == j || !wall(b,q[b]) || (i != b && j != b);
}
static void geometry(const int q[3], double g[3], double dg[3][3], double *vol) {
  double R=1+q[0]*h[0], T=1+q[1]*h[1];
  memset(dg,0,9*sizeof(double));
  g[0]=1; g[1]=R*R; g[2]=1; dg[0][1]=2*R; *vol=R;
  if (SPHERICAL) {
    double sn=sin(T), cs=cos(T);
    g[2]=R*R*sn*sn; dg[0][2]=2*R*sn*sn;
    dg[1][2]=2*R*R*sn*cs; *vol=R*R*sn;
  }
}
static double sample(const double *state,int c,const int q[3],int weighted,int i) {
  double value=state[c*count+offset(q[0],q[1],q[2])];
  if (weighted) { double g[3],dg[3][3],V; geometry(q,g,dg,&V); value*=V*g[i]; }
  return value;
}
static double derivative(const double *state,int c,const int q[3],int a,int weighted,int i) {
  int lo[3]={q[0],q[1],q[2]}, hi[3]={q[0],q[1],q[2]};
  double divisor=2*h[a];
  if (bounded(a) && q[a] == 0) { hi[a]++; divisor=h[a]; }
  else if (bounded(a) && q[a] == dims[a]-1) { lo[a]--; divisor=h[a]; }
  else { lo[a]=(q[a]+dims[a]-1)%dims[a]; hi[a]=(q[a]+1)%dims[a]; }
  return (sample(state,c,hi,weighted,i)-sample(state,c,lo,weighted,i))/divisor;
}
static void acceleration(const double *state,double *out) {
  for (int p=0;p<count;p++) {
    int q[3]; double g[3],dg[3][3],V; indices(p,q); geometry(q,g,dg,&V);
    for (int i=0;i<3;i++) {
      double a=0;
      for (int j=0;j<3;j++)
        a+=derivative(state,stress_id(i,j),q,j,1,i)/V-dg[i][j]*state[(3+j)*count+p]/2;
      out[i*count+p]=velocity_allowed(i,q) ? a/g[i] : 0;
    }
  }
}
static void stress_rate(const double *state,double *out) {
  for (int p=0;p<count;p++) {
    int q[3]; double g[3],dg[3][3],V,E[3][3],trace=0;
    indices(p,q); geometry(q,g,dg,&V);
    for (int i=0;i<3;i++) for (int j=0;j<3;j++) {
      E[i][j]=(g[i]*derivative(state,i,q,j,0,0)+g[j]*derivative(state,j,q,i,0,0))/2;
      if (i == j) for (int k=0;k<3;k++) E[i][j]+=dg[k][i]*state[k*count+p]/2;
    }
    for (int i=0;i<3;i++) trace+=E[i][i]/g[i];
    for (int c=0;c<6;c++) {
      int i=pair_i[c],j=pair_j[c];
      out[c*count+p]=2*E[i][j]/(g[i]*g[j])+(i==j ? 2*trace/g[i] : 0);
    }
  }
}
static void capture(double *state) {
  for (int c=0;c<9;c++) memcpy(state+c*count,fields[c],count*sizeof(double));
}
static void reference_step(double *state,double *a,double *rate) {
  acceleration(state,a);
  for (int c=0;c<3;c++) for (int p=0;p<count;p++) state[c*count+p]+=dt*a[c*count+p]/2;
  stress_rate(state,rate);
  for (int c=0;c<6;c++) for (int p=0;p<count;p++) {
    int q[3]; indices(p,q);
    state[(3+c)*count+p]=stress_allowed(pair_i[c],pair_j[c],q)
      ? state[(3+c)*count+p]+dt*rate[c*count+p] : 0;
  }
  acceleration(state,a);
  for (int c=0;c<3;c++) for (int p=0;p<count;p++) state[c*count+p]+=dt*a[c*count+p]/2;
}
static double energy(const double *state) {
  double E=0;
  for (int p=0;p<count;p++) {
    int q[3]; double g[3],dg[3][3],V,kin=0,ss=0,tr=0; indices(p,q); geometry(q,g,dg,&V);
    for (int a=0;a<3;a++) {
      if (bounded(a) && wall(a,q[a])) V*=0.5;
      kin+=g[a]*state[a*count+p]*state[a*count+p]; tr+=g[a]*state[(3+a)*count+p];
    }
    for (int c=0;c<6;c++) {
      double value=state[(3+c)*count+p];
      ss+=(c<3 ? 1 : 2)*g[pair_i[c]]*g[pair_j[c]]*value*value;
    }
    E+=V*(kin/2+ss/4-tr*tr/16);
  }
  return E*h[0]*h[1]*h[2];
}
static double modified_energy(const double *state,double *a) {
  acceleration(state,a); double correction=0;
  for (int p=0;p<count;p++) {
    int q[3]; double g[3],dg[3][3],V; indices(p,q); geometry(q,g,dg,&V);
    for (int j=0;j<3;j++) if (bounded(j) && wall(j,q[j])) V*=0.5;
    for (int c=0;c<3;c++) correction+=V*g[c]*a[c*count+p]*a[c*count+p];
  }
  return energy(state)-dt*dt*correction*h[0]*h[1]*h[2]/8;
}
static double B0(double x,int second) { return SPHERICAL ? (second ? -cos(x)/x : sin(x)/x) : (second ? y0(x) : j0(x)); }
static double B1(double x,int second) { return SPHERICAL ? (second ? -cos(x)/(x*x)-sin(x)/x : sin(x)/(x*x)-cos(x)/x) : (second ? y1(x) : j1(x)); }
static double mode_at(double k,double R) { return B1(k*R,0)*B1(k,1)-B1(k*R,1)*B1(k,0); }
static double mode_derivative(double R) {
  return (wave_number*(B0(wave_number*R,0)*B1(wave_number,1)-B0(wave_number*R,1)*B1(wave_number,0))
    -(SPHERICAL ? 2 : 1)*mode_at(wave_number,R)/R)/amplitude;
}
static void find_mode(void) {
  double outer=1+(dims[0]-1)*h[0], lo=0.1,hi=lo+0.01;
  while (mode_at(lo,outer)*mode_at(hi,outer)>0 && hi<100) { lo=hi; hi+=0.01; }
  if (hi>=100) { fprintf(stderr,"Bessel root not bracketed\n"); exit(2); }
  for (int t=0;t<60;t++) { double mid=(lo+hi)/2; if (mode_at(lo,outer)*mode_at(mid,outer)<=0) hi=mid; else lo=mid; }
  wave_number=(lo+hi)/2; amplitude=mode_at(wave_number,(1+outer)/2);
}
static void exact_state(double *state,double t) {
  memset(state,0,9*count*sizeof(double)); int c=SPHERICAL ? 2 : 1;
  for (int p=0;p<count;p++) {
    int q[3]; indices(p,q); double R=1+q[0]*h[0], f=mode_at(wave_number,R)/amplitude;
    state[c*count+p]=f*cos(wave_number*t)/R;
    state[stress_id(0,c)*count+p]=(mode_derivative(R)-f/R)*sin(wave_number*t)/(wave_number*R);
  }
}
/* A Cartesian affine velocity and uniform stress are an exact continuum
 * solution: v(X,t)=A X+b, sigma(X,t)=S+t[2 tr(A)I+A+A^T]. Transforming
 * these tensors excites every coordinate component and angular derivative.
 * Only the interior, four cells from a bounded wall, is used in this
 * local truncation test; the eigenmode tests include all boundary points. */
static void affine_state(double *state,double t) {
  const double A[3][3]={{0.2,0.3,-0.4},{-0.1,0.5,0.2},{0.3,-0.2,-0.1}};
  const double S[3][3]={{0.4,0.2,-0.3},{0.2,-0.2,0.1},{-0.3,0.1,0.7}};
  for(int p=0;p<count;p++) {
    int q[3]; indices(p,q);
    double R=1+q[0]*h[0],T=(SPHERICAL?1:0)+q[1]*h[1],P=q[2]*h[2];
    double basis[3][3]={{cos(T),sin(T),0},{-sin(T),cos(T),0},{0,0,1}};
    double X[3]={R*cos(T),R*sin(T),P};
    double g[3],dg[3][3],V,vc[3]={0.1,-0.2,0.3}; geometry(q,g,dg,&V);
    if(SPHERICAL) {
      double b[3][3]={{sin(T)*cos(P),sin(T)*sin(P),cos(T)},
        {cos(T)*cos(P),cos(T)*sin(P),-sin(T)},{-sin(P),cos(P),0}};
      memcpy(basis,b,sizeof(b)); for(int i=0;i<3;i++) X[i]=R*basis[0][i];
    }
    for(int i=0;i<3;i++) for(int j=0;j<3;j++) vc[i]+=A[i][j]*X[j];
    for(int i=0;i<3;i++) {state[i*count+p]=0; for(int j=0;j<3;j++) state[i*count+p]+=basis[i][j]*vc[j]/sqrt(g[i]);}
    for(int c=0;c<6;c++) {
      int i=pair_i[c],j=pair_j[c]; double value=0;
      for(int k=0;k<3;k++) for(int l=0;l<3;l++)
        value+=basis[i][k]*basis[j][l]*(S[k][l]+t*(A[k][l]+A[l][k]+(k==l ? 1.2 : 0)));
      state[(3+c)*count+p]=value/sqrt(g[i]*g[j]);
    }
  }
}
static double affine_rate_error(const double *state,const double *exact) {
  double error=0;
  for(int p=0;p<count;p++) {
    int q[3]; indices(p,q); int interior=1;
    for(int i=0;i<3;i++) if(bounded(i) && (q[i]<4 || q[i]>=dims[i]-4)) interior=0;
    if(!interior) continue;
    double g[3],dg[3][3],V; geometry(q,g,dg,&V);
    for(int c=0;c<9;c++) {
      double scale=c<3?sqrt(g[c]):sqrt(g[pair_i[c-3]]*g[pair_j[c-3]]);
      double e=fabs(state[c*count+p]-exact[c*count+p])*scale/dt;
      if(e>error) error=e;
    }
  }
  return error;
}
int main(int argc,char **argv) {
  const char *mode=argc>1 ? argv[1] : "accuracy";
  Formura_Navi n; Formura_Init(&argc,&argv,&n);
  dims[0]=n.total_grid_r; h[0]=n.space_interval_r;
  dims[1]=n.total_grid_theta; h[1]=n.space_interval_theta;
#if SPHERICAL
  dims[2]=n.total_grid_phi; h[2]=n.space_interval_phi;
#else
  dims[2]=n.total_grid_z; h[2]=n.space_interval_z;
#endif
  count=dims[0]*dims[1]*dims[2]; dt=DT_FACTOR*h[0];
  double *ptrs[9]={&formura_data.v_up1[0][0][0],&formura_data.v_up2[0][0][0],&formura_data.v_up3[0][0][0],
    &formura_data.sigma_up1_up1[0][0][0],&formura_data.sigma_up2_up2[0][0][0],&formura_data.sigma_up3_up3[0][0][0],
    &formura_data.sigma_up1_up2[0][0][0],&formura_data.sigma_up1_up3[0][0][0],&formura_data.sigma_up2_up3[0][0][0]};
  memcpy(fields,ptrs,sizeof(fields));
  double *state=calloc(9*count,sizeof(double)), *reference=calloc(9*count,sizeof(double));
  double *a=calloc(3*count,sizeof(double)), *rate=calloc(6*count,sizeof(double));
  if (!state || !reference || !a || !rate) return 2;
  find_mode();
  int covariance=strcmp(mode,"covariance")==0;
  int accuracy=strcmp(mode,"accuracy")==0;
  if(covariance) affine_state(state,0);
  else if (accuracy) exact_state(state,0);
  else for (int p=0;p<count;p++) {
    int q[3]; indices(p,q);
    double x=(double)q[0]/(dims[0]-1), y=(double)q[1]/(dims[1]-1), z=(double)q[2]/(dims[2]-1);
    for (int c=0;c<9;c++) {
      double value=sin((c+1)*0.7+2*M_PI*x)*cos(2*M_PI*y+0.3*c)*sin(2*M_PI*z+0.2*c);
      if (c<3) value*=velocity_allowed(c,q);
      else value*=stress_allowed(pair_i[c-3],pair_j[c-3],q);
      state[c*count+p]=value;
    }
  }
  /* Pin continuum roundoff at clamped walls to exact zero. */
  for (int p=0;p<count;p++) { int q[3]; indices(p,q); for(int c=0;c<3;c++) if(!velocity_allowed(c,q)) state[c*count+p]=0; }
  for (int c=0;c<9;c++) memcpy(fields[c],state+c*count,count*sizeof(double));
  memcpy(reference,state,9*count*sizeof(double)); reference_step(reference,a,rate);
  double e0=energy(state),m0=modified_energy(state,a),emin=e0,emax=e0,mdrift=0,referr=0;
  int steps=covariance ? 1 : (accuracy ? (int)ceil(2*M_PI/(wave_number*dt)) : 10000);
  if (argc>2) steps=atoi(argv[2]);
  for (int t=1;t<=steps;t++) {
    Formura_Forward(&n);
    if(n.time_step!=t) { fprintf(stderr,"validation requires temporal_blocking_interval=1\n"); return 2; }
    if (t==1 || t%50==0 || t==steps) {
      capture(state); double e=energy(state),m=modified_energy(state,a);
      if (!isfinite(e) || !isfinite(m)) return 1;
      if(e<emin) emin=e; if(e>emax) emax=e;
      double drift=fabs(m-m0)/fabs(m0); if(drift>mdrift) mdrift=drift;
      if(t==1) { int worst=0; for(int j=0;j<9*count;j++) { double d=fabs(state[j]-reference[j]); if(d>referr) {referr=d;worst=j;} } if(referr>1e-11) {int q[3]; indices(worst%count,q); fprintf(stderr,"reference mismatch c=%d q=%d,%d,%d generated=%.17g reference=%.17g\n",worst/count,q[0],q[1],q[2],state[worst],reference[worst]);} }
    }
  }
  double error=0;
  if(accuracy) { exact_state(reference,n.time_step*dt); for(int j=0;j<9*count;j++) reference[j]=state[j]-reference[j]; error=sqrt(energy(reference)/e0); }
  double rate_error=0;
  if(covariance) { affine_state(reference,n.time_step*dt); rate_error=affine_rate_error(state,reference); }
  int ok=referr<1e-11 && (covariance || (mdrift<1e-9 && emax/e0<1.03 && emin/e0>0.97 && (!accuracy || error<0.2)));
  printf("{\"coordinate\":\"%s\",\"mode\":\"%s\",\"nr\":%d,\"n1\":%d,\"n2\":%d,\"steps\":%d,\"dt\":%.17g,\"time\":%.17g,\"wave_number\":%.17g,\"relative_error\":%.12g,\"interior_rate_error\":%.12g,\"reference_error\":%.12g,\"modified_energy_drift\":%.12g,\"energy_min_ratio\":%.12g,\"energy_max_ratio\":%.12g,\"ok\":%s}\n",
    SPHERICAL ? "spherical" : "cylindrical",mode,dims[0],dims[1],dims[2],n.time_step,dt,n.time_step*dt,wave_number,error,rate_error,referr,mdrift,emin/e0,emax/e0,ok ? "true" : "false");
  if(argc>3) { FILE *f=fopen(argv[3],"wb"); if(!f) return 2; fwrite(state,sizeof(double),9*count,f); fclose(f); }
  free(state); free(reference); free(a); free(rate); Formura_Finalize(); return ok ? 0 : 1;
}
