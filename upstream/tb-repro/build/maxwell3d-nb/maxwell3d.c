#include "maxwell3d.h"
typedef struct {
double Bx[132][20][20];
double By[132][20][20];
double Bz[132][20][20];
double Ex[132][20][20];
double Ey[132][20][20];
double Ez[132][20][20];
} Formura_Buff;
typedef struct {
double Bx;
double By;
double Bz;
double Ex;
double Ey;
double Ez;
} Formura_Comm_Buff;
static Formura_Buff buff;
static Formura_Comm_Buff send_buf2_p1_0_0[4][16][16];
static Formura_Comm_Buff recv_buf2_m1_0_0[4][16][16];
static Formura_Comm_Buff send_buf2_0_p1_0[128][4][16];
static Formura_Comm_Buff recv_buf2_0_m1_0[128][4][16];
static Formura_Comm_Buff send_buf2_0_0_p1[128][16][4];
static Formura_Comm_Buff recv_buf2_0_0_m1[128][16][4];
static Formura_Comm_Buff send_buf2_p1_p1_0[4][4][16];
static Formura_Comm_Buff recv_buf2_m1_m1_0[4][4][16];
static Formura_Comm_Buff send_buf2_p1_0_p1[4][16][4];
static Formura_Comm_Buff recv_buf2_m1_0_m1[4][16][4];
static Formura_Comm_Buff send_buf2_0_p1_p1[128][4][4];
static Formura_Comm_Buff recv_buf2_0_m1_m1[128][4][4];
static Formura_Comm_Buff send_buf2_p1_p1_p1[4][4][4];
static Formura_Comm_Buff recv_buf2_m1_m1_m1[4][4][4];
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
void Formura_Step(Formura_Buff * buff,Formura_Grid_Struct * rslt,Formura_Navi n,int block_offset_1,int block_offset_2,int block_offset_3) {
for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
double a0 = buff->Ex[i1+2][i2+2][i3+2];
double a1 = 1.0;
double a2 = -a1;
double a3 = buff->Bz[i1+2][i2+1][i3+2];
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
double a14 = buff->Bz[i1+2][i2+3][i3+2];
double a15 = a14*a7;
double a16 = 2.0;
double a17 = a16*a10;
double a18 = a15/a17;
double a19 = a13+a18;
double a20 = buff->By[i1+2][i2+2][i3+1];
double a21 = a20*a7;
double a22 = 2.0;
double a23 = 7.8125e-3;
double a24 = a22*a23;
double a25 = a21/a24;
double a26 = a19+a25;
double a27 = 1.0;
double a28 = -a27;
double a29 = buff->By[i1+2][i2+2][i3+3];
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

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
double a0 = buff->Ey[i1+2][i2+2][i3+2];
double a1 = buff->Bz[i1+1][i2+2][i3+2];
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
double a12 = buff->Bz[i1+3][i2+2][i3+2];
double a13 = a11*a12;
double a14 = a13*a4;
double a15 = 2.0;
double a16 = a15*a3;
double a17 = a14/a16;
double a18 = a9+a17;
double a19 = 1.0;
double a20 = -a19;
double a21 = buff->Bx[i1+2][i2+2][i3+1];
double a22 = a20*a21;
double a23 = a22*a4;
double a24 = 2.0;
double a25 = 7.8125e-3;
double a26 = a24*a25;
double a27 = a23/a26;
double a28 = a18+a27;
double a29 = buff->Bx[i1+2][i2+2][i3+3];
double a30 = a29*a4;
double a31 = 2.0;
double a32 = a31*a25;
double a33 = a30/a32;
double a34 = a28+a33;
rslt->Ey[i1][i2][i3] = a34;
}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
double a0 = buff->Ez[i1+2][i2+2][i3+2];
double a1 = 1.0;
double a2 = -a1;
double a3 = buff->By[i1+1][i2+2][i3+2];
double a4 = a2*a3;
double a5 = 0.1;
double a6 = 7.8125e-3;
double a7 = a5*a6;
double a8 = a4*a7;
double a9 = 2.0;
double a10 = a9*a6;
double a11 = a8/a10;
double a12 = a0+a11;
double a13 = buff->By[i1+3][i2+2][i3+2];
double a14 = a13*a7;
double a15 = 2.0;
double a16 = a15*a6;
double a17 = a14/a16;
double a18 = a12+a17;
double a19 = buff->Bx[i1+2][i2+1][i3+2];
double a20 = a19*a7;
double a21 = 2.0;
double a22 = 7.8125e-3;
double a23 = a21*a22;
double a24 = a20/a23;
double a25 = a18+a24;
double a26 = 1.0;
double a27 = -a26;
double a28 = buff->Bx[i1+2][i2+3][i3+2];
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

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
double a0 = buff->Ez[i1+2][i2+1][i3+2];
double a1 = 0.1;
double a2 = 7.8125e-3;
double a3 = a1*a2;
double a4 = a0*a3;
double a5 = 2.0;
double a6 = 7.8125e-3;
double a7 = a5*a6;
double a8 = a4/a7;
double a9 = 1.0;
double a10 = -a9;
double a11 = buff->Ez[i1+2][i2+3][i3+2];
double a12 = a10*a11;
double a13 = a12*a3;
double a14 = 2.0;
double a15 = a14*a6;
double a16 = a13/a15;
double a17 = a8+a16;
double a18 = 1.0;
double a19 = -a18;
double a20 = buff->Ey[i1+2][i2+2][i3+1];
double a21 = a19*a20;
double a22 = a21*a3;
double a23 = 2.0;
double a24 = 7.8125e-3;
double a25 = a23*a24;
double a26 = a22/a25;
double a27 = a17+a26;
double a28 = buff->Ey[i1+2][i2+2][i3+3];
double a29 = a28*a3;
double a30 = 2.0;
double a31 = a30*a24;
double a32 = a29/a31;
double a33 = a27+a32;
double a34 = 1.0;
double a35 = -a34;
double a36 = buff->Bz[i1+1][i2+2][i3+1];
double a37 = a35*a36;
double a38 = 2.0;
double a39 = pow(a3,a38);
double a40 = a37*a39;
double a41 = 4.0;
double a42 = a41*a2;
double a43 = a42*a24;
double a44 = a40/a43;
double a45 = a33+a44;
double a46 = buff->Bz[i1+1][i2+2][i3+3];
double a47 = 2.0;
double a48 = pow(a3,a47);
double a49 = a46*a48;
double a50 = 4.0;
double a51 = a50*a2;
double a52 = a51*a24;
double a53 = a49/a52;
double a54 = a45+a53;
double a55 = buff->Bz[i1+3][i2+2][i3+1];
double a56 = 2.0;
double a57 = pow(a3,a56);
double a58 = a55*a57;
double a59 = 4.0;
double a60 = a59*a2;
double a61 = a60*a24;
double a62 = a58/a61;
double a63 = a54+a62;
double a64 = 1.0;
double a65 = -a64;
double a66 = buff->Bz[i1+3][i2+2][i3+3];
double a67 = a65*a66;
double a68 = 2.0;
double a69 = pow(a3,a68);
double a70 = a67*a69;
double a71 = 4.0;
double a72 = a71*a2;
double a73 = a72*a24;
double a74 = a70/a73;
double a75 = a63+a74;
double a76 = 1.0;
double a77 = -a76;
double a78 = buff->By[i1+1][i2+1][i3+2];
double a79 = a77*a78;
double a80 = 2.0;
double a81 = pow(a3,a80);
double a82 = a79*a81;
double a83 = 4.0;
double a84 = a83*a2;
double a85 = a84*a6;
double a86 = a82/a85;
double a87 = a75+a86;
double a88 = buff->By[i1+1][i2+3][i3+2];
double a89 = 2.0;
double a90 = pow(a3,a89);
double a91 = a88*a90;
double a92 = 4.0;
double a93 = a92*a2;
double a94 = a93*a6;
double a95 = a91/a94;
double a96 = a87+a95;
double a97 = buff->By[i1+3][i2+1][i3+2];
double a98 = 2.0;
double a99 = pow(a3,a98);
double a100 = a97*a99;
double a101 = 4.0;
double a102 = a101*a2;
double a103 = a102*a6;
double a104 = a100/a103;
double a105 = a96+a104;
double a106 = 1.0;
double a107 = -a106;
double a108 = buff->By[i1+3][i2+3][i3+2];
double a109 = a107*a108;
double a110 = 2.0;
double a111 = pow(a3,a110);
double a112 = a109*a111;
double a113 = 4.0;
double a114 = a113*a2;
double a115 = a114*a6;
double a116 = a112/a115;
double a117 = a105+a116;
double a118 = 1.0;
double a119 = -a118;
double a120 = buff->Bx[i1+2][i2+2][i3+2];
double a121 = a119*a120;
double a122 = 2.0;
double a123 = pow(a3,a122);
double a124 = a121*a123;
double a125 = 2.0;
double a126 = 2.0;
double a127 = pow(a24,a126);
double a128 = a125*a127;
double a129 = a124/a128;
double a130 = a117+a129;
double a131 = 1.0;
double a132 = -a131;
double a133 = a132*a120;
double a134 = 2.0;
double a135 = pow(a3,a134);
double a136 = a133*a135;
double a137 = 2.0;
double a138 = 2.0;
double a139 = pow(a6,a138);
double a140 = a137*a139;
double a141 = a136/a140;
double a142 = a130+a141;
double a143 = a142+a120;
double a144 = buff->Bx[i1+2][i2+2][i3];
double a145 = 2.0;
double a146 = pow(a3,a145);
double a147 = a144*a146;
double a148 = 4.0;
double a149 = 2.0;
double a150 = pow(a24,a149);
double a151 = a148*a150;
double a152 = a147/a151;
double a153 = a143+a152;
double a154 = buff->Bx[i1+2][i2+2][i3+4];
double a155 = 2.0;
double a156 = pow(a3,a155);
double a157 = a154*a156;
double a158 = 4.0;
double a159 = 2.0;
double a160 = pow(a24,a159);
double a161 = a158*a160;
double a162 = a157/a161;
double a163 = a153+a162;
double a164 = buff->Bx[i1+2][i2][i3+2];
double a165 = 2.0;
double a166 = pow(a3,a165);
double a167 = a164*a166;
double a168 = 4.0;
double a169 = 2.0;
double a170 = pow(a6,a169);
double a171 = a168*a170;
double a172 = a167/a171;
double a173 = a163+a172;
double a174 = buff->Bx[i1+2][i2+4][i3+2];
double a175 = 2.0;
double a176 = pow(a3,a175);
double a177 = a174*a176;
double a178 = 4.0;
double a179 = 2.0;
double a180 = pow(a6,a179);
double a181 = a178*a180;
double a182 = a177/a181;
double a183 = a173+a182;
rslt->Bx[i1][i2][i3] = a183;
}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
double a0 = 1.0;
double a1 = -a0;
double a2 = buff->Ez[i1+1][i2+2][i3+2];
double a3 = a1*a2;
double a4 = 0.1;
double a5 = 7.8125e-3;
double a6 = a4*a5;
double a7 = a3*a6;
double a8 = 2.0;
double a9 = a8*a5;
double a10 = a7/a9;
double a11 = buff->Ez[i1+3][i2+2][i3+2];
double a12 = a11*a6;
double a13 = 2.0;
double a14 = a13*a5;
double a15 = a12/a14;
double a16 = a10+a15;
double a17 = buff->Ex[i1+2][i2+2][i3+1];
double a18 = a17*a6;
double a19 = 2.0;
double a20 = 7.8125e-3;
double a21 = a19*a20;
double a22 = a18/a21;
double a23 = a16+a22;
double a24 = 1.0;
double a25 = -a24;
double a26 = buff->Ex[i1+2][i2+2][i3+3];
double a27 = a25*a26;
double a28 = a27*a6;
double a29 = 2.0;
double a30 = a29*a20;
double a31 = a28/a30;
double a32 = a23+a31;
double a33 = 1.0;
double a34 = -a33;
double a35 = buff->Bz[i1+2][i2+1][i3+1];
double a36 = a34*a35;
double a37 = 2.0;
double a38 = pow(a6,a37);
double a39 = a36*a38;
double a40 = 4.0;
double a41 = 7.8125e-3;
double a42 = a40*a41;
double a43 = a42*a20;
double a44 = a39/a43;
double a45 = a32+a44;
double a46 = buff->Bz[i1+2][i2+1][i3+3];
double a47 = 2.0;
double a48 = pow(a6,a47);
double a49 = a46*a48;
double a50 = 4.0;
double a51 = a50*a41;
double a52 = a51*a20;
double a53 = a49/a52;
double a54 = a45+a53;
double a55 = buff->Bz[i1+2][i2+3][i3+1];
double a56 = 2.0;
double a57 = pow(a6,a56);
double a58 = a55*a57;
double a59 = 4.0;
double a60 = a59*a41;
double a61 = a60*a20;
double a62 = a58/a61;
double a63 = a54+a62;
double a64 = 1.0;
double a65 = -a64;
double a66 = buff->Bz[i1+2][i2+3][i3+3];
double a67 = a65*a66;
double a68 = 2.0;
double a69 = pow(a6,a68);
double a70 = a67*a69;
double a71 = 4.0;
double a72 = a71*a41;
double a73 = a72*a20;
double a74 = a70/a73;
double a75 = a63+a74;
double a76 = 1.0;
double a77 = -a76;
double a78 = buff->By[i1+2][i2+2][i3+2];
double a79 = a77*a78;
double a80 = 2.0;
double a81 = pow(a6,a80);
double a82 = a79*a81;
double a83 = 2.0;
double a84 = 2.0;
double a85 = pow(a20,a84);
double a86 = a83*a85;
double a87 = a82/a86;
double a88 = a75+a87;
double a89 = 1.0;
double a90 = -a89;
double a91 = a90*a78;
double a92 = 2.0;
double a93 = pow(a6,a92);
double a94 = a91*a93;
double a95 = 2.0;
double a96 = 2.0;
double a97 = pow(a5,a96);
double a98 = a95*a97;
double a99 = a94/a98;
double a100 = a88+a99;
double a101 = a100+a78;
double a102 = buff->By[i1+2][i2+2][i3];
double a103 = 2.0;
double a104 = pow(a6,a103);
double a105 = a102*a104;
double a106 = 4.0;
double a107 = 2.0;
double a108 = pow(a20,a107);
double a109 = a106*a108;
double a110 = a105/a109;
double a111 = a101+a110;
double a112 = buff->By[i1+2][i2+2][i3+4];
double a113 = 2.0;
double a114 = pow(a6,a113);
double a115 = a112*a114;
double a116 = 4.0;
double a117 = 2.0;
double a118 = pow(a20,a117);
double a119 = a116*a118;
double a120 = a115/a119;
double a121 = a111+a120;
double a122 = buff->By[i1][i2+2][i3+2];
double a123 = 2.0;
double a124 = pow(a6,a123);
double a125 = a122*a124;
double a126 = 4.0;
double a127 = 2.0;
double a128 = pow(a5,a127);
double a129 = a126*a128;
double a130 = a125/a129;
double a131 = a121+a130;
double a132 = buff->By[i1+4][i2+2][i3+2];
double a133 = 2.0;
double a134 = pow(a6,a133);
double a135 = a132*a134;
double a136 = 4.0;
double a137 = 2.0;
double a138 = pow(a5,a137);
double a139 = a136*a138;
double a140 = a135/a139;
double a141 = a131+a140;
double a142 = 1.0;
double a143 = -a142;
double a144 = buff->Bx[i1+1][i2+1][i3+2];
double a145 = a143*a144;
double a146 = 2.0;
double a147 = pow(a6,a146);
double a148 = a145*a147;
double a149 = 4.0;
double a150 = a149*a5;
double a151 = a150*a41;
double a152 = a148/a151;
double a153 = a141+a152;
double a154 = buff->Bx[i1+1][i2+3][i3+2];
double a155 = 2.0;
double a156 = pow(a6,a155);
double a157 = a154*a156;
double a158 = 4.0;
double a159 = a158*a5;
double a160 = a159*a41;
double a161 = a157/a160;
double a162 = a153+a161;
double a163 = buff->Bx[i1+3][i2+1][i3+2];
double a164 = 2.0;
double a165 = pow(a6,a164);
double a166 = a163*a165;
double a167 = 4.0;
double a168 = a167*a5;
double a169 = a168*a41;
double a170 = a166/a169;
double a171 = a162+a170;
double a172 = 1.0;
double a173 = -a172;
double a174 = buff->Bx[i1+3][i2+3][i3+2];
double a175 = a173*a174;
double a176 = 2.0;
double a177 = pow(a6,a176);
double a178 = a175*a177;
double a179 = 4.0;
double a180 = a179*a5;
double a181 = a180*a41;
double a182 = a178/a181;
double a183 = a171+a182;
rslt->By[i1][i2][i3] = a183;
}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
double a0 = buff->Ey[i1+1][i2+2][i3+2];
double a1 = 0.1;
double a2 = 7.8125e-3;
double a3 = a1*a2;
double a4 = a0*a3;
double a5 = 2.0;
double a6 = a5*a2;
double a7 = a4/a6;
double a8 = 1.0;
double a9 = -a8;
double a10 = buff->Ey[i1+3][i2+2][i3+2];
double a11 = a9*a10;
double a12 = a11*a3;
double a13 = 2.0;
double a14 = a13*a2;
double a15 = a12/a14;
double a16 = a7+a15;
double a17 = 1.0;
double a18 = -a17;
double a19 = buff->Ex[i1+2][i2+1][i3+2];
double a20 = a18*a19;
double a21 = a20*a3;
double a22 = 2.0;
double a23 = 7.8125e-3;
double a24 = a22*a23;
double a25 = a21/a24;
double a26 = a16+a25;
double a27 = buff->Ex[i1+2][i2+3][i3+2];
double a28 = a27*a3;
double a29 = 2.0;
double a30 = a29*a23;
double a31 = a28/a30;
double a32 = a26+a31;
double a33 = 1.0;
double a34 = -a33;
double a35 = buff->Bz[i1+2][i2+2][i3+2];
double a36 = a34*a35;
double a37 = 2.0;
double a38 = pow(a3,a37);
double a39 = a36*a38;
double a40 = 2.0;
double a41 = 2.0;
double a42 = pow(a23,a41);
double a43 = a40*a42;
double a44 = a39/a43;
double a45 = a32+a44;
double a46 = 1.0;
double a47 = -a46;
double a48 = a47*a35;
double a49 = 2.0;
double a50 = pow(a3,a49);
double a51 = a48*a50;
double a52 = 2.0;
double a53 = 2.0;
double a54 = pow(a2,a53);
double a55 = a52*a54;
double a56 = a51/a55;
double a57 = a45+a56;
double a58 = a57+a35;
double a59 = buff->Bz[i1+2][i2][i3+2];
double a60 = 2.0;
double a61 = pow(a3,a60);
double a62 = a59*a61;
double a63 = 4.0;
double a64 = 2.0;
double a65 = pow(a23,a64);
double a66 = a63*a65;
double a67 = a62/a66;
double a68 = a58+a67;
double a69 = buff->Bz[i1+2][i2+4][i3+2];
double a70 = 2.0;
double a71 = pow(a3,a70);
double a72 = a69*a71;
double a73 = 4.0;
double a74 = 2.0;
double a75 = pow(a23,a74);
double a76 = a73*a75;
double a77 = a72/a76;
double a78 = a68+a77;
double a79 = buff->Bz[i1][i2+2][i3+2];
double a80 = 2.0;
double a81 = pow(a3,a80);
double a82 = a79*a81;
double a83 = 4.0;
double a84 = 2.0;
double a85 = pow(a2,a84);
double a86 = a83*a85;
double a87 = a82/a86;
double a88 = a78+a87;
double a89 = buff->Bz[i1+4][i2+2][i3+2];
double a90 = 2.0;
double a91 = pow(a3,a90);
double a92 = a89*a91;
double a93 = 4.0;
double a94 = 2.0;
double a95 = pow(a2,a94);
double a96 = a93*a95;
double a97 = a92/a96;
double a98 = a88+a97;
double a99 = 1.0;
double a100 = -a99;
double a101 = buff->By[i1+2][i2+1][i3+1];
double a102 = a100*a101;
double a103 = 2.0;
double a104 = pow(a3,a103);
double a105 = a102*a104;
double a106 = 4.0;
double a107 = a106*a23;
double a108 = 7.8125e-3;
double a109 = a107*a108;
double a110 = a105/a109;
double a111 = a98+a110;
double a112 = buff->By[i1+2][i2+1][i3+3];
double a113 = 2.0;
double a114 = pow(a3,a113);
double a115 = a112*a114;
double a116 = 4.0;
double a117 = a116*a23;
double a118 = a117*a108;
double a119 = a115/a118;
double a120 = a111+a119;
double a121 = buff->By[i1+2][i2+3][i3+1];
double a122 = 2.0;
double a123 = pow(a3,a122);
double a124 = a121*a123;
double a125 = 4.0;
double a126 = a125*a23;
double a127 = a126*a108;
double a128 = a124/a127;
double a129 = a120+a128;
double a130 = 1.0;
double a131 = -a130;
double a132 = buff->By[i1+2][i2+3][i3+3];
double a133 = a131*a132;
double a134 = 2.0;
double a135 = pow(a3,a134);
double a136 = a133*a135;
double a137 = 4.0;
double a138 = a137*a23;
double a139 = a138*a108;
double a140 = a136/a139;
double a141 = a129+a140;
double a142 = 1.0;
double a143 = -a142;
double a144 = buff->Bx[i1+1][i2+2][i3+1];
double a145 = a143*a144;
double a146 = 2.0;
double a147 = pow(a3,a146);
double a148 = a145*a147;
double a149 = 4.0;
double a150 = a149*a2;
double a151 = a150*a108;
double a152 = a148/a151;
double a153 = a141+a152;
double a154 = buff->Bx[i1+1][i2+2][i3+3];
double a155 = 2.0;
double a156 = pow(a3,a155);
double a157 = a154*a156;
double a158 = 4.0;
double a159 = a158*a2;
double a160 = a159*a108;
double a161 = a157/a160;
double a162 = a153+a161;
double a163 = buff->Bx[i1+3][i2+2][i3+1];
double a164 = 2.0;
double a165 = pow(a3,a164);
double a166 = a163*a165;
double a167 = 4.0;
double a168 = a167*a2;
double a169 = a168*a108;
double a170 = a166/a169;
double a171 = a162+a170;
double a172 = 1.0;
double a173 = -a172;
double a174 = buff->Bx[i1+3][i2+2][i3+3];
double a175 = a173*a174;
double a176 = 2.0;
double a177 = pow(a3,a176);
double a178 = a175*a177;
double a179 = 4.0;
double a180 = a179*a2;
double a181 = a180*a108;
double a182 = a178/a181;
double a183 = a171+a182;
rslt->Bz[i1][i2][i3] = a183;
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
for(int i1 = 0; i1 < 4; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
send_buf2_p1_0_0[i1][i2][i3].Bx = formura_data.Bx[i1+124][i2][i3];
send_buf2_p1_0_0[i1][i2][i3].By = formura_data.By[i1+124][i2][i3];
send_buf2_p1_0_0[i1][i2][i3].Bz = formura_data.Bz[i1+124][i2][i3];
send_buf2_p1_0_0[i1][i2][i3].Ex = formura_data.Ex[i1+124][i2][i3];
send_buf2_p1_0_0[i1][i2][i3].Ey = formura_data.Ey[i1+124][i2][i3];
send_buf2_p1_0_0[i1][i2][i3].Ez = formura_data.Ez[i1+124][i2][i3];
}
}
}

