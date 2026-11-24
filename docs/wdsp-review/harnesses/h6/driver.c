// Driver for finding 6: NOB-II latency and zero-mode blanking quality, orig vs fixed.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>
void create_nobEXT(int id,int run,int mode,int buffsize,double samplerate,double slewtime,double hangtime,double advtime,double backtau,double threshold);
void xnobEXT(int id,double*in,double*out);
void destroy_nobEXT(int id);

static uint64_t rs=88172645463325252ULL;
static double urand(void){ rs^=rs<<13; rs^=rs>>7; rs^=rs<<17; return (rs>>11)*(1.0/9007199254740992.0);}
static double gauss(void){ double u=urand()+1e-300,v=urand(); return sqrt(-2*log(u))*cos(2*M_PI*v);}

typedef struct { const char*name; } T;

static void run(const char*name,double fs,int bsize,int N,double*clean,double*in){
  double*out=calloc(2*N,sizeof(double));
  double*ib=malloc(2*bsize*sizeof(double)),*ob=malloc(2*bsize*sizeof(double));
  create_nobEXT(0,1,0,bsize,fs,0.0001,0.0001,0.0001,0.020,20.0);
  for(int b=0;b+bsize<=N;b+=bsize){ memcpy(ib,in+2*b,2*bsize*sizeof(double)); xnobEXT(0,ib,ob); memcpy(out+2*b,ob,2*bsize*sizeof(double)); }
  destroy_nobEXT(0);
  // delay: find d with out[n]==in[n-d] on impulse-free region => use clean ref in first 0.1 s (no impulses there)
  int best=-1; double be=1e300;
  for(int d=0; d<20000 && d<N/4; d++){ double e=0; int n0=(int)(0.03*fs)+d; for(int n=n0;n<n0+(int)(0.05*fs);n++){ double dr=out[2*n]-in[2*(n-d)], di=out[2*n+1]-in[2*(n-d)+1]; e+=dr*dr+di*di; if(e>be) break;} if(e<be){be=e;best=d;} }
  int d=best;
  // metrics over region after first 0.1 s
  int start=(int)(0.1*fs)+d; double sig=0, err=0, leak=0; long gated=0, leaksamps=0; double maxerr=0;
  for(int n=start;n<N;n++){ double rr=clean[2*(n-d)], ri=clean[2*(n-d)+1]; double orr=out[2*n], oi=out[2*n+1];
    double er=orr-rr, ei=oi-ri; double e2=er*er+ei*ei; sig+=rr*rr+ri*ri; err+=e2;
    double om=sqrt(orr*orr+oi*oi), rm=sqrt(rr*rr+ri*ri);
    if(om<0.5*rm) gated++;
    if(om>1.5*rm+0.1){ leak+=e2; leaksamps++; }
    if(sqrt(e2)>maxerr) maxerr=sqrt(e2); }
  printf("  %-28s delay=%5d samp (%.3f ms)  gated=%7ld samp  leak_samps=%5ld leak_E=%.4g  maxerr=%.3g  SER=%.2f dB\n",
     name,d,1000.0*d/fs,gated,leaksamps,leak,maxerr,10*log10(sig/(err+1e-300)));
  free(out); free(ib); free(ob);
}

// add impulse shaped like a filtered spike: damped ring
static void addimp(double*x,int N,int pos,double A,int len){ double ph=urand()*2*M_PI; for(int k=0;k<len && pos+k<N;k++){ double a=A*exp(-k/(0.35*len+0.5)); x[2*(pos+k)]+=a*cos(ph+1.3*k); x[2*(pos+k)+1]+=a*sin(ph+1.3*k);} }

int main(int argc,char**argv){
  double fs = argc>1? atof(argv[1]):48000; int bsize= argc>2? atoi(argv[2]):1024;
  int N = (int)(fs*4.0); N -= N%bsize;
  double*clean=malloc(2*N*sizeof(double)),*in=malloc(2*N*sizeof(double));
  const char* sc[]={"isolated impulses","bursts 10x @0.8ms","bursts 5x @4ms","long train 60ms @0.2ms","dense 1kHz-rate train"};
  for(int s=0;s<5;s++){
    rs=88172645463325252ULL+s;
    for(int n=0;n<N;n++){ double ph=2*M_PI*1000.0*n/fs; clean[2*n]=cos(ph)+0.02*gauss(); clean[2*n+1]=sin(ph)+0.02*gauss(); }
    memcpy(in,clean,2*N*sizeof(double));
    int nimp=0;
    for(double t=0.15;t<3.9;){
      int p=(int)(t*fs);
      if(s==0){ addimp(in,N,p,100,1+(int)(urand()*4*fs/48000)); nimp++; t+=0.02+0.03*urand(); }
      else if(s==1){ for(int k=0;k<10;k++){addimp(in,N,p+(int)(k*0.0008*fs),100,2); nimp++;} t+=0.1; }
      else if(s==2){ for(int k=0;k<5;k++){addimp(in,N,p+(int)(k*0.004*fs),100,2); nimp++;} t+=0.1; }
      else if(s==3){ for(int k=0;k<300;k++){addimp(in,N,p+(int)(k*0.0002*fs),100,2); nimp++;} t+=0.25; }
      else { addimp(in,N,p,100,2); nimp++; t+=0.001; }
    }
    printf("fs=%.0f buf=%d scenario: %s (%d impulses)\n",fs,bsize,sc[s],nimp);
    run(BUILD,fs,bsize,N,clean,in);
  }
  return 0;
}
