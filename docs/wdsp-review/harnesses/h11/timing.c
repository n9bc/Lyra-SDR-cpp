#include "comm.h"
#include <time.h>
static double now(){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+1e-9*t.tv_nsec;}
int main(){ int Ns[]={1024,2048,4096}; 
 for(int u=0;u<2;u++){ init_impulse_cache(u);
  for(int n=0;n<3;n++){int N=Ns[n]; double* w=fir_bandpass(N,-3000,3000,48000,1,1,1.0/N); _aligned_free(w);
   double t0=now(); for(int i=0;i<2000;i++){double*p=fir_bandpass(N,-3000,3000,48000,1,1,1.0/N);_aligned_free(p);} 
   printf("cache=%d N=%d per_call=%.2f us\n",u,N,(now()-t0)/2000*1e6);} destroy_impulse_cache(); } }
