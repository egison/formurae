#include "mxB.h"
typedef struct {
double Bx[10][10][10];
double By[10][10][10];
double Bz[10][10][10];
double Ex[10][10][10];
double Ey[10][10][10];
double Ez[10][10][10];
} Formura_Buff;
typedef struct {
double Bx[8][8][8];
double By[8][8][8];
double Bz[8][8][8];
double Ex[8][8][8];
double Ey[8][8][8];
double Ez[8][8][8];
} Formura_Rslt;
typedef struct {
double Bx[136][24][24];
double By[136][24][24];
double Bz[136][24][24];
double Ex[136][24][24];
double Ey[136][24][24];
double Ez[136][24][24];
} Formura_Tmp_Floor;
typedef struct {
double Bx[3][3][4][2][10][10];
double By[3][3][4][2][10][10];
double Bz[3][3][4][2][10][10];
double Ex[3][3][4][2][10][10];
double Ey[3][3][4][2][10][10];
double Ez[3][3][4][2][10][10];
} Formura_Tmp_Wall_1;
typedef struct {
double Bx[17][3][4][10][2][10];
double By[17][3][4][10][2][10];
double Bz[17][3][4][10][2][10];
double Ex[17][3][4][10][2][10];
double Ey[17][3][4][10][2][10];
double Ez[17][3][4][10][2][10];
} Formura_Tmp_Wall_2;
typedef struct {
double Bx[17][3][4][10][10][2];
double By[17][3][4][10][10][2];
double Bz[17][3][4][10][10][2];
double Ex[17][3][4][10][10][2];
double Ey[17][3][4][10][10][2];
double Ez[17][3][4][10][10][2];
} Formura_Tmp_Wall_3;
typedef struct {
double Bx;
double By;
double Bz;
double Ex;
double Ey;
double Ez;
} Formura_Comm_Buff;
static Formura_Buff buff;
static Formura_Rslt rslt;
static Formura_Tmp_Floor tmp_floor;
static Formura_Tmp_Wall_1 tmp_wall_1;
static Formura_Tmp_Wall_2 tmp_wall_2;
static Formura_Tmp_Wall_3 tmp_wall_3;
static Formura_Comm_Buff send_buf4_p1_0_0[8][16][16];
static Formura_Comm_Buff recv_buf4_m1_0_0[8][16][16];
static Formura_Comm_Buff send_buf4_0_p1_0[128][8][16];
static Formura_Comm_Buff recv_buf4_0_m1_0[128][8][16];
static Formura_Comm_Buff send_buf4_0_0_p1[128][16][8];
static Formura_Comm_Buff recv_buf4_0_0_m1[128][16][8];
static Formura_Comm_Buff send_buf4_p1_p1_0[8][8][16];
static Formura_Comm_Buff recv_buf4_m1_m1_0[8][8][16];
static Formura_Comm_Buff send_buf4_p1_0_p1[8][16][8];
static Formura_Comm_Buff recv_buf4_m1_0_m1[8][16][8];
static Formura_Comm_Buff send_buf4_0_p1_p1[128][8][8];
static Formura_Comm_Buff recv_buf4_0_m1_m1[128][8][8];
static Formura_Comm_Buff send_buf4_p1_p1_p1[8][8][8];
static Formura_Comm_Buff recv_buf4_m1_m1_m1[8][8][8];
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
for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
double a0 = 0.0;
formura_data.Ex[i1][i2][i3] = a0;
}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
double a0 = i1+n.offset_x+block_offset_1;
double a1 = 7.8125e-3;
double a2 = a0*a1;
double a3 = 128.0;
double a4 = a3*a1;
double a5 = 2.0;
double a6 = a4/a5;
double a7 = a2-a6;
double a8 = 8.0;
double a9 = a8*a1;
double a10 = a7/a9;
double a11 = 2.0;
double a12 = pow(a10,a11);
double a13 = -a12;
double a14 = exp(a13);
formura_data.Ey[i1][i2][i3] = a14;
}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
double a0 = 0.0;
formura_data.Ez[i1][i2][i3] = a0;
}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
double a0 = 0.0;
formura_data.Bx[i1][i2][i3] = a0;
}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
double a0 = 0.0;
formura_data.By[i1][i2][i3] = a0;
}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
double a0 = i1+n.offset_x+block_offset_1;
double a1 = 7.8125e-3;
double a2 = a0*a1;
double a3 = 128.0;
double a4 = a3*a1;
double a5 = 2.0;
double a6 = a4/a5;
double a7 = a2-a6;
double a8 = 8.0;
double a9 = a8*a1;
double a10 = a7/a9;
double a11 = 2.0;
double a12 = pow(a10,a11);
double a13 = -a12;
double a14 = exp(a13);
formura_data.Bz[i1][i2][i3] = a14;
}
}
}

}
void Formura_Step(Formura_Buff * buff,Formura_Rslt * rslt,Formura_Navi n,int block_offset_1,int block_offset_2,int block_offset_3) {
for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
double a0 = buff->Ex[i1+1][i2+1][i3+1];
double a1 = 1.0;
double a2 = -a1;
double a3 = buff->Bz[i1+1][i2][i3+1];
double a4 = a2*a3;
double a5 = 0.1;
double a6 = 7.8125e-3;
double a7 = a5*a6;
double a8 = a4*a7;
double a9 = 2.0;
double a10 = 7.8125e-3;
double a11 = a9*a10;
double a12 = a8/a11;
double a13 = a0+a12;
double a14 = buff->Bz[i1+1][i2+2][i3+1];
double a15 = a14*a7;
double a16 = 2.0;
double a17 = a16*a10;
double a18 = a15/a17;
double a19 = a13+a18;
double a20 = buff->By[i1+1][i2+1][i3];
double a21 = a20*a7;
double a22 = 2.0;
double a23 = 7.8125e-3;
double a24 = a22*a23;
double a25 = a21/a24;
double a26 = a19+a25;
double a27 = 1.0;
double a28 = -a27;
double a29 = buff->By[i1+1][i2+1][i3+2];
double a30 = a28*a29;
double a31 = a30*a7;
double a32 = 2.0;
double a33 = a32*a23;
double a34 = a31/a33;
double a35 = a26+a34;
rslt->Ex[i1][i2][i3] = a35;
}
}
}

for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
double a0 = buff->Ey[i1+1][i2+1][i3+1];
double a1 = buff->Bz[i1][i2+1][i3+1];
double a2 = 0.1;
double a3 = 7.8125e-3;
double a4 = a2*a3;
double a5 = a1*a4;
double a6 = 2.0;
double a7 = a6*a3;
double a8 = a5/a7;
double a9 = a0+a8;
double a10 = 1.0;
double a11 = -a10;
double a12 = buff->Bz[i1+2][i2+1][i3+1];
double a13 = a11*a12;
double a14 = a13*a4;
double a15 = 2.0;
double a16 = a15*a3;
double a17 = a14/a16;
double a18 = a9+a17;
double a19 = 1.0;
double a20 = -a19;
double a21 = buff->Bx[i1+1][i2+1][i3];
double a22 = a20*a21;
double a23 = a22*a4;
double a24 = 2.0;
double a25 = 7.8125e-3;
double a26 = a24*a25;
double a27 = a23/a26;
double a28 = a18+a27;
double a29 = buff->Bx[i1+1][i2+1][i3+2];
double a30 = a29*a4;
double a31 = 2.0;
double a32 = a31*a25;
double a33 = a30/a32;
double a34 = a28+a33;
rslt->Ey[i1][i2][i3] = a34;
}
}
}

