#pragma once
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <math.h>
#include <mpi.h>
#define Ns 3
#define L1 33
#define L2 33
#define L3 64
#define P1 1
#define P2 1
#define P3 1
typedef struct {
double compression[33][33][64];
double energy[33][33][64];
double far[33][33][64];
double modified[33][33][64];
double pfront[33][33][64];
double pr[33][33][64];
double pw[33][33][64];
double sfront[33][33][64];
double shearing[33][33][64];
double sigma_up1_up1[33][33][64];
double sigma_up1_up2[33][33][64];
double sigma_up1_up3[33][33][64];
double sigma_up2_up2[33][33][64];
double sigma_up2_up3[33][33][64];
double sigma_up3_up3[33][33][64];
double sr[33][33][64];
double sw[33][33][64];
double v_up1[33][33][64];
double v_up2[33][33][64];
double v_up3[33][33][64];
} Formura_Grid_Struct;
typedef struct {
int time_step;
int lower_r;
int lower_theta;
int lower_phi;
int upper_r;
int upper_theta;
int upper_phi;
double space_interval_r;
double space_interval_theta;
double space_interval_phi;
double reduce_energy;
double reduce_modified;
double reduce_pw;
double reduce_pr;
double reduce_sw;
double reduce_sr;
double reduce_pfront;
double reduce_sfront;
double reduce_vmax;
int my_rank;
MPI_Comm mpi_world;
int rank_p1_0_0;
int rank_0_p1_0;
int rank_0_0_p1;
int rank_p1_p1_0;
int rank_p1_0_p1;
int rank_0_p1_p1;
int rank_p1_p1_p1;
int rank_m1_0_0;
int rank_0_m1_0;
int rank_0_0_m1;
int rank_m1_m1_0;
int rank_m1_0_m1;
int rank_0_m1_m1;
int rank_m1_m1_m1;
int rank_m1_m1_p1;
int rank_m1_0_p1;
int rank_m1_p1_m1;
int rank_m1_p1_0;
int rank_m1_p1_p1;
int rank_0_m1_p1;
int rank_0_p1_m1;
int rank_p1_m1_m1;
int rank_p1_m1_0;
int rank_p1_m1_p1;
int rank_p1_0_m1;
int rank_p1_p1_m1;
int offset_r;
int offset_theta;
int offset_phi;
double length_r;
double length_theta;
double length_phi;
int total_grid_r;
int total_grid_theta;
int total_grid_phi;
int pos_r;
int pos_theta;
int pos_phi;
} Formura_Navi;
extern Formura_Grid_Struct formura_data;
double to_pos_r(int,Formura_Navi);
double to_pos_theta(int,Formura_Navi);
double to_pos_phi(int,Formura_Navi);
void Formura_Init(int *,char ***,Formura_Navi *);
void Formura_Custom_Init(Formura_Navi *,MPI_Comm);
void Formura_Forward(Formura_Navi *);
void Formura_Finalize();
