#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include HDR

/* Recover per-cell effective step count n_eff for reproG without trusting
 * to_pos: brute-force the (periodic) translation between array indices and
 * logical cells, then map n_eff under the best translation. */

#define NX 128
#define NY 16
#define NZ 16
static double q0f(int i,int j,int k){return 0.001*(i*(NX-i)+2.0*j*(NY-j)+3.0*k*(NZ-k));}
static double r0f(int i,int j,int k){return 0.002*(i*(NX-i)+1.0*j*(NY-j)+1.0*k*(NZ-k));}
static double dyrf(int i,int j,int k){return r0f(i,(j+1)%NY,k)-r0f(i,(j-1+NY)%NY,k);}

static double neff_at(double qv,int ci,int cj,int ck,double c){
  double d = dyrf(ci,cj,ck);
  return (qv - q0f(ci,cj,ck)) / (c*d);
}

int main(int argc, char **argv) {
  int steps = argc > 1 ? atoi(argv[1]) : 8;
  int force = (argc > 4);
  double c = 0.05;
  Formura_Navi n;
  Formura_Init(&argc, &argv, &n);
  while (n.time_step < steps) Formura_Forward(&n);

  /* r is time-invariant: find its shift by exact equality */
  int rs_x=0, rs_y=0, rs_z=0, rbest=-1;
  for (int sx = 0; sx < NX; sx++)
    for (int sy = 0; sy < NY; sy++)
      for (int sz = 0; sz < NZ; sz++) {
        int hit = 0;
        for (int t = 0; t < 96; t++) {
          int ix = (t*37)%NX, iy = (t*11)%NY, iz = (t*7)%NZ;
          if (formura_data.r[ix][iy][iz] == r0f((ix+sx)%NX,(iy+sy)%NY,(iz+sz)%NZ)) hit++;
        }
        if (hit > rbest) { rbest = hit; rs_x=sx; rs_y=sy; rs_z=sz; }
      }
  /* q: score a shift by the size of the most common integer n_eff */
  int bs_x=0, bs_y=0, bs_z=0, best=-1;
  for (int sx = 0; sx < NX; sx++)
    for (int sy = 0; sy < NY; sy++)
      for (int sz = 0; sz < NZ; sz++) {
        int cnt[520]; for (int i=0;i<520;i++) cnt[i]=0;
        for (int t = 0; t < 96; t++) {
          int ix = (t*37)%NX, iy = (t*11)%NY, iz = (t*7)%NZ;
          int ci=(ix+sx)%NX, cj=(iy+sy)%NY, ck=(iz+sz)%NZ;
          if (fabs(dyrf(ci,cj,ck)) < 1e-9) continue;
          double ne = neff_at(formura_data.q[ix][iy][iz],ci,cj,ck,c);
          long r1 = llround(ne);
          if (fabs(ne - r1) < 1e-6 && r1>=0 && r1<520) cnt[r1]++;
        }
        int mode = 0; for (int i=0;i<520;i++) if (cnt[i]>mode) mode=cnt[i];
        if (mode > best) { best = mode; bs_x=sx; bs_y=sy; bs_z=sz; }
      }
  if (force) { bs_x=atoi(argv[2]); bs_y=atoi(argv[3]); bs_z=atoi(argv[4]); }
  printf("shift r: (%d,%d,%d) exact %d/96 | shift q: (%d,%d,%d)%s mode %d | navi (%d,%d,%d)\n",
         rs_x,rs_y,rs_z,rbest, bs_x,bs_y,bs_z, force?" (forced)":"", best, n.offset_x, n.offset_y, n.offset_z);

  int hist[64]={0}; int weird=0;
  static int m[NX][NY][NZ];
  for (int ix = 0; ix < NX; ix++)
    for (int iy = 0; iy < NY; iy++)
      for (int iz = 0; iz < NZ; iz++) {
        int ci=(ix+bs_x)%NX, cj=(iy+bs_y)%NY, ck=(iz+bs_z)%NZ;
        if (fabs(dyrf(ci,cj,ck)) < 1e-9) { m[ci][cj][ck]=-2; continue; }
        double ne = neff_at(formura_data.q[ix][iy][iz],ci,cj,ck,c);
        int nei=(int)llround(ne);
        if (fabs(ne-nei)<1e-6 && nei>=0 && nei<64) { hist[nei]++; m[ci][cj][ck]=nei; }
        else { weird++; m[ci][cj][ck]=-1; }
      }
  printf("n_eff histogram (expect all %d):\n", steps);
  for (int i=0;i<64;i++) if (hist[i]) printf("  n_eff=%2d : %6d cells\n", i, hist[i]);
  printf("  non-integer: %d (excl. dyr=0 rows)\n", weird);
  printf("\nmap k=5 (j rows 0..15, i cols 0..127; .=ok):\n");
  for (int j=0;j<NY;j++){
    for (int i=0;i<NX;i++){
      int v=m[i][j][5];
      putchar(v==steps?'.':(v==-2?',':(v<0?'?':(v<10?'0'+v:'a'+v-10))));
    }
    putchar('\n');
  }
  Formura_Finalize();
  return 0;
}