MPI_Request send_req_p1_0_0;
MPI_Isend(send_buf2_p1_0_0,sizeof(send_buf2_p1_0_0),MPI_BYTE,n->rank_p1_0_0,0,n->mpi_world,&send_req_p1_0_0);
MPI_Request recv_req_m1_0_0;
MPI_Irecv(recv_buf2_m1_0_0,sizeof(recv_buf2_m1_0_0),MPI_BYTE,n->rank_m1_0_0,0,n->mpi_world,&recv_req_m1_0_0);
for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 4; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
send_buf2_0_p1_0[i1][i2][i3].Bx = formura_data.Bx[i1][i2+12][i3];
send_buf2_0_p1_0[i1][i2][i3].By = formura_data.By[i1][i2+12][i3];
send_buf2_0_p1_0[i1][i2][i3].Bz = formura_data.Bz[i1][i2+12][i3];
send_buf2_0_p1_0[i1][i2][i3].Ex = formura_data.Ex[i1][i2+12][i3];
send_buf2_0_p1_0[i1][i2][i3].Ey = formura_data.Ey[i1][i2+12][i3];
send_buf2_0_p1_0[i1][i2][i3].Ez = formura_data.Ez[i1][i2+12][i3];
}
}
}

MPI_Request send_req_0_p1_0;
MPI_Isend(send_buf2_0_p1_0,sizeof(send_buf2_0_p1_0),MPI_BYTE,n->rank_0_p1_0,0,n->mpi_world,&send_req_0_p1_0);
MPI_Request recv_req_0_m1_0;
MPI_Irecv(recv_buf2_0_m1_0,sizeof(recv_buf2_0_m1_0),MPI_BYTE,n->rank_0_m1_0,0,n->mpi_world,&recv_req_0_m1_0);
for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 4; i3 += 1) {
send_buf2_0_0_p1[i1][i2][i3].Bx = formura_data.Bx[i1][i2][i3+12];
send_buf2_0_0_p1[i1][i2][i3].By = formura_data.By[i1][i2][i3+12];
send_buf2_0_0_p1[i1][i2][i3].Bz = formura_data.Bz[i1][i2][i3+12];
send_buf2_0_0_p1[i1][i2][i3].Ex = formura_data.Ex[i1][i2][i3+12];
send_buf2_0_0_p1[i1][i2][i3].Ey = formura_data.Ey[i1][i2][i3+12];
send_buf2_0_0_p1[i1][i2][i3].Ez = formura_data.Ez[i1][i2][i3+12];
}
}
}