for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
double a0 = buff->Ez[i1+1][i2+1][i3+1];
double a1 = 1.0;
double a2 = -a1;
double a3 = buff->By[i1][i2+1][i3+1];
double a4 = a2*a3;
double a5 = 0.1;
double a6 = 7.8125e-3;
double a7 = a5*a6;
double a8 = a4*a7;
double a9 = 2.0;
double a10 = a9*a6;
double a11 = a8/a10;
double a12 = a0+a11;
double a13 = buff->By[i1+2][i2+1][i3+1];
double a14 = a13*a7;
double a15 = 2.0;
double a16 = a15*a6;
double a17 = a14/a16;
double a18 = a12+a17;
double a19 = buff->Bx[i1+1][i2][i3+1];
double a20 = a19*a7;
double a21 = 2.0;
double a22 = 7.8125e-3;
double a23 = a21*a22;
double a24 = a20/a23;
double a25 = a18+a24;
double a26 = 1.0;
double a27 = -a26;
double a28 = buff->Bx[i1+1][i2+2][i3+1];
double a29 = a27*a28;
double a30 = a29*a7;
double a31 = 2.0;
double a32 = a31*a22;
double a33 = a30/a32;
double a34 = a25+a33;
rslt->Ez[i1][i2][i3] = a34;
}
}
}

for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
double a0 = buff->Bx[i1+1][i2+1][i3+1];
rslt->Bx[i1][i2][i3] = a0;
}
}
}

for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
double a0 = buff->By[i1+1][i2+1][i3+1];
rslt->By[i1][i2][i3] = a0;
}
}
}

for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
double a0 = buff->Bz[i1+1][i2+1][i3+1];
rslt->Bz[i1][i2][i3] = a0;
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
n->upper_x = 128;
n->upper_y = 16;
n->upper_z = 16;
n->space_interval_x = 7.8125e-3;
n->space_interval_y = 7.8125e-3;
n->space_interval_z = 7.8125e-3;
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
n->offset_x = 128*i1;
n->offset_y = 16*i2;
n->offset_z = 16*i3;
n->length_x = 1.0;
n->length_y = 0.125;
n->length_z = 0.125;
n->total_grid_x = 128;
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
n->upper_x = 128;
n->upper_y = 16;
n->upper_z = 16;
n->space_interval_x = 7.8125e-3;
n->space_interval_y = 7.8125e-3;
n->space_interval_z = 7.8125e-3;
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
n->offset_x = 128*i1;
n->offset_y = 16*i2;
n->offset_z = 16*i3;
n->length_x = 1.0;
n->length_y = 0.125;
n->length_z = 0.125;
n->total_grid_x = 128;
n->total_grid_y = 16;
n->total_grid_z = 16;
Formura_Setup(*n,0,0,0);
}
void Formura_Forward(Formura_Navi * n) {
for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
tmp_floor.Bx[i1+8][i2+8][i3+8] = formura_data.Bx[i1][i2][i3];
tmp_floor.By[i1+8][i2+8][i3+8] = formura_data.By[i1][i2][i3];
tmp_floor.Bz[i1+8][i2+8][i3+8] = formura_data.Bz[i1][i2][i3];
tmp_floor.Ex[i1+8][i2+8][i3+8] = formura_data.Ex[i1][i2][i3];
tmp_floor.Ey[i1+8][i2+8][i3+8] = formura_data.Ey[i1][i2][i3];
tmp_floor.Ez[i1+8][i2+8][i3+8] = formura_data.Ez[i1][i2][i3];
}
}
}

for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
send_buf4_p1_0_0[i1][i2][i3].Bx = formura_data.Bx[i1+120][i2][i3];
send_buf4_p1_0_0[i1][i2][i3].By = formura_data.By[i1+120][i2][i3];
send_buf4_p1_0_0[i1][i2][i3].Bz = formura_data.Bz[i1+120][i2][i3];
send_buf4_p1_0_0[i1][i2][i3].Ex = formura_data.Ex[i1+120][i2][i3];
send_buf4_p1_0_0[i1][i2][i3].Ey = formura_data.Ey[i1+120][i2][i3];
send_buf4_p1_0_0[i1][i2][i3].Ez = formura_data.Ez[i1+120][i2][i3];
}
}
}

MPI_Request send_req_p1_0_0;
MPI_Isend(send_buf4_p1_0_0,sizeof(send_buf4_p1_0_0),MPI_BYTE,n->rank_p1_0_0,0,n->mpi_world,&send_req_p1_0_0);
MPI_Request recv_req_m1_0_0;
MPI_Irecv(recv_buf4_m1_0_0,sizeof(recv_buf4_m1_0_0),MPI_BYTE,n->rank_m1_0_0,0,n->mpi_world,&recv_req_m1_0_0);
for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
send_buf4_0_p1_0[i1][i2][i3].Bx = formura_data.Bx[i1][i2+8][i3];
send_buf4_0_p1_0[i1][i2][i3].By = formura_data.By[i1][i2+8][i3];
send_buf4_0_p1_0[i1][i2][i3].Bz = formura_data.Bz[i1][i2+8][i3];
send_buf4_0_p1_0[i1][i2][i3].Ex = formura_data.Ex[i1][i2+8][i3];
send_buf4_0_p1_0[i1][i2][i3].Ey = formura_data.Ey[i1][i2+8][i3];
send_buf4_0_p1_0[i1][i2][i3].Ez = formura_data.Ez[i1][i2+8][i3];
}
}
}

MPI_Request send_req_0_p1_0;
MPI_Isend(send_buf4_0_p1_0,sizeof(send_buf4_0_p1_0),MPI_BYTE,n->rank_0_p1_0,0,n->mpi_world,&send_req_0_p1_0);
MPI_Request recv_req_0_m1_0;
MPI_Irecv(recv_buf4_0_m1_0,sizeof(recv_buf4_0_m1_0),MPI_BYTE,n->rank_0_m1_0,0,n->mpi_world,&recv_req_0_m1_0);
for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
send_buf4_0_0_p1[i1][i2][i3].Bx = formura_data.Bx[i1][i2][i3+8];
send_buf4_0_0_p1[i1][i2][i3].By = formura_data.By[i1][i2][i3+8];
send_buf4_0_0_p1[i1][i2][i3].Bz = formura_data.Bz[i1][i2][i3+8];
send_buf4_0_0_p1[i1][i2][i3].Ex = formura_data.Ex[i1][i2][i3+8];
send_buf4_0_0_p1[i1][i2][i3].Ey = formura_data.Ey[i1][i2][i3+8];
send_buf4_0_0_p1[i1][i2][i3].Ez = formura_data.Ez[i1][i2][i3+8];
}
}
}

