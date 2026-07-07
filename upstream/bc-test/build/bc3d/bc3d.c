#include "bc3d.h"
typedef struct {
double q[34][18][18];
} Formura_Buff;
typedef struct {
double q;
} Formura_Comm_Buff;
static Formura_Buff buff;
static Formura_Comm_Buff send_buf1_p1_0_0[2][16][16];
static Formura_Comm_Buff recv_buf1_m1_0_0[2][16][16];
static Formura_Comm_Buff send_buf1_0_p1_0[32][2][16];
static Formura_Comm_Buff recv_buf1_0_m1_0[32][2][16];
static Formura_Comm_Buff send_buf1_0_0_p1[32][16][2];
static Formura_Comm_Buff recv_buf1_0_0_m1[32][16][2];
static Formura_Comm_Buff send_buf1_p1_p1_0[2][2][16];
static Formura_Comm_Buff recv_buf1_m1_m1_0[2][2][16];
static Formura_Comm_Buff send_buf1_p1_0_p1[2][16][2];
static Formura_Comm_Buff recv_buf1_m1_0_m1[2][16][2];
static Formura_Comm_Buff send_buf1_0_p1_p1[32][2][2];
static Formura_Comm_Buff recv_buf1_0_m1_m1[32][2][2];
static Formura_Comm_Buff send_buf1_p1_p1_p1[2][2][2];
static Formura_Comm_Buff recv_buf1_m1_m1_m1[2][2][2];
Formura_Grid_Struct formura_data;
int Formura_Encode_rank(int p1,int p2,int p3) {
return ((p1+1)%1 + 1*((p2+1)%1) + 1*((p3+1)%1));
}
void Formura_Decode_rank(int p,int * p1,int * p2,int * p3) {
int p4 = (int)p%1;
*p1 = (int)p4%1;
*p2 = (int)p4/1;
*p3 = (int)p/1;
}
void Formura_Setup(Formura_Navi n,int block_offset_1,int block_offset_2,int block_offset_3) {
for(int i1 = 0; i1 < 32; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
double a0 = 1.0e-3;
double a1 = i1+n.offset_x+block_offset_1;
double a2 = 1.0;
double a3 = a1+a2;
double a4 = 32.0;
double a5 = a4-a1;
double a6 = a3*a5;
double a7 = 2.0;
double a8 = i2+n.offset_y+block_offset_2;
double a9 = a7*a8;
double a10 = 16.0;
double a11 = a10-a8;
double a12 = a9*a11;
double a13 = a6+a12;
double a14 = i3+n.offset_z+block_offset_3;
double a15 = 2.0;
double a16 = a14+a15;
double a17 = 5.0;
double a18 = a14+a17;
double a19 = a16*a18;
double a20 = a13+a19;
double a21 = a0*a20;
formura_data.q[i1][i2][i3] = a21;
}
}
}

}
void Formura_Step(Formura_Buff * buff,Formura_Grid_Struct * rslt,Formura_Navi n,int block_offset_1,int block_offset_2,int block_offset_3) {
for(int i1 = 0; i1 < 32; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
double a0 = buff->q[i1+1][i2+1][i3+1];
double a1 = 5.0e-2;
double a2 = buff->q[i1+2][i2+1][i3+1];
double a3 = buff->q[i1][i2+1][i3+1];
double a4 = a2+a3;
double a5 = buff->q[i1+1][i2+2][i3+1];
double a6 = a4+a5;
double a7 = buff->q[i1+1][i2][i3+1];
double a8 = a6+a7;
double a9 = buff->q[i1+1][i2+1][i3+2];
double a10 = a8+a9;
double a11 = buff->q[i1+1][i2+1][i3];
double a12 = a10+a11;
double a13 = 6.0;
double a14 = a13*a0;
double a15 = a12-a14;
double a16 = a1*a15;
double a17 = a0+a16;
rslt->q[i1][i2][i3] = a17;
}
}
}

}
double to_pos_x(int i,Formura_Navi n) {
return n.space_interval_x*((i+n.offset_x)%n.total_grid_x);
}
double to_pos_y(int i,Formura_Navi n) {
return n.space_interval_y*((i+n.offset_y)%n.total_grid_y);
}
double to_pos_z(int i,Formura_Navi n) {
return n.space_interval_z*((i+n.offset_z)%n.total_grid_z);
}
void Formura_Init(int * argc,char *** argv,Formura_Navi * n) {
MPI_Init(argc,argv);
MPI_Comm cm = MPI_COMM_WORLD;
int size;
int rank;
MPI_Comm_size(cm,&size);
MPI_Comm_rank(cm,&rank);
if(size != 1) {
fprintf(stderr,"Do not match the number of MPI process!");
exit(1);
}
int i1,i2,i3;
Formura_Decode_rank(rank,&i1,&i2,&i3);
n->time_step = 0;
n->lower_x = 0;
n->lower_y = 0;
n->lower_z = 0;
n->upper_x = 32;
n->upper_y = 16;
n->upper_z = 16;
n->space_interval_x = 3.125e-2;
n->space_interval_y = 3.125e-2;
n->space_interval_z = 3.125e-2;
n->my_rank = rank;
n->mpi_world = cm;
n->rank_p1_0_0 = Formura_Encode_rank(i1+1,i2,i3);
n->rank_0_p1_0 = Formura_Encode_rank(i1,i2+1,i3);
n->rank_0_0_p1 = Formura_Encode_rank(i1,i2,i3+1);
n->rank_p1_p1_0 = Formura_Encode_rank(i1+1,i2+1,i3);
n->rank_p1_0_p1 = Formura_Encode_rank(i1+1,i2,i3+1);
n->rank_0_p1_p1 = Formura_Encode_rank(i1,i2+1,i3+1);
n->rank_p1_p1_p1 = Formura_Encode_rank(i1+1,i2+1,i3+1);
n->rank_m1_0_0 = Formura_Encode_rank(i1-1,i2,i3);
n->rank_0_m1_0 = Formura_Encode_rank(i1,i2-1,i3);
n->rank_0_0_m1 = Formura_Encode_rank(i1,i2,i3-1);
n->rank_m1_m1_0 = Formura_Encode_rank(i1-1,i2-1,i3);
n->rank_m1_0_m1 = Formura_Encode_rank(i1-1,i2,i3-1);
n->rank_0_m1_m1 = Formura_Encode_rank(i1,i2-1,i3-1);
n->rank_m1_m1_m1 = Formura_Encode_rank(i1-1,i2-1,i3-1);
n->offset_x = 32*i1;
n->offset_y = 16*i2;
n->offset_z = 16*i3;
n->length_x = 1.0;
n->length_y = 0.5;
n->length_z = 0.5;
n->total_grid_x = 32;
n->total_grid_y = 16;
n->total_grid_z = 16;
Formura_Setup(*n,0,0,0);
}
void Formura_Custom_Init(Formura_Navi * n,MPI_Comm comm) {
MPI_Comm cm = comm;
int size;
int rank;
MPI_Comm_size(cm,&size);
MPI_Comm_rank(cm,&rank);
if(size != 1) {
fprintf(stderr,"Do not match the number of MPI process!");
exit(1);
}
int i1,i2,i3;
Formura_Decode_rank(rank,&i1,&i2,&i3);
n->time_step = 0;
n->lower_x = 0;
n->lower_y = 0;
n->lower_z = 0;
n->upper_x = 32;
n->upper_y = 16;
n->upper_z = 16;
n->space_interval_x = 3.125e-2;
n->space_interval_y = 3.125e-2;
n->space_interval_z = 3.125e-2;
n->my_rank = rank;
n->mpi_world = cm;
n->rank_p1_0_0 = Formura_Encode_rank(i1+1,i2,i3);
n->rank_0_p1_0 = Formura_Encode_rank(i1,i2+1,i3);
n->rank_0_0_p1 = Formura_Encode_rank(i1,i2,i3+1);
n->rank_p1_p1_0 = Formura_Encode_rank(i1+1,i2+1,i3);
n->rank_p1_0_p1 = Formura_Encode_rank(i1+1,i2,i3+1);
n->rank_0_p1_p1 = Formura_Encode_rank(i1,i2+1,i3+1);
n->rank_p1_p1_p1 = Formura_Encode_rank(i1+1,i2+1,i3+1);
n->rank_m1_0_0 = Formura_Encode_rank(i1-1,i2,i3);
n->rank_0_m1_0 = Formura_Encode_rank(i1,i2-1,i3);
n->rank_0_0_m1 = Formura_Encode_rank(i1,i2,i3-1);
n->rank_m1_m1_0 = Formura_Encode_rank(i1-1,i2-1,i3);
n->rank_m1_0_m1 = Formura_Encode_rank(i1-1,i2,i3-1);
n->rank_0_m1_m1 = Formura_Encode_rank(i1,i2-1,i3-1);
n->rank_m1_m1_m1 = Formura_Encode_rank(i1-1,i2-1,i3-1);
n->offset_x = 32*i1;
n->offset_y = 16*i2;
n->offset_z = 16*i3;
n->length_x = 1.0;
n->length_y = 0.5;
n->length_z = 0.5;
n->total_grid_x = 32;
n->total_grid_y = 16;
n->total_grid_z = 16;
Formura_Setup(*n,0,0,0);
}
void Formura_Forward(Formura_Navi * n) {
for(int i1 = 0; i1 < 32; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
buff.q[i1+1][i2+1][i3+1] = formura_data.q[i1][i2][i3];
}
}
}

