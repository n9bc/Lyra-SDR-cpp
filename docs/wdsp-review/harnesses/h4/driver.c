/* Driver for NOB-II slew finding. Feeds strong off-DC carrier + impulses, measures
   gating splatter (residual = out - delayed clean input) in 2.4 kHz bands vs carrier. */
#include "comm.h"
#include <stdio.h>
#include <fftw3.h>
#include <stdint.h>
static uint64_t rs=0x9E3779B97F4A7C15ull;
static double urand(void){rs^=rs<<13;rs^=rs>>7;rs^=rs<<17;return (rs>>11)*(1.0/9007199254740992.0);}
int main(int argc,char**argv){
  double fs=192000, f0=atof(argv[1]), slew=atof(argv[2]); int tail=atoi(argv[3]);
  double dcoff = argc>4?atof(argv[4]):0.0; int mode = argc>5?atoi(argv[5]):0;
  double hang = argc>6?atof(argv[6]):0.0001, adv = argc>7?atof(argv[7]):0.0001;
  int bs=1024, nb=400, N=bs*nb; /* ~2.13 s */
  NOB a=create_nob(1,bs,0,0,fs,mode,slew,adv,slew,hang,0.025,0.020,20.0);
  int D=a->in_idx-a->out_idx;
  double *clean=calloc(2*N,8),*in=calloc(2*N,8),*out=calloc(2*N,8);
  for(int n=0;n<N;n++){double ph=2*PI*f0*n/fs; clean[2*n]=cos(ph)+dcoff; clean[2*n+1]=sin(ph);}
  memcpy(in,clean,16*(size_t)N);
  int nimp=0; double t=0.05*fs;
  while(t<N-200){ int k=(int)t; double ph=2*PI*urand(); double amp[4]={100,50,25,12};
    for(int j=0;j<(tail?4:1);j++){in[2*(k+j)]+=amp[j]*cos(ph); in[2*(k+j)+1]+=amp[j]*sin(ph);} nimp++;
    t+=fs/100.0*(0.8+0.4*urand()); }
  if(getenv("BURST")){ for(int r=0;r<8;r++){ int st=(int)((0.2+0.25*r)*fs); for(int k=st;k<st+(int)(0.040*fs);k+=30){double ph=2*PI*urand(); in[2*k]+=1000*cos(ph); in[2*k+1]+=1000*sin(ph);} } }
  for(int b=0;b<nb;b++){a->in=in+2*b*bs;a->out=out+2*b*bs;xnob(a);}
  /* analysis window: skip first 0.04 s */
  int s0=(int)(0.04*fs), L=N-s0-D; L&=~1;
  fftw_complex *x=fftw_malloc(sizeof(fftw_complex)*L),*X=fftw_malloc(sizeof(fftw_complex)*L);
  fftw_plan p=fftw_plan_dft_1d(L,x,X,FFTW_FORWARD,FFTW_ESTIMATE);
  double *Pr=malloc(8*L),*Pc=malloc(8*L);
  double maxr=0, rsum=0; long gated=0;
  for(int n=0;n<L;n++){int m=s0+n+D,c=s0+n; double w=0.5-0.5*cos(2*PI*n/L);
    double ri=out[2*m]-clean[2*c], rq=out[2*m+1]-clean[2*c+1];
    double rr=sqrt(ri*ri+rq*rq); if(rr>maxr)maxr=rr; if(rr>1e-9)gated++; rsum+=rr*rr;
    x[n][0]=w*ri;x[n][1]=w*rq;}
  fftw_execute(p); for(int k=0;k<L;k++)Pr[k]=X[k][0]*X[k][0]+X[k][1]*X[k][1];
  for(int n=0;n<L;n++){int c=s0+n; double w=0.5-0.5*cos(2*PI*n/L); x[n][0]=w*(clean[2*c]-dcoff);x[n][1]=w*clean[2*c+1];}
  fftw_execute(p); for(int k=0;k<L;k++)Pc[k]=X[k][0]*X[k][0]+X[k][1]*X[k][1];
  #define BAND(P,fc) ({double s_=0; for(int k_=(int)((fc-1200)/fs*L);k_<=(int)((fc+1200)/fs*L);k_++){int kk=((k_%L)+L)%L; s_+=P[kk];} s_;})
  double car=BAND(Pc,f0);
  int ov=0; (void)ov; printf("D=%d impulses=%d residual_rms=%.4e maxresid=%.3f gatedSamples=%ld adv_slew=%d hang_slew=%d\n",D,nimp,sqrt(rsum/L),maxr,gated,a->adv_slew_count,a->hang_slew_count);
  double offs[]={1000,2000,3000,5000,10000,15000,20000,30000,50000};
  for(int i=0;i<9;i++) printf("  splatter @ carrier%+6.0f Hz (2.4k band): %7.2f dBc\n",offs[i],10*log10(BAND(Pr,f0+offs[i])/car));
  printf("  DC band (0 Hz +-1.2k):                %7.2f dBc\n",10*log10(BAND(Pr,0)/car));
  return 0;}