MPI_Request send_req_0_0_p1;
MPI_Isend(send_buf2_0_0_p1,sizeof(send_buf2_0_0_p1),MPI_BYTE,n->rank_0_0_p1,0,n->mpi_world,&send_req_0_0_p1);
MPI_Request recv_req_0_0_m1;
MPI_Irecv(recv_buf2_0_0_m1,sizeof(recv_buf2_0_0_m1),MPI_BYTE,n->rank_0_0_m1,0,n->mpi_world,&recv_req_0_0_m1);
for(int i1 = 0; i1 < 4; i1 += 1) {
for(int i2 = 0; i2 < 4; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
send_buf2_p1_p1_0[i1][i2][i3].Bx = formura_data.Bx[i1+124][i2+12][i3];
send_buf2_p1_p1_0[i1][i2][i3].By = formura_data.By[i1+124][i2+12][i3];
send_buf2_p1_p1_0[i1][i2][i3].Bz = formura_data.Bz[i1+124][i2+12][i3];
send_buf2_p1_p1_0[i1][i2][i3].Ex = formura_data.Ex[i1+124][i2+12][i3];
send_buf2_p1_p1_0[i1][i2][i3].Ey = formura_data.Ey[i1+124][i2+12][i3];
send_buf2_p1_p1_0[i1][i2][i3].Ez = formura_data.Ez[i1+124][i2+12][i3];
}
}
}

