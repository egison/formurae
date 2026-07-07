#include "repro2.h"
typedef struct {
double q[12];
} Formura_Buff;
typedef struct {
double q[8];
} Formura_Rslt;
typedef struct {
double q[80];
} Formura_Tmp_Floor;
typedef struct {
double q[4][4];
} Formura_Tmp_Wall_1;
typedef struct {
double q;
} Formura_Comm_Buff;
static Formura_Buff buff;
static Formura_Rslt rslt;
static Formura_Tmp_Floor tmp_floor;
static Formura_Tmp_Wall_1 tmp_wall_1;
static Formura_Comm_Buff send_buf8_p1[16];
static Formura_Comm_Buff recv_buf8_m1[16];
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

}
void Formura_Step(Formura_Buff * buff,Formura_Rslt * rslt,Formura_Navi n,int block_offset_1) {
for(int i1 = 0; i1 < 8; i1 += 1) {
double a0 = buff->q[i1+2];
double a1 = 5.0e-2;
double a2 = buff->q[i1+4];
double a3 = 2.0;
double a4 = a3*a0;
double a5 = a2-a4;
double a6 = buff->q[i1];
double a7 = a5+a6;
double a8 = a1*a7;
double a9 = a0+a8;
rslt->q[i1] = a9;
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
for(int i1 = 0; i1 < 64; i1 += 1) {
tmp_floor.q[i1+16] = formura_data.q[i1];
}

for(int i1 = 0; i1 < 16; i1 += 1) {
send_buf8_p1[i1].q = formura_data.q[i1+48];
}

MPI_Request send_req_p1;
MPI_Isend(send_buf8_p1,sizeof(send_buf8_p1),MPI_BYTE,n->rank_p1,0,n->mpi_world,&send_req_p1);
MPI_Request recv_req_m1;
MPI_Irecv(recv_buf8_m1,sizeof(recv_buf8_m1),MPI_BYTE,n->rank_m1,0,n->mpi_world,&recv_req_m1);
for(int j1 = 0; j1 < 7; j1 += 1) {
for(int i1 = 0; i1 < 8; i1 += 1) {
rslt.q[i1] = tmp_floor.q[i1+72-8*j1];
}

for(int it = 0; it < 4; it += 1) {
for(int i1 = 0; i1 < 8; i1 += 1) {
buff.q[i1] = rslt.q[i1];
}

for(int i1 = 0; i1 < 4; i1 += 1) {
buff.q[i1+8] = tmp_wall_1.q[it][i1];
}

Formura_Step(&buff,&rslt,*n,+72-8*j1);
for(int i1 = 0; i1 < 4; i1 += 1) {
tmp_wall_1.q[it][i1] = buff.q[i1];
}

}

for(int i1 = 0; i1 < 8; i1 += 1) {
tmp_floor.q[i1+72-8*j1] = rslt.q[i1];
}

}

MPI_Wait(&send_req_p1,MPI_STATUS_IGNORE);
MPI_Wait(&recv_req_m1,MPI_STATUS_IGNORE);
for(int i1 = 0; i1 < 16; i1 += 1) {
tmp_floor.q[i1] = recv_buf8_m1[i1].q;
}

for(int j1 = 7; j1 < 10; j1 += 1) {
for(int i1 = 0; i1 < 8; i1 += 1) {
rslt.q[i1] = tmp_floor.q[i1+72-8*j1];
}

for(int it = 0; it < 4; it += 1) {
for(int i1 = 0; i1 < 8; i1 += 1) {
buff.q[i1] = rslt.q[i1];
}

for(int i1 = 0; i1 < 4; i1 += 1) {
buff.q[i1+8] = tmp_wall_1.q[it][i1];
}

Formura_Step(&buff,&rslt,*n,+72-8*j1);
for(int i1 = 0; i1 < 4; i1 += 1) {
tmp_wall_1.q[it][i1] = buff.q[i1];
}

}

for(int i1 = 0; i1 < 8; i1 += 1) {
tmp_floor.q[i1+72-8*j1] = rslt.q[i1];
}

}

for(int i1 = 0; i1 < 64; i1 += 1) {
formura_data.q[i1] = tmp_floor.q[i1];
}

n->offset_x = (n->offset_x - 8 + n->total_grid_x)%n->total_grid_x;
n->time_step += 4;
}
void Formura_Finalize() {
MPI_Finalize();
}
