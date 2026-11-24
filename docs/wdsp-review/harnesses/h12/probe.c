#include "comm.h"
int main(){ int S=64,NC=2048; double* in=calloc(2*S,8),*out=calloc(4*S,8);
 double* imp=fir_bandpass(NC,200,3000,48000,1,1,1.0/(2*S)); FIRCORE p=create_fircore(S,in,out,NC,0,16,imp);
 double fs[]={1000,-1000,5000,-5000};
 for(int q=0;q<4;q++){ flush_fircore(p); double pk=0; for(int b=0;b<200;b++){ for(int n=0;n<S;n++){int m=b*S+n; in[2*n]=cos(TWOPI*fs[q]*m/48000); in[2*n+1]=sin(TWOPI*fs[q]*m/48000);} xfircore(p); if(b>100) for(int n=0;n<S;n++){double a=hypot(out[2*n],out[2*n+1]); if(a>pk)pk=a;} } printf("f=%g gain=%g\n",fs[q],pk);} }
