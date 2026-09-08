/* Run generated divergence and curl on one supplied velocity snapshot.
 * Binary files use component-major IEEE binary64, in host byte order.
 * The Python collector independently checks every output component. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc,char **argv) {
  if(argc!=3) return 2;
  Formura_Navi n;Formura_Init(&argc,&argv,&n);
#if SPHERICAL
  size_t count=(size_t)n.total_grid_r*n.total_grid_theta*n.total_grid_phi;
#else
  size_t count=(size_t)n.total_grid_r*n.total_grid_theta*n.total_grid_z;
#endif
  double *v[]={&formura_data.v_up1[0][0][0],&formura_data.v_up2[0][0][0],&formura_data.v_up3[0][0][0]};
  FILE *in=fopen(argv[1],"rb");if(!in) return 2;
  for(int c=0;c<3;c++) {
    if(fread(v[c],sizeof(double),count,in)!=count) return 2;
    for(size_t p=0;p<count;p++) if(!isfinite(v[c][p])) return 2;
  }
  if(fgetc(in)!=EOF || fclose(in)) return 2;
  Formura_Forward(&n);if(n.time_step!=1) return 2;
  double *out[]={&formura_data.compression[0][0][0],
    &formura_data.rotation_up1[0][0][0],&formura_data.rotation_up2[0][0][0],&formura_data.rotation_up3[0][0][0]};
  FILE *f=fopen(argv[2],"wb");if(!f) return 2;
  for(int c=0;c<4;c++) {
    for(size_t p=0;p<count;p++) if(!isfinite(out[c][p])) return 1;
    if(fwrite(out[c],sizeof(double),count,f)!=count) return 2;
  }
  if(fclose(f)) return 2;
  Formura_Finalize();return 0;
}