MPI_Request send_req_0_0_p1;
MPI_Isend(send_buf4_0_0_p1,sizeof(send_buf4_0_0_p1),MPI_BYTE,n->rank_0_0_p1,0,n->mpi_world,&send_req_0_0_p1);
MPI_Request recv_req_0_0_m1;
MPI_Irecv(recv_buf4_0_0_m1,sizeof(recv_buf4_0_0_m1),MPI_BYTE,n->rank_0_0_m1,0,n->mpi_world,&recv_req_0_0_m1);
for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
send_buf4_p1_p1_0[i1][i2][i3].Bx = formura_data.Bx[i1+120][i2+8][i3];
send_buf4_p1_p1_0[i1][i2][i3].By = formura_data.By[i1+120][i2+8][i3];
send_buf4_p1_p1_0[i1][i2][i3].Bz = formura_data.Bz[i1+120][i2+8][i3];
send_buf4_p1_p1_0[i1][i2][i3].Ex = formura_data.Ex[i1+120][i2+8][i3];
send_buf4_p1_p1_0[i1][i2][i3].Ey = formura_data.Ey[i1+120][i2+8][i3];
send_buf4_p1_p1_0[i1][i2][i3].Ez = formura_data.Ez[i1+120][i2+8][i3];
}
}
}

MPI_Request send_req_p1_p1_0;
MPI_Isend(send_buf4_p1_p1_0,sizeof(send_buf4_p1_p1_0),MPI_BYTE,n->rank_p1_p1_0,0,n->mpi_world,&send_req_p1_p1_0);
MPI_Request recv_req_m1_m1_0;
MPI_Irecv(recv_buf4_m1_m1_0,sizeof(recv_buf4_m1_m1_0),MPI_BYTE,n->rank_m1_m1_0,0,n->mpi_world,&recv_req_m1_m1_0);
for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
send_buf4_p1_0_p1[i1][i2][i3].Bx = formura_data.Bx[i1+120][i2][i3+8];
send_buf4_p1_0_p1[i1][i2][i3].By = formura_data.By[i1+120][i2][i3+8];
send_buf4_p1_0_p1[i1][i2][i3].Bz = formura_data.Bz[i1+120][i2][i3+8];
send_buf4_p1_0_p1[i1][i2][i3].Ex = formura_data.Ex[i1+120][i2][i3+8];
send_buf4_p1_0_p1[i1][i2][i3].Ey = formura_data.Ey[i1+120][i2][i3+8];
send_buf4_p1_0_p1[i1][i2][i3].Ez = formura_data.Ez[i1+120][i2][i3+8];
}
}
}

MPI_Request send_req_p1_0_p1;
MPI_Isend(send_buf4_p1_0_p1,sizeof(send_buf4_p1_0_p1),MPI_BYTE,n->rank_p1_0_p1,0,n->mpi_world,&send_req_p1_0_p1);
MPI_Request recv_req_m1_0_m1;
MPI_Irecv(recv_buf4_m1_0_m1,sizeof(recv_buf4_m1_0_m1),MPI_BYTE,n->rank_m1_0_m1,0,n->mpi_world,&recv_req_m1_0_m1);
for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
send_buf4_0_p1_p1[i1][i2][i3].Bx = formura_data.Bx[i1][i2+8][i3+8];
send_buf4_0_p1_p1[i1][i2][i3].By = formura_data.By[i1][i2+8][i3+8];
send_buf4_0_p1_p1[i1][i2][i3].Bz = formura_data.Bz[i1][i2+8][i3+8];
send_buf4_0_p1_p1[i1][i2][i3].Ex = formura_data.Ex[i1][i2+8][i3+8];
send_buf4_0_p1_p1[i1][i2][i3].Ey = formura_data.Ey[i1][i2+8][i3+8];
send_buf4_0_p1_p1[i1][i2][i3].Ez = formura_data.Ez[i1][i2+8][i3+8];
}
}
}

MPI_Request send_req_0_p1_p1;
MPI_Isend(send_buf4_0_p1_p1,sizeof(send_buf4_0_p1_p1),MPI_BYTE,n->rank_0_p1_p1,0,n->mpi_world,&send_req_0_p1_p1);
MPI_Request recv_req_0_m1_m1;
MPI_Irecv(recv_buf4_0_m1_m1,sizeof(recv_buf4_0_m1_m1),MPI_BYTE,n->rank_0_m1_m1,0,n->mpi_world,&recv_req_0_m1_m1);
for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
send_buf4_p1_p1_p1[i1][i2][i3].Bx = formura_data.Bx[i1+120][i2+8][i3+8];
send_buf4_p1_p1_p1[i1][i2][i3].By = formura_data.By[i1+120][i2+8][i3+8];
send_buf4_p1_p1_p1[i1][i2][i3].Bz = formura_data.Bz[i1+120][i2+8][i3+8];
send_buf4_p1_p1_p1[i1][i2][i3].Ex = formura_data.Ex[i1+120][i2+8][i3+8];
send_buf4_p1_p1_p1[i1][i2][i3].Ey = formura_data.Ey[i1+120][i2+8][i3+8];
send_buf4_p1_p1_p1[i1][i2][i3].Ez = formura_data.Ez[i1+120][i2+8][i3+8];
}
}
}

