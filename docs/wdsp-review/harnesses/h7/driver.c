#include "comm.h"
#include <stdio.h>
#include <stdint.h>
#define FS 48000.0
#define BS 1024
static uint64_t rs;
static double urand(void){ rs ^= rs<<13; rs ^= rs>>7; rs ^= rs<<17; return ((rs>>11)+0.5)*(1.0/9007199254740992.0); }
static double gauss(void){ return sqrt(-2*log(urand()))*cos(2*PI*urand()); }

typedef struct { double *x; int *imp; int n; } tsig_t;
static tsig_t mk(int n){ tsig_t s; s.x=calloc(2*n,sizeof(double)); s.imp=calloc(n,sizeof(int)); s.n=n; return s; }
static void addnoise(tsig_t s,int a,int b,double meanabs){ double sg=meanabs/1.2533141373155; for(int i=a;i<b;i++){ s.x[2*i]+=sg*gauss(); s.x[2*i+1]+=sg*gauss(); } }
static void addimp(tsig_t s,int a,int b,double rate,double amp){ double per=FS/rate; double t=a+per*urand(); while((int)t+3<b){ int k=(int)t; double ph=2*PI*urand(); for(int j=0;j<3;j++){ s.x[2*(k+j)]+=amp*cos(ph); s.x[2*(k+j)+1]+=amp*sin(ph); s.imp[k+j]=1;} t+=per*(0.5+urand()); } }

/* run blanker; returns out aligned to input (delay compensated); also records avg per block */
static double *run(tsig_t s,double T,double *avgtrace){
  int nb=s.n/BS; double *out=calloc(2*(s.n+4096),sizeof(double)); double ib[2*BS],ob[2*BS];
  NOB a=create_nob(1,BS,ib,ob,FS,0,1e-4,1e-4,1e-4,1e-4,0.025,0.02,T);
  int D=a->in_idx-a->out_idx; double *raw=calloc(2*(nb*BS),sizeof(double));
  for(int b=0;b<nb;b++){ memcpy(ib,s.x+2*b*BS,sizeof ib); xnob(a); memcpy(raw+2*b*BS,ob,sizeof ob); if(avgtrace) avgtrace[b]=a->avg; }
  for(int i=0;i+D<nb*BS;i++){ out[2*i]=raw[2*(i+D)]; out[2*i+1]=raw[2*(i+D)+1]; }
  destroy_nob(a); free(raw); return out; }

static int altered(tsig_t s,double*o,int i){ double dr=o[2*i]-s.x[2*i], di=o[2*i+1]-s.x[2*i+1]; double m=fabs(s.x[2*i])+fabs(s.x[2*i+1]); return (fabs(dr)+fabs(di))>1e-9*(m+1e-30); }