MPI_Request send_req_p1_p1_0;
MPI_Isend(send_buf2_p1_p1_0,sizeof(send_buf2_p1_p1_0),MPI_BYTE,n->rank_p1_p1_0,0,n->mpi_world,&send_req_p1_p1_0);
MPI_Request recv_req_m1_m1_0;
MPI_Irecv(recv_buf2_m1_m1_0,sizeof(recv_buf2_m1_m1_0),MPI_BYTE,n->rank_m1_m1_0,0,n->mpi_world,&recv_req_m1_m1_0);
for(int i1 = 0; i1 < 4; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 4; i3 += 1) {
send_buf2_p1_0_p1[i1][i2][i3].Bx = formura_data.Bx[i1+124][i2][i3+12];
send_buf2_p1_0_p1[i1][i2][i3].By = formura_data.By[i1+124][i2][i3+12];
send_buf2_p1_0_p1[i1][i2][i3].Bz = formura_data.Bz[i1+124][i2][i3+12];
send_buf2_p1_0_p1[i1][i2][i3].Ex = formura_data.Ex[i1+124][i2][i3+12];
send_buf2_p1_0_p1[i1][i2][i3].Ey = formura_data.Ey[i1+124][i2][i3+12];
send_buf2_p1_0_p1[i1][i2][i3].Ez = formura_data.Ez[i1+124][i2][i3+12];
}
}
}

