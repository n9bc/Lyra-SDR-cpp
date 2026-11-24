#include "comm.h"
int main(void){
 int size=1024,nc=2048; double* buf=malloc0(size*sizeof(complex));
 double* imp = fir_bandpass(nc, 0.0, 3000.0, 48000.0, 0, 1, 1.0/(2*size));
 FIRCORE p = create_fircore(size, buf, buf, nc, 0, 16, imp);
 double fs[]={-2500,-1500,-500,500,1500,2500,6000};
 for(int t=0;t<7;t++){ flush_fircore(p); long n=0; double pw=0;
  for(int b=0;b<8;b++){ for(int i=0;i<size;i++,n++){double ph=TWOPI*fs[t]*n/48000.0; buf[2*i]=cos(ph); buf[2*i+1]=sin(ph);} xfircore(p);
   if(b==7){pw=0;for(int i=0;i<size;i++)pw+=buf[2*i]*buf[2*i]+buf[2*i+1]*buf[2*i+1];pw/=size;}}
  printf("f=%6.0f gain=%.2f dB\n",fs[t],10*log10(pw+1e-30)); }
}
