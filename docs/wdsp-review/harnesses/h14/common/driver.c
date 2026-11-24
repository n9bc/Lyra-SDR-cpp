/* h14 driver: two free-running clock domains feeding the REAL WDSP rmatch (+varsamp).
   args: insize outsize ringsize ppm_in ppm_out jitter_ms duration_s stall_t stall_ms seed csv [prop_ringmin prop_ringmax]
   Input callbacks every insize samples of a 48 kHz*(1+ppm_in) clock, output callbacks every
   outsize samples of 48 kHz*(1+ppm_out). Optional non-accumulating uniform jitter [0,jitter_ms]
   on each callback time (bursty delivery). Optional input stall: in-callbacks whose nominal
   time falls in [stall_t, stall_t+stall_ms) are dropped (samples lost). */
#include "comm.h"
#include <stdio.h>
static uint64_t rs;
static double urand(void){ rs ^= rs<<13; rs ^= rs>>7; rs ^= rs<<17; return (double)(rs>>11)*(1.0/9007199254740992.0);} 
int main(int argc, char** argv){
  if(argc<12){fprintf(stderr,"usage\n");return 1;}
  int insize=atoi(argv[1]), outsize=atoi(argv[2]), ringsize=atoi(argv[3]);
  double ppm_in=atof(argv[4]), ppm_out=atof(argv[5]), jit=atof(argv[6])*1e-3, dur=atof(argv[7]);
  double stall_t=atof(argv[8]), stall_d=atof(argv[9])*1e-3; rs=(uint64_t)atoll(argv[10])*2654435761ull+88172645463325252ull;
  const char* csv=argv[11];
  int pmin = argc>12?atoi(argv[12]):0, pmax=argc>13?atoi(argv[13]):0;
  double fin=48000.0*(1+ppm_in*1e-6), fout=48000.0*(1+ppm_out*1e-6);
  double var_true=(fout/48000.0)/(fin/48000.0);
  RMATCH a=(RMATCH)create_rmatchV(insize,outsize,48000,48000,ringsize,1.0);
  if(pmin>0) setRMatchPropRingMin(a,pmin);
  if(pmax>0) setRMatchPropRingMax(a,pmax);
  double* in=(double*)malloc0(insize*sizeof(complex)); double* out=(double*)malloc0(outsize*sizeof(complex));
  long kin=0,kout=0; double ph=0, w=TWOPI*1000.0/48000.0;
  double tin=jit*urand(), tout=jit*urand();
  FILE* f=fopen(csv,"w"); fprintf(f,"t,dev,var_ppm,uf,of\n");
  int nb=(int)(dur*10)+2; double* bsum=calloc(nb,8); int* bcnt=calloc(nb,4); double* bvar=calloc(nb,8);
  int* buf=calloc(nb,4); int* bof=calloc(nb,4);
  long uf_prev=0, of_prev=0;
  while(1){
    double t = tin<tout? tin: tout; if(t>=dur) break;
    if(tin<tout){
      double tn=(double)kin*insize/fin;
      int drop = (stall_d>0 && tn>=stall_t && tn<stall_t+stall_d);
      for(int i=0;i<insize;i++){ in[2*i]=0.5*cos(ph); in[2*i+1]=0.5*sin(ph); ph+=w; if(ph>TWOPI)ph-=TWOPI; }
      if(!drop) xrmatchIN(a,in);
      kin++; tin=(double)kin*insize/fin + jit*urand();
    } else {
      xrmatchOUT(a,out);
      int b=(int)(t*10); bsum[b]+= (double)(a->n_ring - a->rsize/2); bcnt[b]++;
      bvar[b]=(a->var/var_true-1.0)*1e6;
      buf[b]+= (int)(a->underflows-uf_prev); bof[b]+=(int)(a->overflows-of_prev); uf_prev=a->underflows; of_prev=a->overflows;
      kout++; tout=(double)kout*outsize/fout + jit*urand();
    }
  }
  for(int b=0;b<nb;b++) if(bcnt[b]) fprintf(f,"%.1f,%.2f,%.2f,%d,%d\n",b/10.0,bsum[b]/bcnt[b],bvar[b],buf[b],bof[b]);
  fclose(f);
  printf("insize=%d outsize=%d rsize=%d var_true_ppm=%.1f uf=%ld of=%ld\n",insize,outsize,a->rsize,(var_true-1)*1e6,a->underflows,a->overflows);
  return 0;
}