int main(void){
  const double E=1e-3;
  printf("# build: %s\n", BUILD);
  /* Test 1: impulse density sweep */
  printf("\n[T1] dense impulses: 3-sample impulses, noise E|x|=1e-3, 2 s, stats over last 1.5 s\n");
  printf("T    rate/s amp(xE)  avg/E(dB)  imp_missed%%  resid_imp_E(dB)  clean_altered%%\n");
  double Ts[]={12,4}; double rates[]={100,300,1000,2000}; double amps[]={15,20,50,100};
  for(int ti=0;ti<2;ti++) for(int ri=0;ri<4;ri++) for(int ai=0;ai<4;ai++){
    rs=0x9E3779B97F4A7C15ULL+ri*7+ai*131+ti; int n=96*BS; tsig_t s=mk(n); addnoise(s,0,n,E); addimp(s,0,n,rates[ri],amps[ai]*E);
    double tr[96]; double *o=run(s,Ts[ti],tr); int st=n/4, en=n-4096;
    double av=0; for(int b=24;b<94;b++) av+=tr[b]; av/=70;
    long ni=0,miss=0,nc=0,alt=0; double ei=0,eo=0;
    for(int i=st;i<en;i++){ if(s.imp[i]){ ni++; double pi_=s.x[2*i]*s.x[2*i]+s.x[2*i+1]*s.x[2*i+1], po=o[2*i]*o[2*i]+o[2*i+1]*o[2*i+1]; ei+=pi_; eo+=po; if(po>0.25*pi_) miss++; } else { nc++; alt+=altered(s,o,i);} }
    printf("%-4g %-6g %-7g %9.2f  %10.2f  %14.2f  %12.2f\n",Ts[ti],rates[ri],amps[ai],20*log10(av/E),100.0*miss/ni,10*log10((eo+1e-300)/ei),100.0*alt/nc);
    free(o); free(s.x); free(s.imp);
  }
  /* Test 2: startup blind spot */
  printf("\n[T2] start-up: noise E|x|=1e-4, 100x impulses at 200/s from t=0, T=12\n");
  { rs=12345; int n=24*BS; tsig_t s=mk(n); addnoise(s,0,n,1e-4); addimp(s,0,n,200,100*1e-4); double *o=run(s,12,NULL);
    int win[]={0,2400,4800,9600,14400,19200}; for(int w=0;w<5;w++){ long ni=0,miss=0; for(int i=win[w];i<win[w+1];i++) if(s.imp[i]){ni++; double pi_=s.x[2*i]*s.x[2*i]+s.x[2*i+1]*s.x[2*i+1], po=o[2*i]*o[2*i]+o[2*i+1]*o[2*i+1]; if(po>0.25*pi_) miss++;}
      printf("  t=%5.0f-%5.0f ms: impulse samples %ld missed %ld (%.0f%%)\n",win[w]/48.0,win[w+1]/48.0,ni,miss,ni?100.0*miss/ni:0); }
    free(o); }
  /* Test 3: silence then noise */
  printf("\n[T3] 1 s exact zeros then noise E|x|=1e-3 (no impulses): altered samples after onset\n");
  for(int ti=0;ti<2;ti++){ double T=ti?2.5:12; rs=777; int n=96*BS; int on=48000; tsig_t s=mk(n); addnoise(s,on,n,E); double *o=run(s,T,NULL);
    long a5=0,a50=0,ss=0; for(int i=on;i<on+240;i++) a5+=altered(s,o,i); for(int i=on;i<on+2400;i++) a50+=altered(s,o,i); for(int i=on+24000;i<n-4096;i++) ss+=altered(s,o,i);
    int first_ok=-1; for(int i=on;i<n;i++){ int ok=1; for(int j=0;j<48;j++) if(altered(s,o,i+j)){ok=0;break;} if(ok){first_ok=i-on;break;} }
    printf("  T=%-4g altered in first 5 ms: %ld/240, first 50 ms: %ld/2400, steady-state %.3f%%, first 1ms-clean run at +%d samples\n",T,a5,a50,100.0*ss/(n-4096-on-24000),first_ok);
    free(o);}
  /* Test 4: pure-noise false alarm */
  printf("\n[T4] pure noise 4 s: fraction of samples altered (blanked) ; closed-form P_fa=exp(-pi T^2/4)\n");
  double T4[]={2.5,3,3.5,4,6,12};
  for(int ti=0;ti<6;ti++){ rs=4242; int n=188*BS; tsig_t s=mk(n); addnoise(s,0,n,E); double tr[188]; double *o=run(s,T4[ti],tr);
    long alt=0; for(int i=n/8;i<n-4096;i++) alt+=altered(s,o,i); double av=0; for(int b=30;b<186;b++) av+=tr[b]; av/=156;
    printf("  T=%-4g altered %.4f%%  avg/E=%.4f  Pfa(closed, vs true E)=%.3g\n",T4[ti],100.0*alt/(n-4096-n/8),av/E,exp(-PI*T4[ti]*T4[ti]/4)); free(o);}
  /* Test 5: upward 20 dB step */
  printf("\n[T5] noise level step +20 dB at t=1 s (no impulses): altered samples after step\n");
  for(int ti=0;ti<2;ti++){ double T=ti?2.5:12; rs=999; int n=96*BS; int st=48000; tsig_t s=mk(n); addnoise(s,0,st,E); addnoise(s,st,n,10*E); double *o=run(s,T,NULL);
    long a10=0,a100=0,a500=0; for(int i=st;i<st+480;i++) a10+=altered(s,o,i); for(int i=st;i<st+4800;i++) a100+=altered(s,o,i); for(int i=st+4800;i<st+24000;i++) a500+=altered(s,o,i);
    printf("  T=%-4g altered 0-10ms: %ld/480, 0-100ms: %ld/4800, 100-500ms: %ld/19200\n",T,a10,a100,a500); free(o);}
  /* Test 6: 40 dB level drop (tuning jump to a quiet band) */
  printf("\n[T6] noise level drop -40 dB at t=1 s: altered samples after drop\n");
  for(int ti=0;ti<2;ti++){ double T=ti?2.5:12; rs=31337; int n=96*BS; int st=48000; tsig_t s=mk(n); addnoise(s,0,st,100*E); addnoise(s,st,n,E); double *o=run(s,T,NULL);
    long a10=0,a100=0; for(int i=st;i<st+480;i++) a10+=altered(s,o,i); for(int i=st;i<st+4800;i++) a100+=altered(s,o,i);
    printf("  T=%-4g altered 0-10ms: %ld/480, 0-100ms: %ld/4800\n",T,a10,a100); free(o);}
  return 0; }
