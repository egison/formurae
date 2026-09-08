/* Three-dimensional velocity output for generated P/S diagnostics.
 * Same initial pulse and unchanged wave kernel as propagation_check.h.
 * Reuse the independent metric, reference-step and energy calculations
 * from the numerical validation driver, with a separate experiment main. */
#define main elastic_validation_main
#include "elastic_check.h"
#undef main

static const double pulse_radius=0.35;

static void cartesian_geometry(const int q[3], double X[3], double basis[3][3], double scale[3]) {
  double R=1+q[0]*h[0],T=(SPHERICAL ? 1 : 0)+q[1]*h[1],P=q[2]*h[2];
  double cyl[3][3]={{cos(T),sin(T),0},{-sin(T),cos(T),0},{0,0,1}};
  memcpy(basis,cyl,sizeof(cyl));
  X[0]=R*cos(T);X[1]=R*sin(T);X[2]=P;
  scale[0]=1;scale[1]=R;scale[2]=1;
  if(SPHERICAL) {
    double sph[3][3]={{sin(T)*cos(P),sin(T)*sin(P),cos(T)},
      {cos(T)*cos(P),cos(T)*sin(P),-sin(T)},{-sin(P),cos(P),0}};
    memcpy(basis,sph,sizeof(sph));
    for(int c=0;c<3;c++) X[c]=R*basis[0][c];
    scale[2]=R*sin(T);
  }
}

static double physical_speed(const double *state,int p,const double scale[3]) {
  double squared=0;
  for(int c=0;c<3;c++) {double v=scale[c]*state[c*count+p];squared+=v*v;}
  return sqrt(squared);
}

/* All velocity components, component-major binary64 in native byte order.
 * Transient files are consumed by the generated diagnostic executable. */
static void write_volume(const char *directory,const double *state,int step) {
  char path[4096];
  int n=snprintf(path,sizeof(path),"%s/velocity-%04d.bin",directory,step);
  if(n<0 || (size_t)n>=sizeof(path)) exit(2);
  FILE *out=fopen(path,"wb");if(!out) {perror(path);exit(2);}
  if(fwrite(state,sizeof(double),3*count,out)!=(size_t)(3*count) || fclose(out)) exit(2);
}

int main(int argc,char **argv) {
  if(argc!=2) {fprintf(stderr,"usage: check OUTPUT_DIRECTORY\n");return 2;}
  const char *directory=argv[1];
  Formura_Navi n;Formura_Init(&argc,&argv,&n);
  dims[0]=n.total_grid_r;h[0]=n.space_interval_r;
  dims[1]=n.total_grid_theta;h[1]=n.space_interval_theta;
#if SPHERICAL
  dims[2]=n.total_grid_phi;h[2]=n.space_interval_phi;
#else
  dims[2]=n.total_grid_z;h[2]=n.space_interval_z;
#endif
  count=dims[0]*dims[1]*dims[2];dt=DT_FACTOR*h[0];
  double *ptrs[9]={&formura_data.v_up1[0][0][0],&formura_data.v_up2[0][0][0],&formura_data.v_up3[0][0][0],
    &formura_data.sigma_up1_up1[0][0][0],&formura_data.sigma_up2_up2[0][0][0],&formura_data.sigma_up3_up3[0][0][0],
    &formura_data.sigma_up1_up2[0][0][0],&formura_data.sigma_up1_up3[0][0][0],&formura_data.sigma_up2_up3[0][0][0]};
  memcpy(fields,ptrs,sizeof(fields));
  double *state=calloc(9*count,sizeof(double)),*reference=calloc(9*count,sizeof(double));
  double *a=calloc(3*count,sizeof(double)),*rate=calloc(6*count,sizeof(double));
  if(!state || !reference || !a || !rate) return 2;
  double center_z=SPHERICAL ? 0 : 0.5,initial_peak=0;
  for(int p=0;p<count;p++) {
    int q[3];double X[3],basis[3][3],scale[3];indices(p,q);cartesian_geometry(q,X,basis,scale);
    double d2=(X[0]-1.5)*(X[0]-1.5)+X[1]*X[1]+(X[2]-center_z)*(X[2]-center_z);
    double f=d2<pulse_radius*pulse_radius ? exp(-2*d2/(pulse_radius*pulse_radius-d2)) : 0;
    for(int c=0;c<3;c++) state[c*count+p]=velocity_allowed(c,q) ? f*basis[c][0]/scale[c] : 0;
    double speed=physical_speed(state,p,scale);if(speed>initial_peak) initial_peak=speed;
  }
  for(int c=0;c<9;c++) memcpy(fields[c],state+c*count,count*sizeof(double));
  if(fabs(initial_peak-1)>1e-12) return 2;
  double e0=energy(state),m0=modified_energy(state,a),emax=e0,emin=e0,mdrift=0,referr=0,wallerr=0;
  int frames[4]={0,(int)llround(0.2/dt),(int)llround(0.4/dt),(int)llround(0.6/dt)};
  write_volume(directory,state,0);
  char path[4096];snprintf(path,sizeof(path),"%s/energy.dat",directory);
  FILE *trace=fopen(path,"w");if(!trace) return 2;
  fprintf(trace,"step time energy_relative modified_relative\n0 0 0 0\n");
  for(int step=1;step<=frames[3];step++) {
    int check=step==1 || step==frames[1] || step==frames[2] || step==frames[3];
    if(check) {capture(reference);reference_step(reference,a,rate);}
    Formura_Forward(&n);if(n.time_step!=step) return 2;
    if(check || step%16==0 || step%24==0) {
      capture(state);
      for(int c=0;c<9;c++) for(int p=0;p<count;p++) {
        double value=state[c*count+p];if(!isfinite(value)) return 1;
        if(check) {double diff=fabs(value-reference[c*count+p]);if(diff>referr) referr=diff;}
        if(c<3) {int q[3];indices(p,q);if(!velocity_allowed(c,q) && fabs(value)>wallerr) wallerr=fabs(value);}
      }
      double e=energy(state),m=modified_energy(state,a);
      if(e>emax) emax=e;if(e<emin) emin=e;
      double drift=fabs(m-m0)/m0;if(drift>mdrift) mdrift=drift;
      fprintf(trace,"%d %.17g %.17g %.17g\n",step,step*dt,(e-e0)/e0,(m-m0)/m0);
      if(step%24==0) {
        write_volume(directory,state,step);
        fprintf(stderr,"%s frame at t=%.6g written\n",SPHERICAL ? "spherical" : "cylindrical",step*dt);
      }
    }
  }
  if(fclose(trace)) return 2;
  int ok=referr<1e-11 && mdrift<1e-10 && wallerr==0 && emin/e0>0.97 && emax/e0<1.03;
  printf("{\"coordinate\":\"%s\",\"grid\":[%d,%d,%d],\"dt\":%.17g,\"steps\":%d,\"time\":%.17g,\"initial_peak_speed\":%.17g,\"pulse_radius\":%.17g,\"reference_max_absolute_error\":%.17g,\"modified_energy_relative_drift\":%.17g,\"energy_min_ratio\":%.17g,\"energy_max_ratio\":%.17g,\"wall_velocity_error\":%.17g,\"ok\":%s}\n",
    SPHERICAL ? "spherical" : "cylindrical",dims[0],dims[1],dims[2],dt,n.time_step,n.time_step*dt,initial_peak,pulse_radius,referr,mdrift,emin/e0,emax/e0,wallerr,ok ? "true" : "false");
  free(state);free(reference);free(a);free(rate);Formura_Finalize();return ok ? 0 : 1;
}