MPI_Request send_req_p1_p1_p1;
MPI_Isend(send_buf4_p1_p1_p1,sizeof(send_buf4_p1_p1_p1),MPI_BYTE,n->rank_p1_p1_p1,0,n->mpi_world,&send_req_p1_p1_p1);
MPI_Request recv_req_m1_m1_m1;
MPI_Irecv(recv_buf4_m1_m1_m1,sizeof(recv_buf4_m1_m1_m1),MPI_BYTE,n->rank_m1_m1_m1,0,n->mpi_world,&recv_req_m1_m1_m1);
for(int j1 = 0; j1 < 15; j1 += 1) {
for(int j2 = 0; j2 < 1; j2 += 1) {
for(int j3 = 0; j3 < 1; j3 += 1) {
for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
rslt.Bx[i1][i2][i3] = tmp_floor.Bx[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
rslt.By[i1][i2][i3] = tmp_floor.By[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
rslt.Bz[i1][i2][i3] = tmp_floor.Bz[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
rslt.Ex[i1][i2][i3] = tmp_floor.Ex[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
rslt.Ey[i1][i2][i3] = tmp_floor.Ey[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
rslt.Ez[i1][i2][i3] = tmp_floor.Ez[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
}
}
}

for(int it = 0; it < 4; it += 1) {
for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
buff.Bx[i1][i2][i3] = rslt.Bx[i1][i2][i3];
buff.By[i1][i2][i3] = rslt.By[i1][i2][i3];
buff.Bz[i1][i2][i3] = rslt.Bz[i1][i2][i3];
buff.Ex[i1][i2][i3] = rslt.Ex[i1][i2][i3];
buff.Ey[i1][i2][i3] = rslt.Ey[i1][i2][i3];
buff.Ez[i1][i2][i3] = rslt.Ez[i1][i2][i3];
}
}
}

for(int i1 = 0; i1 < 2; i1 += 1) {
for(int i2 = 0; i2 < 10; i2 += 1) {
for(int i3 = 0; i3 < 10; i3 += 1) {
buff.Bx[i1+8][i2][i3] = tmp_wall_1.Bx[j2][j3][it][i1][i2][i3];
buff.By[i1+8][i2][i3] = tmp_wall_1.By[j2][j3][it][i1][i2][i3];
buff.Bz[i1+8][i2][i3] = tmp_wall_1.Bz[j2][j3][it][i1][i2][i3];
buff.Ex[i1+8][i2][i3] = tmp_wall_1.Ex[j2][j3][it][i1][i2][i3];
buff.Ey[i1+8][i2][i3] = tmp_wall_1.Ey[j2][j3][it][i1][i2][i3];
buff.Ez[i1+8][i2][i3] = tmp_wall_1.Ez[j2][j3][it][i1][i2][i3];
}
}
}

for(int i1 = 0; i1 < 10; i1 += 1) {
for(int i2 = 0; i2 < 2; i2 += 1) {
for(int i3 = 0; i3 < 10; i3 += 1) {
buff.Bx[i1][i2+8][i3] = tmp_wall_2.Bx[j1][j3][it][i1][i2][i3];
buff.By[i1][i2+8][i3] = tmp_wall_2.By[j1][j3][it][i1][i2][i3];
buff.Bz[i1][i2+8][i3] = tmp_wall_2.Bz[j1][j3][it][i1][i2][i3];
buff.Ex[i1][i2+8][i3] = tmp_wall_2.Ex[j1][j3][it][i1][i2][i3];
buff.Ey[i1][i2+8][i3] = tmp_wall_2.Ey[j1][j3][it][i1][i2][i3];
buff.Ez[i1][i2+8][i3] = tmp_wall_2.Ez[j1][j3][it][i1][i2][i3];
}
}
}

for(int i1 = 0; i1 < 10; i1 += 1) {
for(int i2 = 0; i2 < 10; i2 += 1) {
for(int i3 = 0; i3 < 2; i3 += 1) {
buff.Bx[i1][i2][i3+8] = tmp_wall_3.Bx[j1][j2][it][i1][i2][i3];
buff.By[i1][i2][i3+8] = tmp_wall_3.By[j1][j2][it][i1][i2][i3];
buff.Bz[i1][i2][i3+8] = tmp_wall_3.Bz[j1][j2][it][i1][i2][i3];
buff.Ex[i1][i2][i3+8] = tmp_wall_3.Ex[j1][j2][it][i1][i2][i3];
buff.Ey[i1][i2][i3+8] = tmp_wall_3.Ey[j1][j2][it][i1][i2][i3];
buff.Ez[i1][i2][i3+8] = tmp_wall_3.Ez[j1][j2][it][i1][i2][i3];
}
}
}

Formura_Step(&buff,&rslt,*n,+128-8*j1,+16-8*j2,+16-8*j3);
for(int i1 = 0; i1 < 2; i1 += 1) {
for(int i2 = 0; i2 < 10; i2 += 1) {
for(int i3 = 0; i3 < 10; i3 += 1) {
tmp_wall_1.Bx[j2][j3][it][i1][i2][i3] = buff.Bx[i1][i2][i3];
tmp_wall_1.By[j2][j3][it][i1][i2][i3] = buff.By[i1][i2][i3];
tmp_wall_1.Bz[j2][j3][it][i1][i2][i3] = buff.Bz[i1][i2][i3];
tmp_wall_1.Ex[j2][j3][it][i1][i2][i3] = buff.Ex[i1][i2][i3];
tmp_wall_1.Ey[j2][j3][it][i1][i2][i3] = buff.Ey[i1][i2][i3];
tmp_wall_1.Ez[j2][j3][it][i1][i2][i3] = buff.Ez[i1][i2][i3];
}
}
}

for(int i1 = 0; i1 < 10; i1 += 1) {
for(int i2 = 0; i2 < 2; i2 += 1) {
for(int i3 = 0; i3 < 10; i3 += 1) {
tmp_wall_2.Bx[j1][j3][it][i1][i2][i3] = buff.Bx[i1][i2][i3];
tmp_wall_2.By[j1][j3][it][i1][i2][i3] = buff.By[i1][i2][i3];
tmp_wall_2.Bz[j1][j3][it][i1][i2][i3] = buff.Bz[i1][i2][i3];
tmp_wall_2.Ex[j1][j3][it][i1][i2][i3] = buff.Ex[i1][i2][i3];
tmp_wall_2.Ey[j1][j3][it][i1][i2][i3] = buff.Ey[i1][i2][i3];
tmp_wall_2.Ez[j1][j3][it][i1][i2][i3] = buff.Ez[i1][i2][i3];
}
}
}

for(int i1 = 0; i1 < 10; i1 += 1) {
for(int i2 = 0; i2 < 10; i2 += 1) {
for(int i3 = 0; i3 < 2; i3 += 1) {
tmp_wall_3.Bx[j1][j2][it][i1][i2][i3] = buff.Bx[i1][i2][i3];
tmp_wall_3.By[j1][j2][it][i1][i2][i3] = buff.By[i1][i2][i3];
tmp_wall_3.Bz[j1][j2][it][i1][i2][i3] = buff.Bz[i1][i2][i3];
tmp_wall_3.Ex[j1][j2][it][i1][i2][i3] = buff.Ex[i1][i2][i3];
tmp_wall_3.Ey[j1][j2][it][i1][i2][i3] = buff.Ey[i1][i2][i3];
tmp_wall_3.Ez[j1][j2][it][i1][i2][i3] = buff.Ez[i1][i2][i3];
}
}
}

}

for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
tmp_floor.Bx[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.Bx[i1][i2][i3];
tmp_floor.By[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.By[i1][i2][i3];
tmp_floor.Bz[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.Bz[i1][i2][i3];
tmp_floor.Ex[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.Ex[i1][i2][i3];
tmp_floor.Ey[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.Ey[i1][i2][i3];
tmp_floor.Ez[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.Ez[i1][i2][i3];
}
}
}

}
}
}

MPI_Wait(&send_req_p1_0_0,MPI_STATUS_IGNORE);
MPI_Wait(&send_req_0_p1_0,MPI_STATUS_IGNORE);
MPI_Wait(&send_req_0_0_p1,MPI_STATUS_IGNORE);
MPI_Wait(&send_req_p1_p1_0,MPI_STATUS_IGNORE);
MPI_Wait(&send_req_p1_0_p1,MPI_STATUS_IGNORE);
MPI_Wait(&send_req_0_p1_p1,MPI_STATUS_IGNORE);
MPI_Wait(&send_req_p1_p1_p1,MPI_STATUS_IGNORE);
MPI_Wait(&recv_req_m1_0_0,MPI_STATUS_IGNORE);
MPI_Wait(&recv_req_0_m1_0,MPI_STATUS_IGNORE);
MPI_Wait(&recv_req_0_0_m1,MPI_STATUS_IGNORE);
MPI_Wait(&recv_req_m1_m1_0,MPI_STATUS_IGNORE);
MPI_Wait(&recv_req_m1_0_m1,MPI_STATUS_IGNORE);
MPI_Wait(&recv_req_0_m1_m1,MPI_STATUS_IGNORE);
MPI_Wait(&recv_req_m1_m1_m1,MPI_STATUS_IGNORE);
for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
tmp_floor.Bx[i1][i2+8][i3+8] = recv_buf4_m1_0_0[i1][i2][i3].Bx;
tmp_floor.By[i1][i2+8][i3+8] = recv_buf4_m1_0_0[i1][i2][i3].By;
tmp_floor.Bz[i1][i2+8][i3+8] = recv_buf4_m1_0_0[i1][i2][i3].Bz;
tmp_floor.Ex[i1][i2+8][i3+8] = recv_buf4_m1_0_0[i1][i2][i3].Ex;
tmp_floor.Ey[i1][i2+8][i3+8] = recv_buf4_m1_0_0[i1][i2][i3].Ey;
tmp_floor.Ez[i1][i2+8][i3+8] = recv_buf4_m1_0_0[i1][i2][i3].Ez;
}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
tmp_floor.Bx[i1+8][i2][i3+8] = recv_buf4_0_m1_0[i1][i2][i3].Bx;
tmp_floor.By[i1+8][i2][i3+8] = recv_buf4_0_m1_0[i1][i2][i3].By;
tmp_floor.Bz[i1+8][i2][i3+8] = recv_buf4_0_m1_0[i1][i2][i3].Bz;
tmp_floor.Ex[i1+8][i2][i3+8] = recv_buf4_0_m1_0[i1][i2][i3].Ex;
tmp_floor.Ey[i1+8][i2][i3+8] = recv_buf4_0_m1_0[i1][i2][i3].Ey;
tmp_floor.Ez[i1+8][i2][i3+8] = recv_buf4_0_m1_0[i1][i2][i3].Ez;
}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
tmp_floor.Bx[i1+8][i2+8][i3] = recv_buf4_0_0_m1[i1][i2][i3].Bx;
tmp_floor.By[i1+8][i2+8][i3] = recv_buf4_0_0_m1[i1][i2][i3].By;
tmp_floor.Bz[i1+8][i2+8][i3] = recv_buf4_0_0_m1[i1][i2][i3].Bz;
tmp_floor.Ex[i1+8][i2+8][i3] = recv_buf4_0_0_m1[i1][i2][i3].Ex;
tmp_floor.Ey[i1+8][i2+8][i3] = recv_buf4_0_0_m1[i1][i2][i3].Ey;
tmp_floor.Ez[i1+8][i2+8][i3] = recv_buf4_0_0_m1[i1][i2][i3].Ez;
}
}
}