MPI_Request send_req_p1_0_p1;
MPI_Isend(send_buf2_p1_0_p1,sizeof(send_buf2_p1_0_p1),MPI_BYTE,n->rank_p1_0_p1,0,n->mpi_world,&send_req_p1_0_p1);
MPI_Request recv_req_m1_0_m1;
MPI_Irecv(recv_buf2_m1_0_m1,sizeof(recv_buf2_m1_0_m1),MPI_BYTE,n->rank_m1_0_m1,0,n->mpi_world,&recv_req_m1_0_m1);
for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 4; i2 += 1) {
for(int i3 = 0; i3 < 4; i3 += 1) {
send_buf2_0_p1_p1[i1][i2][i3].Bx = formura_data.Bx[i1][i2+12][i3+12];
send_buf2_0_p1_p1[i1][i2][i3].By = formura_data.By[i1][i2+12][i3+12];
send_buf2_0_p1_p1[i1][i2][i3].Bz = formura_data.Bz[i1][i2+12][i3+12];
send_buf2_0_p1_p1[i1][i2][i3].Ex = formura_data.Ex[i1][i2+12][i3+12];
send_buf2_0_p1_p1[i1][i2][i3].Ey = formura_data.Ey[i1][i2+12][i3+12];
send_buf2_0_p1_p1[i1][i2][i3].Ez = formura_data.Ez[i1][i2+12][i3+12];
}
}
}

