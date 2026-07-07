#include "reproH.h"
typedef struct {
double q[130][18][18];
double r[130][18][18];
} Formura_Buff;
typedef struct {
double q;
double r;
} Formura_Comm_Buff;
static Formura_Buff buff;
static Formura_Comm_Buff send_buf1_p1_0_0[2][16][16];
static Formura_Comm_Buff recv_buf1_m1_0_0[2][16][16];
static Formura_Comm_Buff send_buf1_0_p1_0[128][2][16];
static Formura_Comm_Buff recv_buf1_0_m1_0[128][2][16];
static Formura_Comm_Buff send_buf1_0_0_p1[128][16][2];
static Formura_Comm_Buff recv_buf1_0_0_m1[128][16][2];
static Formura_Comm_Buff send_buf1_p1_p1_0[2][2][16];
static Formura_Comm_Buff recv_buf1_m1_m1_0[2][2][16];
static Formura_Comm_Buff send_buf1_p1_0_p1[2][16][2];
static Formura_Comm_Buff recv_buf1_m1_0_m1[2][16][2];
static Formura_Comm_Buff send_buf1_0_p1_p1[128][2][2];
static Formura_Comm_Buff recv_buf1_0_m1_m1[128][2][2];
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
for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
double a0 = 1.0e-3;
double a1 = i1+n.offset_x+block_offset_1;
double a2 = 128.0;
double a3 = a2-a1;
double a4 = a1*a3;
double a5 = 2.0;
double a6 = i2+n.offset_y+block_offset_2;
double a7 = a5*a6;
double a8 = 16.0;
double a9 = a8-a6;
double a10 = a7*a9;
double a11 = a4+a10;
double a12 = 3.0;
double a13 = i3+n.offset_z+block_offset_3;
double a14 = a12*a13;
double a15 = 16.0;
double a16 = a15-a13;
double a17 = a14*a16;
double a18 = a11+a17;
double a19 = a0*a18;
formura_data.q[i1][i2][i3] = a19;
}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
double a0 = 2.0e-3;
double a1 = i1+n.offset_x+block_offset_1;
double a2 = 128.0;
double a3 = a2-a1;
double a4 = a1*a3;
double a5 = i2+n.offset_y+block_offset_2;
double a6 = 16.0;
double a7 = a6-a5;
double a8 = a5*a7;
double a9 = a4+a8;
double a10 = i3+n.offset_z+block_offset_3;
double a11 = 16.0;
double a12 = a11-a10;
double a13 = a10*a12;
double a14 = a9+a13;
double a15 = a0*a14;
formura_data.r[i1][i2][i3] = a15;
}
}
}

}
void Formura_Step(Formura_Buff * buff,Formura_Grid_Struct * rslt,Formura_Navi n,int block_offset_1,int block_offset_2,int block_offset_3) {
for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
double a0 = buff->q[i1+1][i2+1][i3+1];
double a1 = 5.0e-2;
double a2 = buff->r[i1+1][i2+2][i3+1];
double a3 = buff->r[i1+1][i2][i3+1];
double a4 = a2-a3;
double a5 = a1*a4;
double a6 = a0+a5;
rslt->q[i1][i2][i3] = a6;
}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
double a0 = 0.999;
double a1 = buff->r[i1+1][i2+1][i3+1];
double a2 = a0*a1;
rslt->r[i1][i2][i3] = a2;
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
for(int i1 = 0; i1 < 2; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
send_buf1_p1_0_0[i1][i2][i3].q = formura_data.q[i1+126][i2][i3];
send_buf1_p1_0_0[i1][i2][i3].r = formura_data.r[i1+126][i2][i3];
}
}
}

MPI_Request send_req_p1_0_0;
MPI_Isend(send_buf1_p1_0_0,sizeof(send_buf1_p1_0_0),MPI_BYTE,n->rank_p1_0_0,0,n->mpi_world,&send_req_p1_0_0);
MPI_Request recv_req_m1_0_0;
MPI_Irecv(recv_buf1_m1_0_0,sizeof(recv_buf1_m1_0_0),MPI_BYTE,n->rank_m1_0_0,0,n->mpi_world,&recv_req_m1_0_0);
for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 2; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
send_buf1_0_p1_0[i1][i2][i3].q = formura_data.q[i1][i2+14][i3];
send_buf1_0_p1_0[i1][i2][i3].r = formura_data.r[i1][i2+14][i3];
}
}
}

