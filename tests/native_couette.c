/* Independent component formulas and convergence tests for the generated model.
   Physical constants below belong to the analytic reference, not the simulator. */
#define FORMURAE_NATIVE_NO_MAIN
#include "model.c"
static double value(NState *s,int f,int i,int j){return n_at(s,s->field[f],i,j);}
static double first(NState *s,int f,int i,int j,int axis){
 return (value(s,f,i+(axis==0),j+(axis==1))-value(s,f,i-(axis==0),j-(axis==1)))/(2*s->spacing[axis]);
}
static double second(NState *s,int f,int i,int j,int axis){
 return (value(s,f,i+(axis==0),j+(axis==1))+value(s,f,i-(axis==0),j-(axis==1))-2*value(s,f,i,j))/pow(s->spacing[axis],2);
}
static const int cf[2][2]={{N_C_up1_up1,N_C_up1_up2},{N_C_up1_up2,N_C_up2_up2}};
static const int rf[2][2]={{N_rate_up1_up1,N_rate_up1_up2},{N_rate_up1_up2,N_rate_up2_up2}};
static const int tf[2][2]={{N_transport_up1_up1,N_transport_up1_up2},{N_transport_up1_up2,N_transport_up2_up2}};
static void operators(NState *s){
 model_observe(s);
 n_ghost(s,s->field[N_v_up1],s->field[N_vectorScale_up1],1);
 n_ghost(s,s->field[N_v_up2],s->field[N_vectorScale_up2],1);
 for(int a=0;a<2;a++)for(int b=a;b<2;b++){
  int scale=a==0?(b==0?N_tensorScale_up1_up1:N_tensorScale_up1_up2):N_tensorScale_up2_up2;
  n_ghost(s,s->field[cf[a][b]],s->field[scale],0);
 }
 n_ghost(s,s->field[N_wallOmega],s->field[N_unitScale],0);stage_operators(s);
}
static double check_grid(int n,int comma){
 NState *s=n_create(&n_model,n+1,4*n);model_prepare(s);operators(s);
 double transport=0,tensor=0,div=0;
 for(int i=s->halo+3;i<s->halo+s->nx-3;i++)for(int j=0;j<s->ny;j++){
  double R=1+(i-s->halo)*s->spacing[0],V[2]={value(s,N_v_up1,i,j),value(s,N_v_up2,i,j)};
  double G[2][2];for(int a=0;a<2;a++)for(int b=0;b<2;b++)G[a][b]=first(s,a?N_v_up2:N_v_up1,i,j,b);
  for(int a=0;a<2;a++)for(int b=a;b<2;b++){
   double adv=0,stretching=0,wind=0;
   for(int k=0;k<2;k++){
    adv-=V[k]*first(s,cf[a][b],i,j,k);
    wind+=fabs(V[k])*s->spacing[k]*second(s,cf[a][b],i,j,k)/2;
    stretching+=G[a][k]*value(s,cf[k][b],i,j)+value(s,cf[a][k],i,j)*G[b][k];
   }
   double metric=a==b?(a?1/(R*R):1):0,scale=pow(R,a+b);
   transport=fmax(transport,fabs(value(s,tf[a][b],i,j)-adv-wind)*scale);
   tensor=fmax(tensor,fabs(value(s,rf[a][b],i,j)-(adv+stretching-(value(s,cf[a][b],i,j)-metric)/1.5))*scale);
  }
  div=fmax(div,fabs(value(s,N_divergenceValue,i,j)));
 }
 assert(transport<1e-9 && tensor<1e-9 && div<1e-11);
 /* Exact steady unperturbed circular Couette flow. The radial force is
    balanced by pressure; tangential acceleration and its curl vanish. */
 for(int i=0;i<s->total;i++)for(int j=0;j<s->ny;j++){
  size_t p=(size_t)i*s->ny+j;double R=1+(i-s->halo)*s->spacing[0],xy=-4/(R*R);
  s->field[N_C_up1_up1][p]=1;s->field[N_C_up1_up2][p]=xy/R;s->field[N_C_up2_up2][p]=(1+2*xy*xy)/(R*R);
  s->field[N_omega][p]=0;
 }
 operators(s);double steady=0;
 for(int i=s->halo+n/4;i<=s->halo+3*n/4;i++)for(int j=0;j<s->ny;j++){
  double R=1+(i-s->halo)*s->spacing[0];
  steady=fmax(steady,fabs(value(s,N_acceleration_up2,i,j))*R);
  steady=fmax(steady,fabs(value(s,N_rotationRate,i,j)));
  for(int a=0;a<2;a++)for(int b=a;b<2;b++)steady=fmax(steady,fabs(value(s,rf[a][b],i,j))*pow(R,a+b));
 }
 printf("%s{\"radial\":%d,\"steady_error\":%.17g,\"divergence\":%.17g,\"transport_reference_error\":%.17g,\"tensor_reference_error\":%.17g}",comma?",":"",n,steady,div,transport,tensor);
 n_destroy(s);return steady;
}
int main(void){
 printf("{\"backend\":\"formurae-native-c\",\"runs\":[");
 double errors[3];for(int k=0;k<3;k++)errors[k]=check_grid(16<<k,k);
 double o1=log2(errors[0]/errors[1]),o2=log2(errors[1]/errors[2]);assert(o1>1.7&&o2>1.7);
 NState *solutions[3];
 for(int k=0;k<3;k++){
  NState *s=solutions[k]=n_create(&n_model,25,64);double dt=.001/(1<<k);n_uniform(s,N_timestep,dt);model_prepare(s);
  for(int step=0;step<200*(1<<k);step++)model_advance(s);
  model_observe(s);assert(n_reduce(s,&n_monitors[0])>0);
 }
 int fields[]={N_C_up1_up1,N_C_up1_up2,N_C_up2_up2,N_omega,N_meanVelocity};double differences[2]={0,0};
 for(int k=0;k<2;k++)for(int f=0;f<5;f++){
  NState *s=solutions[k];for(int i=s->halo;i<s->halo+s->nx;i++)for(int j=0;j<s->ny;j++){
   double scale=f<3?pow(1+(i-s->halo)*s->spacing[0],f):1;
   differences[k]=fmax(differences[k],scale*fabs(value(s,fields[f],i,j)-value(solutions[k+1],fields[f],i,j)));
  }
 }
 double order=log2(differences[0]/differences[1]);assert(order>.7&&order<1.4);
 printf("],\"orders\":[%.17g,%.17g],\"time_difference_errors\":[%.17g,%.17g],\"time_order\":%.17g}\n",o1,o2,differences[0],differences[1],order);
 for(int k=0;k<3;k++)n_destroy(solutions[k]);return 0;
}