MPI_Request send_req_0_p1_p1;
MPI_Isend(send_buf2_0_p1_p1,sizeof(send_buf2_0_p1_p1),MPI_BYTE,n->rank_0_p1_p1,0,n->mpi_world,&send_req_0_p1_p1);
MPI_Request recv_req_0_m1_m1;
MPI_Irecv(recv_buf2_0_m1_m1,sizeof(recv_buf2_0_m1_m1),MPI_BYTE,n->rank_0_m1_m1,0,n->mpi_world,&recv_req_0_m1_m1);
for(int i1 = 0; i1 < 4; i1 += 1) {
for(int i2 = 0; i2 < 4; i2 += 1) {
for(int i3 = 0; i3 < 4; i3 += 1) {
send_buf2_p1_p1_p1[i1][i2][i3].Bx = formura_data.Bx[i1+124][i2+12][i3+12];
send_buf2_p1_p1_p1[i1][i2][i3].By = formura_data.By[i1+124][i2+12][i3+12];
send_buf2_p1_p1_p1[i1][i2][i3].Bz = formura_data.Bz[i1+124][i2+12][i3+12];
send_buf2_p1_p1_p1[i1][i2][i3].Ex = formura_data.Ex[i1+124][i2+12][i3+12];
send_buf2_p1_p1_p1[i1][i2][i3].Ey = formura_data.Ey[i1+124][i2+12][i3+12];
send_buf2_p1_p1_p1[i1][i2][i3].Ez = formura_data.Ez[i1+124][i2+12][i3+12];
}
}
}