for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
tmp_floor.Bx[i1][i2][i3+8] = recv_buf4_m1_m1_0[i1][i2][i3].Bx;
tmp_floor.By[i1][i2][i3+8] = recv_buf4_m1_m1_0[i1][i2][i3].By;
tmp_floor.Bz[i1][i2][i3+8] = recv_buf4_m1_m1_0[i1][i2][i3].Bz;
tmp_floor.Ex[i1][i2][i3+8] = recv_buf4_m1_m1_0[i1][i2][i3].Ex;
tmp_floor.Ey[i1][i2][i3+8] = recv_buf4_m1_m1_0[i1][i2][i3].Ey;
tmp_floor.Ez[i1][i2][i3+8] = recv_buf4_m1_m1_0[i1][i2][i3].Ez;
}
}
}

for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
tmp_floor.Bx[i1][i2+8][i3] = recv_buf4_m1_0_m1[i1][i2][i3].Bx;
tmp_floor.By[i1][i2+8][i3] = recv_buf4_m1_0_m1[i1][i2][i3].By;
tmp_floor.Bz[i1][i2+8][i3] = recv_buf4_m1_0_m1[i1][i2][i3].Bz;
tmp_floor.Ex[i1][i2+8][i3] = recv_buf4_m1_0_m1[i1][i2][i3].Ex;
tmp_floor.Ey[i1][i2+8][i3] = recv_buf4_m1_0_m1[i1][i2][i3].Ey;
tmp_floor.Ez[i1][i2+8][i3] = recv_buf4_m1_0_m1[i1][i2][i3].Ez;
}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
tmp_floor.Bx[i1+8][i2][i3] = recv_buf4_0_m1_m1[i1][i2][i3].Bx;
tmp_floor.By[i1+8][i2][i3] = recv_buf4_0_m1_m1[i1][i2][i3].By;
tmp_floor.Bz[i1+8][i2][i3] = recv_buf4_0_m1_m1[i1][i2][i3].Bz;
tmp_floor.Ex[i1+8][i2][i3] = recv_buf4_0_m1_m1[i1][i2][i3].Ex;
tmp_floor.Ey[i1+8][i2][i3] = recv_buf4_0_m1_m1[i1][i2][i3].Ey;
tmp_floor.Ez[i1+8][i2][i3] = recv_buf4_0_m1_m1[i1][i2][i3].Ez;
}
}
}

for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
tmp_floor.Bx[i1][i2][i3] = recv_buf4_m1_m1_m1[i1][i2][i3].Bx;
tmp_floor.By[i1][i2][i3] = recv_buf4_m1_m1_m1[i1][i2][i3].By;
tmp_floor.Bz[i1][i2][i3] = recv_buf4_m1_m1_m1[i1][i2][i3].Bz;
tmp_floor.Ex[i1][i2][i3] = recv_buf4_m1_m1_m1[i1][i2][i3].Ex;
tmp_floor.Ey[i1][i2][i3] = recv_buf4_m1_m1_m1[i1][i2][i3].Ey;
tmp_floor.Ez[i1][i2][i3] = recv_buf4_m1_m1_m1[i1][i2][i3].Ez;
}
}
}

