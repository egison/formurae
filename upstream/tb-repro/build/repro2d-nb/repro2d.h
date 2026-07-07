#pragma once
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <math.h>
#include <mpi.h>
#define Ns 2
#define L1 32
#define L2 32
#define P1 1
#define P2 1
typedef struct {
double q[32][32];
} Formura_Grid_Struct;
typedef struct {
int time_step;
int lower_x;
int lower_y;
int upper_x;
int upper_y;
double space_interval_x;
double space_interval_y;
int my_rank;
MPI_Comm mpi_world;
int rank_p1_0;
int rank_0_p1;
int rank_p1_p1;
int rank_m1_0;
int rank_0_m1;
int rank_m1_m1;
int offset_x;
int offset_y;
double length_x;
double length_y;
int total_grid_x;
int total_grid_y;
} Formura_Navi;
extern Formura_Grid_Struct formura_data;
double to_pos_x(int,Formura_Navi);
double to_pos_y(int,Formura_Navi);
void Formura_Init(int *,char ***,Formura_Navi *);
void Formura_Custom_Init(Formura_Navi *,MPI_Comm);
void Formura_Forward(Formura_Navi *);
void Formura_Finalize();