MPI_Request send_req_0_p1_0;
MPI_Isend(send_buf1_0_p1_0,sizeof(send_buf1_0_p1_0),MPI_BYTE,n->rank_0_p1_0,0,n->mpi_world,&send_req_0_p1_0);
MPI_Request recv_req_0_m1_0;
MPI_Irecv(recv_buf1_0_m1_0,sizeof(recv_buf1_0_m1_0),MPI_BYTE,n->rank_0_m1_0,0,n->mpi_world,&recv_req_0_m1_0);
for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 2; i3 += 1) {
send_buf1_0_0_p1[i1][i2][i3].q = formura_data.q[i1][i2][i3+14];
send_buf1_0_0_p1[i1][i2][i3].r = formura_data.r[i1][i2][i3+14];
}
}
}

MPI_Request send_req_0_0_p1;
MPI_Isend(send_buf1_0_0_p1,sizeof(send_buf1_0_0_p1),MPI_BYTE,n->rank_0_0_p1,0,n->mpi_world,&send_req_0_0_p1);
MPI_Request recv_req_0_0_m1;
MPI_Irecv(recv_buf1_0_0_m1,sizeof(recv_buf1_0_0_m1),MPI_BYTE,n->rank_0_0_m1,0,n->mpi_world,&recv_req_0_0_m1);
for(int i1 = 0; i1 < 2; i1 += 1) {
for(int i2 = 0; i2 < 2; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
send_buf1_p1_p1_0[i1][i2][i3].q = formura_data.q[i1+126][i2+14][i3];
send_buf1_p1_p1_0[i1][i2][i3].r = formura_data.r[i1+126][i2+14][i3];
}
}
}

MPI_Request send_req_p1_p1_0;
MPI_Isend(send_buf1_p1_p1_0,sizeof(send_buf1_p1_p1_0),MPI_BYTE,n->rank_p1_p1_0,0,n->mpi_world,&send_req_p1_p1_0);
MPI_Request recv_req_m1_m1_0;
MPI_Irecv(recv_buf1_m1_m1_0,sizeof(recv_buf1_m1_m1_0),MPI_BYTE,n->rank_m1_m1_0,0,n->mpi_world,&recv_req_m1_m1_0);
for(int i1 = 0; i1 < 2; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 2; i3 += 1) {
send_buf1_p1_0_p1[i1][i2][i3].q = formura_data.q[i1+126][i2][i3+14];
send_buf1_p1_0_p1[i1][i2][i3].r = formura_data.r[i1+126][i2][i3+14];
}
}
}

MPI_Request send_req_p1_0_p1;
MPI_Isend(send_buf1_p1_0_p1,sizeof(send_buf1_p1_0_p1),MPI_BYTE,n->rank_p1_0_p1,0,n->mpi_world,&send_req_p1_0_p1);
MPI_Request recv_req_m1_0_m1;
MPI_Irecv(recv_buf1_m1_0_m1,sizeof(recv_buf1_m1_0_m1),MPI_BYTE,n->rank_m1_0_m1,0,n->mpi_world,&recv_req_m1_0_m1);
for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 2; i2 += 1) {
for(int i3 = 0; i3 < 2; i3 += 1) {
send_buf1_0_p1_p1[i1][i2][i3].q = formura_data.q[i1][i2+14][i3+14];
send_buf1_0_p1_p1[i1][i2][i3].r = formura_data.r[i1][i2+14][i3+14];
}
}
}

