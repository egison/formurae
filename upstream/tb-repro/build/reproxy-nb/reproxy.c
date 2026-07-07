#include "reproxy.h"
typedef struct {
double q[68];
double r[68];
} Formura_Buff;
typedef struct {
double q;
double r;
} Formura_Comm_Buff;
static Formura_Buff buff;
static Formura_Comm_Buff send_buf2_p1[4];
static Formura_Comm_Buff recv_buf2_m1[4];
Formura_Grid_Struct formura_data;
int Formura_Encode_rank(int p1) {
return (p1+1)%1;
}
void Formura_Decode_rank(int p,int * p1) {
*p1 = (int)p%1;
}
void Formura_Setup(Formura_Navi n,int block_offset_1) {
for(int i1 = 0; i1 < 64; i1 += 1) {
double a0 = 1.0e-3;
double a1 = i1+n.offset_x+block_offset_1;
double a2 = a0*a1;
double a3 = 64.0;
double a4 = a3-a1;
double a5 = a2*a4;
formura_data.q[i1] = a5;
}

for(int i1 = 0; i1 < 64; i1 += 1) {
double a0 = 2.0e-3;
double a1 = i1+n.offset_x+block_offset_1;
double a2 = a0*a1;
double a3 = 64.0;
double a4 = a3-a1;
double a5 = a2*a4;
formura_data.r[i1] = a5;
}

}
void Formura_Step(Formura_Buff * buff,Formura_Grid_Struct * rslt,Formura_Navi n,int block_offset_1) {
for(int i1 = 0; i1 < 64; i1 += 1) {
double a0 = buff->q[i1+2];
double a1 = 5.0e-2;
double a2 = buff->r[i1+3];
double a3 = 2.0;
double a4 = buff->r[i1+2];
double a5 = a3*a4;
double a6 = a2-a5;
double a7 = buff->r[i1+1];
double a8 = a6+a7;
double a9 = a1*a8;
double a10 = a0+a9;
rslt->q[i1] = a10;
}

for(int i1 = 0; i1 < 64; i1 += 1) {
double a0 = buff->r[i1+2];
double a1 = 5.0e-2;
double a2 = buff->q[i1+4];
double a3 = 2.0;
double a4 = buff->q[i1+2];
double a5 = a3*a4;
double a6 = a2-a5;
double a7 = buff->q[i1];
double a8 = a6+a7;
double a9 = a1*a8;
double a10 = a0+a9;
rslt->r[i1] = a10;
}

}
double to_pos_x(int i,Formura_Navi n) {
return n.space_interval_x*((i+n.offset_x)%n.total_grid_x);
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
int i1;
Formura_Decode_rank(rank,&i1);
n->time_step = 0;
n->lower_x = 0;
n->upper_x = 64;
n->space_interval_x = 1.5625e-2;
n->my_rank = rank;
n->mpi_world = cm;
n->rank_p1 = Formura_Encode_rank(i1+1);
n->rank_m1 = Formura_Encode_rank(i1-1);
n->offset_x = 64*i1;
n->length_x = 1.0;
n->total_grid_x = 64;
Formura_Setup(*n,0);
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
int i1;
Formura_Decode_rank(rank,&i1);
n->time_step = 0;
n->lower_x = 0;
n->upper_x = 64;
n->space_interval_x = 1.5625e-2;
n->my_rank = rank;
n->mpi_world = cm;
n->rank_p1 = Formura_Encode_rank(i1+1);
n->rank_m1 = Formura_Encode_rank(i1-1);
n->offset_x = 64*i1;
n->length_x = 1.0;
n->total_grid_x = 64;
Formura_Setup(*n,0);
}
void Formura_Forward(Formura_Navi * n) {
for(int i1 = 0; i1 < 4; i1 += 1) {
send_buf2_p1[i1].q = formura_data.q[i1+60];
send_buf2_p1[i1].r = formura_data.r[i1+60];
}

MPI_Request send_req_p1;
MPI_Isend(send_buf2_p1,sizeof(send_buf2_p1),MPI_BYTE,n->rank_p1,0,n->mpi_world,&send_req_p1);
MPI_Request recv_req_m1;
MPI_Irecv(recv_buf2_m1,sizeof(recv_buf2_m1),MPI_BYTE,n->rank_m1,0,n->mpi_world,&recv_req_m1);
MPI_Wait(&send_req_p1,MPI_STATUS_IGNORE);
MPI_Wait(&recv_req_m1,MPI_STATUS_IGNORE);
for(int i1 = 0; i1 < 4; i1 += 1) {
buff.q[i1] = recv_buf2_m1[i1].q;
buff.r[i1] = recv_buf2_m1[i1].r;
}

for(int i1 = 0; i1 < 64; i1 += 1) {
buff.q[i1+4] = formura_data.q[i1];
buff.r[i1+4] = formura_data.r[i1];
}

Formura_Step(&buff,&formura_data,*n,0);
n->offset_x = (n->offset_x - 2 + n->total_grid_x)%n->total_grid_x;
n->time_step += 1;
}
void Formura_Finalize() {
MPI_Finalize();
}