for(int g = 0; g < 1; g += 1) {
for(int i1 = 0; i1 < 18; i1 += 1) {
for(int i2 = 0; i2 < 18; i2 += 1) {
buff.q[g][i1][i2] = buff.q[1-g][i1][i2];
}
}
}

for(int g = 33; g < 34; g += 1) {
for(int i1 = 0; i1 < 18; i1 += 1) {
for(int i2 = 0; i2 < 18; i2 += 1) {
buff.q[g][i1][i2] = buff.q[65-g][i1][i2];
}
}
}

for(int i0 = 0; i0 < 34; i0 += 1) {
for(int g = 0; g < 1; g += 1) {
for(int i2 = 0; i2 < 18; i2 += 1) {
buff.q[i0][g][i2] = buff.q[i0][g+16][i2];
}
}
}

for(int i0 = 0; i0 < 34; i0 += 1) {
for(int g = 17; g < 18; g += 1) {
for(int i2 = 0; i2 < 18; i2 += 1) {
buff.q[i0][g][i2] = buff.q[i0][g-16][i2];
}
}
}

for(int i0 = 0; i0 < 34; i0 += 1) {
for(int i1 = 0; i1 < 18; i1 += 1) {
for(int g = 0; g < 1; g += 1) {
buff.q[i0][i1][g] = 0.0;
}
}
}

for(int i0 = 0; i0 < 34; i0 += 1) {
for(int i1 = 0; i1 < 18; i1 += 1) {
for(int g = 17; g < 18; g += 1) {
buff.q[i0][i1][g] = 0.0;
}
}
}

Formura_Step(&buff,&formura_data,*n,0,0,0);
n->time_step += 1;
}
void Formura_Finalize() {
MPI_Finalize();
}