MPI_Request send_req_p1_p1_p1;
MPI_Isend(send_buf2_p1_p1_p1,sizeof(send_buf2_p1_p1_p1),MPI_BYTE,n->rank_p1_p1_p1,0,n->mpi_world,&send_req_p1_p1_p1);
MPI_Request recv_req_m1_m1_m1;
MPI_Irecv(recv_buf2_m1_m1_m1,sizeof(recv_buf2_m1_m1_m1),MPI_BYTE,n->rank_m1_m1_m1,0,n->mpi_world,&recv_req_m1_m1_m1);
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
for(int i1 = 0; i1 < 4; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
buff.Bx[i1][i2+4][i3+4] = recv_buf2_m1_0_0[i1][i2][i3].Bx;
buff.By[i1][i2+4][i3+4] = recv_buf2_m1_0_0[i1][i2][i3].By;
buff.Bz[i1][i2+4][i3+4] = recv_buf2_m1_0_0[i1][i2][i3].Bz;
buff.Ex[i1][i2+4][i3+4] = recv_buf2_m1_0_0[i1][i2][i3].Ex;
buff.Ey[i1][i2+4][i3+4] = recv_buf2_m1_0_0[i1][i2][i3].Ey;
buff.Ez[i1][i2+4][i3+4] = recv_buf2_m1_0_0[i1][i2][i3].Ez;
}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 4; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
buff.Bx[i1+4][i2][i3+4] = recv_buf2_0_m1_0[i1][i2][i3].Bx;
buff.By[i1+4][i2][i3+4] = recv_buf2_0_m1_0[i1][i2][i3].By;
buff.Bz[i1+4][i2][i3+4] = recv_buf2_0_m1_0[i1][i2][i3].Bz;
buff.Ex[i1+4][i2][i3+4] = recv_buf2_0_m1_0[i1][i2][i3].Ex;
buff.Ey[i1+4][i2][i3+4] = recv_buf2_0_m1_0[i1][i2][i3].Ey;
buff.Ez[i1+4][i2][i3+4] = recv_buf2_0_m1_0[i1][i2][i3].Ez;
}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 4; i3 += 1) {
buff.Bx[i1+4][i2+4][i3] = recv_buf2_0_0_m1[i1][i2][i3].Bx;
buff.By[i1+4][i2+4][i3] = recv_buf2_0_0_m1[i1][i2][i3].By;
buff.Bz[i1+4][i2+4][i3] = recv_buf2_0_0_m1[i1][i2][i3].Bz;
buff.Ex[i1+4][i2+4][i3] = recv_buf2_0_0_m1[i1][i2][i3].Ex;
buff.Ey[i1+4][i2+4][i3] = recv_buf2_0_0_m1[i1][i2][i3].Ey;
buff.Ez[i1+4][i2+4][i3] = recv_buf2_0_0_m1[i1][i2][i3].Ez;
}
}
}