for(int j1 = 15; j1 < 17; j1 += 1) {
for(int j2 = 0; j2 < 1; j2 += 1) {
for(int j3 = 0; j3 < 1; j3 += 1) {
for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
rslt.Bx[i1][i2][i3] = tmp_floor.Bx[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
rslt.By[i1][i2][i3] = tmp_floor.By[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
rslt.Bz[i1][i2][i3] = tmp_floor.Bz[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
rslt.Ex[i1][i2][i3] = tmp_floor.Ex[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
rslt.Ey[i1][i2][i3] = tmp_floor.Ey[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
rslt.Ez[i1][i2][i3] = tmp_floor.Ez[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
}
}
}

for(int it = 0; it < 4; it += 1) {
for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
buff.Bx[i1][i2][i3] = rslt.Bx[i1][i2][i3];
buff.By[i1][i2][i3] = rslt.By[i1][i2][i3];
buff.Bz[i1][i2][i3] = rslt.Bz[i1][i2][i3];
buff.Ex[i1][i2][i3] = rslt.Ex[i1][i2][i3];
buff.Ey[i1][i2][i3] = rslt.Ey[i1][i2][i3];
buff.Ez[i1][i2][i3] = rslt.Ez[i1][i2][i3];
}
}
}

for(int i1 = 0; i1 < 2; i1 += 1) {
for(int i2 = 0; i2 < 10; i2 += 1) {
for(int i3 = 0; i3 < 10; i3 += 1) {
buff.Bx[i1+8][i2][i3] = tmp_wall_1.Bx[j2][j3][it][i1][i2][i3];
buff.By[i1+8][i2][i3] = tmp_wall_1.By[j2][j3][it][i1][i2][i3];
buff.Bz[i1+8][i2][i3] = tmp_wall_1.Bz[j2][j3][it][i1][i2][i3];
buff.Ex[i1+8][i2][i3] = tmp_wall_1.Ex[j2][j3][it][i1][i2][i3];
buff.Ey[i1+8][i2][i3] = tmp_wall_1.Ey[j2][j3][it][i1][i2][i3];
buff.Ez[i1+8][i2][i3] = tmp_wall_1.Ez[j2][j3][it][i1][i2][i3];
}
}
}

for(int i1 = 0; i1 < 10; i1 += 1) {
for(int i2 = 0; i2 < 2; i2 += 1) {
for(int i3 = 0; i3 < 10; i3 += 1) {
buff.Bx[i1][i2+8][i3] = tmp_wall_2.Bx[j1][j3][it][i1][i2][i3];
buff.By[i1][i2+8][i3] = tmp_wall_2.By[j1][j3][it][i1][i2][i3];
buff.Bz[i1][i2+8][i3] = tmp_wall_2.Bz[j1][j3][it][i1][i2][i3];
buff.Ex[i1][i2+8][i3] = tmp_wall_2.Ex[j1][j3][it][i1][i2][i3];
buff.Ey[i1][i2+8][i3] = tmp_wall_2.Ey[j1][j3][it][i1][i2][i3];
buff.Ez[i1][i2+8][i3] = tmp_wall_2.Ez[j1][j3][it][i1][i2][i3];
}
}
}

for(int i1 = 0; i1 < 10; i1 += 1) {
for(int i2 = 0; i2 < 10; i2 += 1) {
for(int i3 = 0; i3 < 2; i3 += 1) {
buff.Bx[i1][i2][i3+8] = tmp_wall_3.Bx[j1][j2][it][i1][i2][i3];
buff.By[i1][i2][i3+8] = tmp_wall_3.By[j1][j2][it][i1][i2][i3];
buff.Bz[i1][i2][i3+8] = tmp_wall_3.Bz[j1][j2][it][i1][i2][i3];
buff.Ex[i1][i2][i3+8] = tmp_wall_3.Ex[j1][j2][it][i1][i2][i3];
buff.Ey[i1][i2][i3+8] = tmp_wall_3.Ey[j1][j2][it][i1][i2][i3];
buff.Ez[i1][i2][i3+8] = tmp_wall_3.Ez[j1][j2][it][i1][i2][i3];
}
}
}

Formura_Step(&buff,&rslt,*n,+128-8*j1,+16-8*j2,+16-8*j3);
for(int i1 = 0; i1 < 2; i1 += 1) {
for(int i2 = 0; i2 < 10; i2 += 1) {
for(int i3 = 0; i3 < 10; i3 += 1) {
tmp_wall_1.Bx[j2][j3][it][i1][i2][i3] = buff.Bx[i1][i2][i3];
tmp_wall_1.By[j2][j3][it][i1][i2][i3] = buff.By[i1][i2][i3];
tmp_wall_1.Bz[j2][j3][it][i1][i2][i3] = buff.Bz[i1][i2][i3];
tmp_wall_1.Ex[j2][j3][it][i1][i2][i3] = buff.Ex[i1][i2][i3];
tmp_wall_1.Ey[j2][j3][it][i1][i2][i3] = buff.Ey[i1][i2][i3];
tmp_wall_1.Ez[j2][j3][it][i1][i2][i3] = buff.Ez[i1][i2][i3];
}
}
}

for(int i1 = 0; i1 < 10; i1 += 1) {
for(int i2 = 0; i2 < 2; i2 += 1) {
for(int i3 = 0; i3 < 10; i3 += 1) {
tmp_wall_2.Bx[j1][j3][it][i1][i2][i3] = buff.Bx[i1][i2][i3];
tmp_wall_2.By[j1][j3][it][i1][i2][i3] = buff.By[i1][i2][i3];
tmp_wall_2.Bz[j1][j3][it][i1][i2][i3] = buff.Bz[i1][i2][i3];
tmp_wall_2.Ex[j1][j3][it][i1][i2][i3] = buff.Ex[i1][i2][i3];
tmp_wall_2.Ey[j1][j3][it][i1][i2][i3] = buff.Ey[i1][i2][i3];
tmp_wall_2.Ez[j1][j3][it][i1][i2][i3] = buff.Ez[i1][i2][i3];
}
}
}

for(int i1 = 0; i1 < 10; i1 += 1) {
for(int i2 = 0; i2 < 10; i2 += 1) {
for(int i3 = 0; i3 < 2; i3 += 1) {
tmp_wall_3.Bx[j1][j2][it][i1][i2][i3] = buff.Bx[i1][i2][i3];
tmp_wall_3.By[j1][j2][it][i1][i2][i3] = buff.By[i1][i2][i3];
tmp_wall_3.Bz[j1][j2][it][i1][i2][i3] = buff.Bz[i1][i2][i3];
tmp_wall_3.Ex[j1][j2][it][i1][i2][i3] = buff.Ex[i1][i2][i3];
tmp_wall_3.Ey[j1][j2][it][i1][i2][i3] = buff.Ey[i1][i2][i3];
tmp_wall_3.Ez[j1][j2][it][i1][i2][i3] = buff.Ez[i1][i2][i3];
}
}
}

}

for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
tmp_floor.Bx[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.Bx[i1][i2][i3];
tmp_floor.By[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.By[i1][i2][i3];
tmp_floor.Bz[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.Bz[i1][i2][i3];
tmp_floor.Ex[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.Ex[i1][i2][i3];
tmp_floor.Ey[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.Ey[i1][i2][i3];
tmp_floor.Ez[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.Ez[i1][i2][i3];
}
}
}

}
}
}

for(int j1 = 0; j1 < 17; j1 += 1) {
for(int j2 = 1; j2 < 3; j2 += 1) {
for(int j3 = 0; j3 < 1; j3 += 1) {
for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
rslt.Bx[i1][i2][i3] = tmp_floor.Bx[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
rslt.By[i1][i2][i3] = tmp_floor.By[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
rslt.Bz[i1][i2][i3] = tmp_floor.Bz[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
rslt.Ex[i1][i2][i3] = tmp_floor.Ex[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
rslt.Ey[i1][i2][i3] = tmp_floor.Ey[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
rslt.Ez[i1][i2][i3] = tmp_floor.Ez[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
}
}
}

for(int it = 0; it < 4; it += 1) {
for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
buff.Bx[i1][i2][i3] = rslt.Bx[i1][i2][i3];
buff.By[i1][i2][i3] = rslt.By[i1][i2][i3];
buff.Bz[i1][i2][i3] = rslt.Bz[i1][i2][i3];
buff.Ex[i1][i2][i3] = rslt.Ex[i1][i2][i3];
buff.Ey[i1][i2][i3] = rslt.Ey[i1][i2][i3];
buff.Ez[i1][i2][i3] = rslt.Ez[i1][i2][i3];
}
}
}

for(int i1 = 0; i1 < 2; i1 += 1) {
for(int i2 = 0; i2 < 10; i2 += 1) {
for(int i3 = 0; i3 < 10; i3 += 1) {
buff.Bx[i1+8][i2][i3] = tmp_wall_1.Bx[j2][j3][it][i1][i2][i3];
buff.By[i1+8][i2][i3] = tmp_wall_1.By[j2][j3][it][i1][i2][i3];
buff.Bz[i1+8][i2][i3] = tmp_wall_1.Bz[j2][j3][it][i1][i2][i3];
buff.Ex[i1+8][i2][i3] = tmp_wall_1.Ex[j2][j3][it][i1][i2][i3];
buff.Ey[i1+8][i2][i3] = tmp_wall_1.Ey[j2][j3][it][i1][i2][i3];
buff.Ez[i1+8][i2][i3] = tmp_wall_1.Ez[j2][j3][it][i1][i2][i3];
}
}
}

for(int i1 = 0; i1 < 10; i1 += 1) {
for(int i2 = 0; i2 < 2; i2 += 1) {
for(int i3 = 0; i3 < 10; i3 += 1) {
buff.Bx[i1][i2+8][i3] = tmp_wall_2.Bx[j1][j3][it][i1][i2][i3];
buff.By[i1][i2+8][i3] = tmp_wall_2.By[j1][j3][it][i1][i2][i3];
buff.Bz[i1][i2+8][i3] = tmp_wall_2.Bz[j1][j3][it][i1][i2][i3];
buff.Ex[i1][i2+8][i3] = tmp_wall_2.Ex[j1][j3][it][i1][i2][i3];
buff.Ey[i1][i2+8][i3] = tmp_wall_2.Ey[j1][j3][it][i1][i2][i3];
buff.Ez[i1][i2+8][i3] = tmp_wall_2.Ez[j1][j3][it][i1][i2][i3];
}
}
}

for(int i1 = 0; i1 < 10; i1 += 1) {
for(int i2 = 0; i2 < 10; i2 += 1) {
for(int i3 = 0; i3 < 2; i3 += 1) {
buff.Bx[i1][i2][i3+8] = tmp_wall_3.Bx[j1][j2][it][i1][i2][i3];
buff.By[i1][i2][i3+8] = tmp_wall_3.By[j1][j2][it][i1][i2][i3];
buff.Bz[i1][i2][i3+8] = tmp_wall_3.Bz[j1][j2][it][i1][i2][i3];
buff.Ex[i1][i2][i3+8] = tmp_wall_3.Ex[j1][j2][it][i1][i2][i3];
buff.Ey[i1][i2][i3+8] = tmp_wall_3.Ey[j1][j2][it][i1][i2][i3];
buff.Ez[i1][i2][i3+8] = tmp_wall_3.Ez[j1][j2][it][i1][i2][i3];
}
}
}

Formura_Step(&buff,&rslt,*n,+128-8*j1,+16-8*j2,+16-8*j3);
for(int i1 = 0; i1 < 2; i1 += 1) {
for(int i2 = 0; i2 < 10; i2 += 1) {
for(int i3 = 0; i3 < 10; i3 += 1) {
tmp_wall_1.Bx[j2][j3][it][i1][i2][i3] = buff.Bx[i1][i2][i3];
tmp_wall_1.By[j2][j3][it][i1][i2][i3] = buff.By[i1][i2][i3];
tmp_wall_1.Bz[j2][j3][it][i1][i2][i3] = buff.Bz[i1][i2][i3];
tmp_wall_1.Ex[j2][j3][it][i1][i2][i3] = buff.Ex[i1][i2][i3];
tmp_wall_1.Ey[j2][j3][it][i1][i2][i3] = buff.Ey[i1][i2][i3];
tmp_wall_1.Ez[j2][j3][it][i1][i2][i3] = buff.Ez[i1][i2][i3];
}
}
}

for(int i1 = 0; i1 < 10; i1 += 1) {
for(int i2 = 0; i2 < 2; i2 += 1) {
for(int i3 = 0; i3 < 10; i3 += 1) {
tmp_wall_2.Bx[j1][j3][it][i1][i2][i3] = buff.Bx[i1][i2][i3];
tmp_wall_2.By[j1][j3][it][i1][i2][i3] = buff.By[i1][i2][i3];
tmp_wall_2.Bz[j1][j3][it][i1][i2][i3] = buff.Bz[i1][i2][i3];
tmp_wall_2.Ex[j1][j3][it][i1][i2][i3] = buff.Ex[i1][i2][i3];
tmp_wall_2.Ey[j1][j3][it][i1][i2][i3] = buff.Ey[i1][i2][i3];
tmp_wall_2.Ez[j1][j3][it][i1][i2][i3] = buff.Ez[i1][i2][i3];
}
}
}

for(int i1 = 0; i1 < 10; i1 += 1) {
for(int i2 = 0; i2 < 10; i2 += 1) {
for(int i3 = 0; i3 < 2; i3 += 1) {
tmp_wall_3.Bx[j1][j2][it][i1][i2][i3] = buff.Bx[i1][i2][i3];
tmp_wall_3.By[j1][j2][it][i1][i2][i3] = buff.By[i1][i2][i3];
tmp_wall_3.Bz[j1][j2][it][i1][i2][i3] = buff.Bz[i1][i2][i3];
tmp_wall_3.Ex[j1][j2][it][i1][i2][i3] = buff.Ex[i1][i2][i3];
tmp_wall_3.Ey[j1][j2][it][i1][i2][i3] = buff.Ey[i1][i2][i3];
tmp_wall_3.Ez[j1][j2][it][i1][i2][i3] = buff.Ez[i1][i2][i3];
}
}
}

}

for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
tmp_floor.Bx[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.Bx[i1][i2][i3];
tmp_floor.By[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.By[i1][i2][i3];
tmp_floor.Bz[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.Bz[i1][i2][i3];
tmp_floor.Ex[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.Ex[i1][i2][i3];
tmp_floor.Ey[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.Ey[i1][i2][i3];
tmp_floor.Ez[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.Ez[i1][i2][i3];
}
}
}

}
}
}

for(int j1 = 0; j1 < 17; j1 += 1) {
for(int j2 = 0; j2 < 3; j2 += 1) {
for(int j3 = 1; j3 < 3; j3 += 1) {
for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
rslt.Bx[i1][i2][i3] = tmp_floor.Bx[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
rslt.By[i1][i2][i3] = tmp_floor.By[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
rslt.Bz[i1][i2][i3] = tmp_floor.Bz[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
rslt.Ex[i1][i2][i3] = tmp_floor.Ex[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
rslt.Ey[i1][i2][i3] = tmp_floor.Ey[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
rslt.Ez[i1][i2][i3] = tmp_floor.Ez[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3];
}
}
}

for(int it = 0; it < 4; it += 1) {
for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
buff.Bx[i1][i2][i3] = rslt.Bx[i1][i2][i3];
buff.By[i1][i2][i3] = rslt.By[i1][i2][i3];
buff.Bz[i1][i2][i3] = rslt.Bz[i1][i2][i3];
buff.Ex[i1][i2][i3] = rslt.Ex[i1][i2][i3];
buff.Ey[i1][i2][i3] = rslt.Ey[i1][i2][i3];
buff.Ez[i1][i2][i3] = rslt.Ez[i1][i2][i3];
}
}
}

for(int i1 = 0; i1 < 2; i1 += 1) {
for(int i2 = 0; i2 < 10; i2 += 1) {
for(int i3 = 0; i3 < 10; i3 += 1) {
buff.Bx[i1+8][i2][i3] = tmp_wall_1.Bx[j2][j3][it][i1][i2][i3];
buff.By[i1+8][i2][i3] = tmp_wall_1.By[j2][j3][it][i1][i2][i3];
buff.Bz[i1+8][i2][i3] = tmp_wall_1.Bz[j2][j3][it][i1][i2][i3];
buff.Ex[i1+8][i2][i3] = tmp_wall_1.Ex[j2][j3][it][i1][i2][i3];
buff.Ey[i1+8][i2][i3] = tmp_wall_1.Ey[j2][j3][it][i1][i2][i3];
buff.Ez[i1+8][i2][i3] = tmp_wall_1.Ez[j2][j3][it][i1][i2][i3];
}
}
}

for(int i1 = 0; i1 < 10; i1 += 1) {
for(int i2 = 0; i2 < 2; i2 += 1) {
for(int i3 = 0; i3 < 10; i3 += 1) {
buff.Bx[i1][i2+8][i3] = tmp_wall_2.Bx[j1][j3][it][i1][i2][i3];
buff.By[i1][i2+8][i3] = tmp_wall_2.By[j1][j3][it][i1][i2][i3];
buff.Bz[i1][i2+8][i3] = tmp_wall_2.Bz[j1][j3][it][i1][i2][i3];
buff.Ex[i1][i2+8][i3] = tmp_wall_2.Ex[j1][j3][it][i1][i2][i3];
buff.Ey[i1][i2+8][i3] = tmp_wall_2.Ey[j1][j3][it][i1][i2][i3];
buff.Ez[i1][i2+8][i3] = tmp_wall_2.Ez[j1][j3][it][i1][i2][i3];
}
}
}

for(int i1 = 0; i1 < 10; i1 += 1) {
for(int i2 = 0; i2 < 10; i2 += 1) {
for(int i3 = 0; i3 < 2; i3 += 1) {
buff.Bx[i1][i2][i3+8] = tmp_wall_3.Bx[j1][j2][it][i1][i2][i3];
buff.By[i1][i2][i3+8] = tmp_wall_3.By[j1][j2][it][i1][i2][i3];
buff.Bz[i1][i2][i3+8] = tmp_wall_3.Bz[j1][j2][it][i1][i2][i3];
buff.Ex[i1][i2][i3+8] = tmp_wall_3.Ex[j1][j2][it][i1][i2][i3];
buff.Ey[i1][i2][i3+8] = tmp_wall_3.Ey[j1][j2][it][i1][i2][i3];
buff.Ez[i1][i2][i3+8] = tmp_wall_3.Ez[j1][j2][it][i1][i2][i3];
}
}
}

Formura_Step(&buff,&rslt,*n,+128-8*j1,+16-8*j2,+16-8*j3);
for(int i1 = 0; i1 < 2; i1 += 1) {
for(int i2 = 0; i2 < 10; i2 += 1) {
for(int i3 = 0; i3 < 10; i3 += 1) {
tmp_wall_1.Bx[j2][j3][it][i1][i2][i3] = buff.Bx[i1][i2][i3];
tmp_wall_1.By[j2][j3][it][i1][i2][i3] = buff.By[i1][i2][i3];
tmp_wall_1.Bz[j2][j3][it][i1][i2][i3] = buff.Bz[i1][i2][i3];
tmp_wall_1.Ex[j2][j3][it][i1][i2][i3] = buff.Ex[i1][i2][i3];
tmp_wall_1.Ey[j2][j3][it][i1][i2][i3] = buff.Ey[i1][i2][i3];
tmp_wall_1.Ez[j2][j3][it][i1][i2][i3] = buff.Ez[i1][i2][i3];
}
}
}

for(int i1 = 0; i1 < 10; i1 += 1) {
for(int i2 = 0; i2 < 2; i2 += 1) {
for(int i3 = 0; i3 < 10; i3 += 1) {
tmp_wall_2.Bx[j1][j3][it][i1][i2][i3] = buff.Bx[i1][i2][i3];
tmp_wall_2.By[j1][j3][it][i1][i2][i3] = buff.By[i1][i2][i3];
tmp_wall_2.Bz[j1][j3][it][i1][i2][i3] = buff.Bz[i1][i2][i3];
tmp_wall_2.Ex[j1][j3][it][i1][i2][i3] = buff.Ex[i1][i2][i3];
tmp_wall_2.Ey[j1][j3][it][i1][i2][i3] = buff.Ey[i1][i2][i3];
tmp_wall_2.Ez[j1][j3][it][i1][i2][i3] = buff.Ez[i1][i2][i3];
}
}
}

for(int i1 = 0; i1 < 10; i1 += 1) {
for(int i2 = 0; i2 < 10; i2 += 1) {
for(int i3 = 0; i3 < 2; i3 += 1) {
tmp_wall_3.Bx[j1][j2][it][i1][i2][i3] = buff.Bx[i1][i2][i3];
tmp_wall_3.By[j1][j2][it][i1][i2][i3] = buff.By[i1][i2][i3];
tmp_wall_3.Bz[j1][j2][it][i1][i2][i3] = buff.Bz[i1][i2][i3];
tmp_wall_3.Ex[j1][j2][it][i1][i2][i3] = buff.Ex[i1][i2][i3];
tmp_wall_3.Ey[j1][j2][it][i1][i2][i3] = buff.Ey[i1][i2][i3];
tmp_wall_3.Ez[j1][j2][it][i1][i2][i3] = buff.Ez[i1][i2][i3];
}
}
}

}

for(int i1 = 0; i1 < 8; i1 += 1) {
for(int i2 = 0; i2 < 8; i2 += 1) {
for(int i3 = 0; i3 < 8; i3 += 1) {
tmp_floor.Bx[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.Bx[i1][i2][i3];
tmp_floor.By[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.By[i1][i2][i3];
tmp_floor.Bz[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.Bz[i1][i2][i3];
tmp_floor.Ex[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.Ex[i1][i2][i3];
tmp_floor.Ey[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.Ey[i1][i2][i3];
tmp_floor.Ez[i1+128-8*j1][i2+16-8*j2][i3+16-8*j3] = rslt.Ez[i1][i2][i3];
}
}
}

}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
formura_data.Bx[i1][i2][i3] = tmp_floor.Bx[i1][i2][i3];
formura_data.By[i1][i2][i3] = tmp_floor.By[i1][i2][i3];
formura_data.Bz[i1][i2][i3] = tmp_floor.Bz[i1][i2][i3];
formura_data.Ex[i1][i2][i3] = tmp_floor.Ex[i1][i2][i3];
formura_data.Ey[i1][i2][i3] = tmp_floor.Ey[i1][i2][i3];
formura_data.Ez[i1][i2][i3] = tmp_floor.Ez[i1][i2][i3];
}
}
}

n->offset_x = (n->offset_x - 4 + n->total_grid_x)%n->total_grid_x;
n->offset_y = (n->offset_y - 4 + n->total_grid_y)%n->total_grid_y;
n->offset_z = (n->offset_z - 4 + n->total_grid_z)%n->total_grid_z;
n->time_step += 4;
}
void Formura_Finalize() {
MPI_Finalize();
}
