#pragma once
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <math.h>
#include <mpi.h>
#define Ns 2
#define L1 64
#define P1 1
typedef struct {
double q[64];
double r[64];
} Formura_Grid_Struct;
typedef struct {
int time_step;
int lower_x;
int upper_x;
double space_interval_x;
int my_rank;
MPI_Comm mpi_world;
int rank_p1;
int rank_m1;
int offset_x;
double length_x;
int total_grid_x;
} Formura_Navi;
extern Formura_Grid_Struct formura_data;
double to_pos_x(int,Formura_Navi);
void Formura_Init(int *,char ***,Formura_Navi *);
void Formura_Custom_Init(Formura_Navi *,MPI_Comm);
void Formura_Forward(Formura_Navi *);
void Formura_Finalize();