for(int i1 = 0; i1 < 4; i1 += 1) {
for(int i2 = 0; i2 < 4; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
buff.Bx[i1][i2][i3+4] = recv_buf2_m1_m1_0[i1][i2][i3].Bx;
buff.By[i1][i2][i3+4] = recv_buf2_m1_m1_0[i1][i2][i3].By;
buff.Bz[i1][i2][i3+4] = recv_buf2_m1_m1_0[i1][i2][i3].Bz;
buff.Ex[i1][i2][i3+4] = recv_buf2_m1_m1_0[i1][i2][i3].Ex;
buff.Ey[i1][i2][i3+4] = recv_buf2_m1_m1_0[i1][i2][i3].Ey;
buff.Ez[i1][i2][i3+4] = recv_buf2_m1_m1_0[i1][i2][i3].Ez;
}
}
}

for(int i1 = 0; i1 < 4; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 4; i3 += 1) {
buff.Bx[i1][i2+4][i3] = recv_buf2_m1_0_m1[i1][i2][i3].Bx;
buff.By[i1][i2+4][i3] = recv_buf2_m1_0_m1[i1][i2][i3].By;
buff.Bz[i1][i2+4][i3] = recv_buf2_m1_0_m1[i1][i2][i3].Bz;
buff.Ex[i1][i2+4][i3] = recv_buf2_m1_0_m1[i1][i2][i3].Ex;
buff.Ey[i1][i2+4][i3] = recv_buf2_m1_0_m1[i1][i2][i3].Ey;
buff.Ez[i1][i2+4][i3] = recv_buf2_m1_0_m1[i1][i2][i3].Ez;
}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 4; i2 += 1) {
for(int i3 = 0; i3 < 4; i3 += 1) {
buff.Bx[i1+4][i2][i3] = recv_buf2_0_m1_m1[i1][i2][i3].Bx;
buff.By[i1+4][i2][i3] = recv_buf2_0_m1_m1[i1][i2][i3].By;
buff.Bz[i1+4][i2][i3] = recv_buf2_0_m1_m1[i1][i2][i3].Bz;
buff.Ex[i1+4][i2][i3] = recv_buf2_0_m1_m1[i1][i2][i3].Ex;
buff.Ey[i1+4][i2][i3] = recv_buf2_0_m1_m1[i1][i2][i3].Ey;
buff.Ez[i1+4][i2][i3] = recv_buf2_0_m1_m1[i1][i2][i3].Ez;
}
}
}

for(int i1 = 0; i1 < 4; i1 += 1) {
for(int i2 = 0; i2 < 4; i2 += 1) {
for(int i3 = 0; i3 < 4; i3 += 1) {
buff.Bx[i1][i2][i3] = recv_buf2_m1_m1_m1[i1][i2][i3].Bx;
buff.By[i1][i2][i3] = recv_buf2_m1_m1_m1[i1][i2][i3].By;
buff.Bz[i1][i2][i3] = recv_buf2_m1_m1_m1[i1][i2][i3].Bz;
buff.Ex[i1][i2][i3] = recv_buf2_m1_m1_m1[i1][i2][i3].Ex;
buff.Ey[i1][i2][i3] = recv_buf2_m1_m1_m1[i1][i2][i3].Ey;
buff.Ez[i1][i2][i3] = recv_buf2_m1_m1_m1[i1][i2][i3].Ez;
}
}
}

for(int i1 = 0; i1 < 128; i1 += 1) {
for(int i2 = 0; i2 < 16; i2 += 1) {
for(int i3 = 0; i3 < 16; i3 += 1) {
buff.Bx[i1+4][i2+4][i3+4] = formura_data.Bx[i1][i2][i3];
buff.By[i1+4][i2+4][i3+4] = formura_data.By[i1][i2][i3];
buff.Bz[i1+4][i2+4][i3+4] = formura_data.Bz[i1][i2][i3];
buff.Ex[i1+4][i2+4][i3+4] = formura_data.Ex[i1][i2][i3];
buff.Ey[i1+4][i2+4][i3+4] = formura_data.Ey[i1][i2][i3];
buff.Ez[i1+4][i2+4][i3+4] = formura_data.Ez[i1][i2][i3];
}
}
}

Formura_Step(&buff,&formura_data,*n,0,0,0);
n->offset_x = (n->offset_x - 2 + n->total_grid_x)%n->total_grid_x;
n->offset_y = (n->offset_y - 2 + n->total_grid_y)%n->total_grid_y;
n->offset_z = (n->offset_z - 2 + n->total_grid_z)%n->total_grid_z;
n->time_step += 1;
}
void Formura_Finalize() {
MPI_Finalize();
}