MPI_Request send_req_0_p1_p1;
MPI_Isend(send_buf1_0_p1_p1,sizeof(send_buf1_0_p1_p1),MPI_BYTE,n->rank_0_p1_p1,0,n->mpi_world,&send_req_0_p1_p1);
MPI_Request recv_req_0_m1_m1;
MPI_Irecv(recv_buf1_0_m1_m1,sizeof(recv_buf1_0_m1_m1),MPI_BYTE,n->rank_0_m1_m1,0,n->mpi_world,&recv_req_0_m1_m1);
for(int i1 = 0; i1 < 2; i1 += 1) {
for(int i2 = 0; i2 < 2; i2 += 1) {
for(int i3 = 0; i3 < 2; i3 += 1) {
send_buf1_p1_p1_p1[i1][i2][i3].q = formura_data.q[i1+126][i2+14][i3+14];
send_buf1_p1_p1_p1[i1][i2][i3].r = formura_data.r[i1+126][i2+14][i3+14];
}
}
}

MPI_Request send_req_p1_p1_p1;
MPI_Isend(send_buf1_p1_p1_p1,sizeof(send_buf1_p1_p1_p1),MPI_BYTE,n->rank_p1_p1_p1,0,n->mpi_world,&send_req_p1_p1_p1);
MPI_Request recv_req_m1_m1_m1;
MPI_Irecv(recv_buf1_m1_m1_m1,sizeof(recv_buf1_m1_m1_m1),MPI_BYTE,n->rank_m1_m1_m1,0,n->mpi_world,&recv_req_m1_m1_m1);
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
for(int i1 = 0; i1 < 2; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
buff.q[i1][i2+2][i3+2] = recv_buf1_m1_0_0[i1][i2][i3].q;
buff.r[i1][i2+2][i3+2] = recv_buf1_m1_0_0[i1][i2][i3].r;
}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 2; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
buff.q[i1+2][i2][i3+2] = recv_buf1_0_m1_0[i1][i2][i3].q;
buff.r[i1+2][i2][i3+2] = recv_buf1_0_m1_0[i1][i2][i3].r;
}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 2; i3 += 1) {
buff.q[i1+2][i2+2][i3] = recv_buf1_0_0_m1[i1][i2][i3].q;
buff.r[i1+2][i2+2][i3] = recv_buf1_0_0_m1[i1][i2][i3].r;
}
}
}

for(int i1 = 0; i1 < 2; i1 += 1) {
for(int i2 = 0; i2 < 2; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
buff.q[i1][i2][i3+2] = recv_buf1_m1_m1_0[i1][i2][i3].q;
buff.r[i1][i2][i3+2] = recv_buf1_m1_m1_0[i1][i2][i3].r;
}
}
}

for(int i1 = 0; i1 < 2; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 2; i3 += 1) {
buff.q[i1][i2+2][i3] = recv_buf1_m1_0_m1[i1][i2][i3].q;
buff.r[i1][i2+2][i3] = recv_buf1_m1_0_m1[i1][i2][i3].r;
}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 2; i2 += 1) {
for(int i3 = 0; i3 < 2; i3 += 1) {
buff.q[i1+2][i2][i3] = recv_buf1_0_m1_m1[i1][i2][i3].q;
buff.r[i1+2][i2][i3] = recv_buf1_0_m1_m1[i1][i2][i3].r;
}
}
}

for(int i1 = 0; i1 < 2; i1 += 1) {
for(int i2 = 0; i2 < 2; i2 += 1) {
for(int i3 = 0; i3 < 2; i3 += 1) {
buff.q[i1][i2][i3] = recv_buf1_m1_m1_m1[i1][i2][i3].q;
buff.r[i1][i2][i3] = recv_buf1_m1_m1_m1[i1][i2][i3].r;
}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
buff.q[i1+2][i2+2][i3+2] = formura_data.q[i1][i2][i3];
buff.r[i1+2][i2+2][i3+2] = formura_data.r[i1][i2][i3];
}
}
}

Formura_Step(&buff,&formura_data,*n,0,0,0);
n->offset_x = (n->offset_x - 1 + n->total_grid_x)%n->total_grid_x;
n->offset_y = (n->offset_y - 1 + n->total_grid_y)%n->total_grid_y;
n->offset_z = (n->offset_z - 1 + n->total_grid_z)%n->total_grid_z;
n->time_step += 1;
}
void Formura_Finalize() {
MPI_Finalize();
}
