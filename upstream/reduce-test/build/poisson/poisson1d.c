#include "poisson1d.h"
typedef struct {
double d[66];
double q[66];
} Formura_Buff;
typedef struct {
double d;
double q;
} Formura_Comm_Buff;
static Formura_Buff buff;
static Formura_Comm_Buff send_buf1_p1[2];
static Formura_Comm_Buff recv_buf1_m1[2];
Formura_Grid_Struct formura_data;
int Formura_Encode_rank(int p1) {
return (p1+1)%1;
}
void Formura_Decode_rank(int p,int * p1) {
*p1 = (int)p%1;
}
void Formura_Setup(Formura_Navi n,int block_offset_1) {
for(int i1 = 0; i1 < 64; i1 += 1) {
double a0 = 0.0;
formura_data.q[i1] = a0;
}

for(int i1 = 0; i1 < 64; i1 += 1) {
double a0 = 1.0;
formura_data.d[i1] = a0;
}

}
void Formura_Step(Formura_Buff * buff,Formura_Grid_Struct * rslt,Formura_Navi n,int block_offset_1) {
for(int i1 = 0; i1 < 64; i1 += 1) {
double a0 = buff->q[i1+2];
double a1 = buff->q[i1];
double a2 = a0+a1;
double a3 = 1.0e-3;
double a4 = a2+a3;
double a5 = 2.0;
double a6 = a4/a5;
rslt->q[i1] = a6;
}

for(int i1 = 0; i1 < 64; i1 += 1) {
double a0 = buff->q[i1+2];
double a1 = buff->q[i1];
double a2 = a0+a1;
double a3 = 1.0e-3;
double a4 = a2+a3;
double a5 = 2.0;
double a6 = a4/a5;
double a7 = buff->q[i1+1];
double a8 = a6-a7;
rslt->d[i1] = a8;
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
n->reduce_res = 0.0;
n->reduce_tot = 0.0;
n->my_rank = rank;
n->mpi_world = cm;
n->rank_p1 = Formura_Encode_rank(i1+1);
n->rank_m1 = Formura_Encode_rank(i1-1);
n->offset_x = 64*i1;
n->length_x = 1.0;
n->total_grid_x = 64;
Formura_Setup(*n,0);
{
double acc = 0.0;
for (int i1 = n->lower_x; i1 < n->upper_x; i1++) {
acc = fmax(acc, fabs(formura_data.d[i1]));
}

MPI_Allreduce(MPI_IN_PLACE, &acc, 1, MPI_DOUBLE, MPI_MAX, n->mpi_world);

n->reduce_res = acc;
}
{
double acc = 0.0;
for (int i1 = n->lower_x; i1 < n->upper_x; i1++) {
acc = acc + formura_data.q[i1];
}

MPI_Allreduce(MPI_IN_PLACE, &acc, 1, MPI_DOUBLE, MPI_SUM, n->mpi_world);

n->reduce_tot = acc;
}
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
n->reduce_res = 0.0;
n->reduce_tot = 0.0;
n->my_rank = rank;
n->mpi_world = cm;
n->rank_p1 = Formura_Encode_rank(i1+1);
n->rank_m1 = Formura_Encode_rank(i1-1);
n->offset_x = 64*i1;
n->length_x = 1.0;
n->total_grid_x = 64;
Formura_Setup(*n,0);
{
double acc = 0.0;
for (int i1 = n->lower_x; i1 < n->upper_x; i1++) {
acc = fmax(acc, fabs(formura_data.d[i1]));
}

MPI_Allreduce(MPI_IN_PLACE, &acc, 1, MPI_DOUBLE, MPI_MAX, n->mpi_world);

n->reduce_res = acc;
}
{
double acc = 0.0;
for (int i1 = n->lower_x; i1 < n->upper_x; i1++) {
acc = acc + formura_data.q[i1];
}

MPI_Allreduce(MPI_IN_PLACE, &acc, 1, MPI_DOUBLE, MPI_SUM, n->mpi_world);

n->reduce_tot = acc;
}
}
void Formura_Forward(Formura_Navi * n) {
for(int i1 = 0; i1 < 64; i1 += 1) {
buff.d[i1+1] = formura_data.d[i1];
buff.q[i1+1] = formura_data.q[i1];
}

for(int g = 0; g < 1; g += 1) {
buff.d[g] = 0.0;
buff.q[g] = 0.0;
}

for(int g = 65; g < 66; g += 1) {
buff.d[g] = 0.0;
buff.q[g] = 0.0;
}

Formura_Step(&buff,&formura_data,*n,0);
{
double acc = 0.0;
for (int i1 = n->lower_x; i1 < n->upper_x; i1++) {
acc = fmax(acc, fabs(formura_data.d[i1]));
}

MPI_Allreduce(MPI_IN_PLACE, &acc, 1, MPI_DOUBLE, MPI_MAX, n->mpi_world);

n->reduce_res = acc;
}
{
double acc = 0.0;
for (int i1 = n->lower_x; i1 < n->upper_x; i1++) {
acc = acc + formura_data.q[i1];
}

MPI_Allreduce(MPI_IN_PLACE, &acc, 1, MPI_DOUBLE, MPI_SUM, n->mpi_world);

n->reduce_tot = acc;
}
n->time_step += 1;
}
void Formura_Finalize() {
MPI_Finalize();
}
