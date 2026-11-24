#include "comm.h"
int main(void){
 int bsize=1024; double*buf=(double*)malloc0(2*bsize*sizeof(double));
 EMNR a=create_emnr(1,0,bsize,buf,buf,4096,4,48000,0,1.0,2,0,1);
 unsigned s=1;
 for(int b=0;b<20;b++){ for(int i=0;i<bsize;i++){ s=s*1103515245u+12345u; buf[2*i]=1e-3*(((s>>8)&0xffff)/32768.0-1.0); buf[2*i+1]=0;}
  xemnr(a,0); int nn=0,first=-1; for(int k=0;k<a->msize;k++) if(a->mask[k]!=a->mask[k]){nn++; if(first<0)first=k;}
  if(nn){ int k=first; printf("blk %d maskNaN=%d first=%d ly=%g ld=%g pg=%g pm=%g\n",b,nn,k,(double)a->g.lambda_y[k],(double)a->g.lambda_d[k],(double)a->g.prev_gamma[k],(double)a->g.prev_mask[k]); break;}}
 a->g.ae_run=0;
 return 0;}
