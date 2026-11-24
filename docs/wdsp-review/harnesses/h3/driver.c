#include "comm.h"
#include <stdio.h>
#include <stdint.h>
#include <time.h>
#define FS 48000.0
static uint64_t rs;
static double ur(void){rs^=rs<<13;rs^=rs>>7;rs^=rs<<17;return ((rs>>11)+0.5)*(1.0/9007199254740992.0);}
static double gn(void){return sqrt(-2*log(ur()))*cos(TWOPI*ur());}
/* complex noise with E|n|^2 = 1 */
static void cn(double*r,double*i){*r=gn()*M_SQRT1_2;*i=gn()*M_SQRT1_2;}

typedef struct { long flags, blanked, imp_tot, imp_hit, nearblank; double res_in, res_out, win_in, win_out; } Res;

/* run one scenario. sig(n, &cr,&ci) returns clean (non-impulse) signal; impulse list */
typedef void (*SigFn)(long n, double*r, double*i, void*ctx);
static NOB mk(double T, int cap){
  const char*e=getenv("NBMODE"); int md=e?atoi(e):0;
  NOB a=create_nob(1,1,0,0,FS,md,0.0001,0.0001,0.0001,0.0001,0.025,0.02,T);
#ifdef FIXED
  a->lp_cap=cap;
#else
  (void)cap;
#endif
  return a;
}
static Res run(double T,int cap,long N,long m0,long m1,SigFn f,void*ctx,long*imps,int nimp,double impamp,uint64_t seed){
  Res R={0}; rs=seed;
  NOB a=mk(T,cap);
  double in[2],out[2];
  a->in=in;a->out=out;
  int D=a->in_idx-a->out_idx; if(D<0)D+=a->dline_size;
  double *hx=calloc(2*N,sizeof(double)), *hc=calloc(2*N,sizeof(double));
  char *isimp=calloc(N,1);
  for(int k=0;k<nimp;k++) isimp[imps[k]]=1;
  for(long n=0;n<N;n++){
    double r,i; f(n,&r,&i,ctx);
    double nr,ni; cn(&nr,&ni); r+=nr;i+=ni;
    hc[2*n]=r;hc[2*n+1]=i;
    if(isimp[n]){double ph=TWOPI*ur(); r+=impamp*cos(ph); i+=impamp*sin(ph);}
    hx[2*n]=r;hx[2*n+1]=i;
    in[0]=r;in[1]=i; xnob(a);
    int idx=a->in_idx-1; if(idx<0) idx+=a->dline_size;
    int fl=a->imp[idx];
    if(n>=m0&&n<m1){
      if(fl) R.flags++;
      long d=n-D;
      if(d>=m0){
        double er=out[0]-hx[2*d],ei=out[1]-hx[2*d+1];
        if(er*er+ei*ei>1e-18) R.blanked++;
      }
    }
  }
  /* impulse detection: flagged within [k, k+3] -> recompute by re-run is costly; use stored */
  free(hx);free(hc);free(isimp);destroy_nob(a);
  return R;
}
/* second pass variant capturing flags per sample */
static Res run2(double T,int cap,long N,long m0,long m1,SigFn f,void*ctx,long*imps,int nimp,double impamp,uint64_t seed){
  Res R={0}; rs=seed;
  NOB a=mk(T,cap);
  double in[2],out[2]; a->in=in;a->out=out;
  int D=a->in_idx-a->out_idx; if(D<0)D+=a->dline_size;
  double *hx=calloc(2*N,sizeof(double)), *hc=calloc(2*N,sizeof(double)), *ho=calloc(2*N,sizeof(double));
  char *isimp=calloc(N,1), *fl=calloc(N,1);
  for(int k=0;k<nimp;k++) isimp[imps[k]]=1;
  for(long n=0;n<N;n++){
    double r,i; f(n,&r,&i,ctx);
    double nr,ni; cn(&nr,&ni); r+=nr;i+=ni;
    hc[2*n]=r;hc[2*n+1]=i;
    if(isimp[n]){double ph=TWOPI*ur(); r+=impamp*cos(ph); i+=impamp*sin(ph);}
    hx[2*n]=r;hx[2*n+1]=i;
    in[0]=r;in[1]=i; xnob(a);
    int idx=a->in_idx-1; if(idx<0) idx+=a->dline_size;
    fl[n]=(char)a->imp[idx];
    long d=n-D; if(d>=0){ho[2*d]=out[0];ho[2*d+1]=out[1];}
  }
  char *nearimp=calloc(N,1);
  for(int k=0;k<nimp;k++){
    long s=imps[k]; R.imp_tot++;
    int hit=0; for(long j=s;j<s+4&&j<N;j++) if(fl[j]) hit=1;
    R.imp_hit+=hit;
    for(long j=s-20;j<s+40;j++) if(j>=0&&j<N) nearimp[j]=1;
    /* residual impulse energy: |x-clean|^2 at impulse sample in vs out-clean */
    double er=hx[2*s]-hc[2*s],ei=hx[2*s+1]-hc[2*s+1]; R.res_in+=er*er+ei*ei;
    er=ho[2*s]-hc[2*s];ei=ho[2*s+1]-hc[2*s+1]; R.res_out+=er*er+ei*ei;
    for(long j=s-20;j<s+40;j++){ if(j<0||j>=N)continue;
      double a1=hx[2*j]-hc[2*j],b1=hx[2*j+1]-hc[2*j+1]; R.win_in+=a1*a1+b1*b1;
      double a2=ho[2*j]-hc[2*j],b2=ho[2*j+1]-hc[2*j+1]; R.win_out+=a2*a2+b2*b2; }
  }
  for(long n=m0;n<m1&&n<N-D;n++){
    if(fl[n]&&!nearimp[n]) R.flags++;      /* false flags (not near an impulse) */
    double er=ho[2*n]-hx[2*n],ei=ho[2*n+1]-hx[2*n+1];
    if(er*er+ei*ei>1e-18 && !nearimp[n]) R.blanked++;
    if(er*er+ei*ei>1e-18 && nearimp[n]) R.nearblank++; /* collateral blanked samples */
  }
  free(hx);free(hc);free(ho);free(isimp);free(fl);free(nearimp);destroy_nob(a);
  return R;
}

/* ---- signals ---- */
typedef struct { double amp, f, ton, rise; int shaped; long onset; long period; } Key;
static void sig_none(long n,double*r,double*i,void*c){(void)n;(void)c;*r=*i=0;}
static void sig_key(long n,double*r,double*i,void*cx){
  Key*k=cx; double env=0;
  if(n>=k->onset){
    long t=(n-k->onset); if(k->period>0) t%=k->period;
    long on=(long)(k->ton*FS), rl=(long)(k->rise*FS);
    if(!k->shaped) env = (t<on)?1:0;
    else if(t<rl) env=0.5-0.5*cos(PI*t/rl);
    else if(t<on) env=1;
    else if(t<on+rl) env=0.5+0.5*cos(PI*(t-on)/rl);
    else env=0;
  }
  double ph=TWOPI*k->f*n/FS; *r=k->amp*env*cos(ph);*i=k->amp*env*sin(ph);
}
typedef struct { int nc; double amp; double f[64], p[64]; } Multi;
static void sig_multi(long n,double*r,double*i,void*cx){
  Multi*m=cx; double a=0,b=0;
  for(int k=0;k<m->nc;k++){double ph=TWOPI*m->f[k]*n/FS+m->p[k]; a+=cos(ph);b+=sin(ph);}
  *r=m->amp*a;*i=m->amp*b;
}
/* SSB-like: complex white noise -> 4-pole lowpass (~1.2 kHz) shifted to +6 kHz, x syllabic envelope */
typedef struct { double amp; double s[8]; uint64_t rs2; double env, envt; } Ssb;
static double ur2(uint64_t*s){*s^=*s<<13;*s^=*s>>7;*s^=*s<<17;return ((*s>>11)+0.5)*(1.0/9007199254740992.0);}
static void sig_ssb(long n,double*r,double*i,void*cx){
  Ssb*s=cx; double a=exp(-TWOPI*1200.0/FS);
  double u1=ur2(&s->rs2),u2=ur2(&s->rs2); double g=sqrt(-2*log(u1));
  double xr=g*cos(TWOPI*u2), xi=g*sin(TWOPI*u2);
  for(int k=0;k<4;k++){ s->s[2*k]=a*s->s[2*k]+(1-a)*xr; s->s[2*k+1]=a*s->s[2*k+1]+(1-a)*xi; xr=s->s[2*k]; xi=s->s[2*k+1]; }
  if(n%2400==0) s->envt = (ur2(&s->rs2)<0.3)?0.05:(0.3+ur2(&s->rs2));   /* 50 ms syllables */
  s->env = 0.998*s->env+0.002*s->envt;
  double ph=TWOPI*6000.0*n/FS, c=cos(ph), sn=sin(ph);
  double yr=xr*c-xi*sn, yi=xr*sn+xi*c;
  *r=s->amp*s->env*yr*18.0; *i=s->amp*s->env*yi*18.0;  /* 18 ~ restores unit rms after LPF */
}

static void pr(const char*tag,Res R){
  printf("%-58s flags=%6ld blanked=%6ld", tag, R.flags, R.blanked);
  if(R.imp_tot) printf(" imp_hit=%ld/%ld resid_dB=%.1f blank/imp=%.1f win_err_dB=%+.1f", R.imp_hit, R.imp_tot, 10*log10((R.res_out+1e-30)/R.res_in), (double)R.nearblank/R.imp_tot, 10*log10((R.win_out+1e-30)/R.win_in));
  printf("\n");
}

int main(void){
#ifdef FIXED
  printf("=== FIXED (NLMS order 8, mu 0.05, cap 20) ===\n");
#else
  printf("=== ORIGINAL ===\n");
#endif
  long N; char tag[128];
  /* S1: noise only, P_fa */
  for(double T=2.5;T<=6.01;T+=3.5){ N=(long)(4*FS); Res R=run(T,20,N,(long)FS,N,sig_none,0,0,0,0,1);
    snprintf(tag,sizeof tag,"S1 noise only T=%.1f (P_fa=%.2e)",T,(double)R.flags/(N-FS)); pr(tag,R);}
  /* S1b: impulses in noise only */
  { long imps[40]; for(int k=0;k<40;k++) imps[k]=(long)(FS)+k*2400+17;
    double amps[3]={8,15,30};
    for(int a=0;a<3;a++){ N=(long)(3.5*FS); Res R=run2(4,20,N,(long)FS,N,sig_none,0,imps,40,amps[a],2);
      snprintf(tag,sizeof tag,"S1b noise + 40 impulses %.0f x rms, T=4",amps[a]); pr(tag,R);} }
  /* S2/S3: shaped key-down/up, repeating 20 ms on / 30 ms off... use 50 ms on / 50 off, 10 cycles */
  { double lev[2]={100,10}, Ts[2]={12,6};
    for(int s=0;s<2;s++){ Key k={lev[s],3000,0.05,0.005,1,(long)FS,(long)(0.1*FS)}; N=(long)(2*FS);
      Res R=run(Ts[s],20,N,(long)FS,N,sig_key,&k,0,0,0,3);
      snprintf(tag,sizeof tag,"S2 shaped(5ms RC) keying %.0f dB, 10 cycles, T=%.0f",20*log10(lev[s]),Ts[s]); pr(tag,R);} }
  /* S4: steady 40 dB carrier + 15 impulses */
  { long imps[15]; for(int k=0;k<15;k++) imps[k]=(long)(FS)+k*3000+11;
    double amps[4]={10,30,100,300};
    for(int a=0;a<4;a++){ Key k={100,3000,1e9,0,0,0,0}; N=(long)(2*FS);
      Res R=run2(4,20,N,(long)FS,N,sig_key,&k,imps,15,amps[a],4);
      snprintf(tag,sizeof tag,"S4 40dB carrier + 15 imp %.0fx noise rms, T=4",amps[a]); pr(tag,R);} }
  /* S5: hard (unshaped) key-down 40 dB at t=1s, capped vs uncapped */
  { int caps[2]={20,-1};
    for(int c=0;c<2;c++){ Key k={100,3000,1e9,0,0,(long)FS,0}; N=(long)(2*FS);
      Res R=run(6,caps[c],N,(long)FS,N,sig_key,&k,0,0,0,5);
      snprintf(tag,sizeof tag,"S5 hard key-down 40dB, T=6, cap=%d (1 s after step)",caps[c]); pr(tag,R);}
    /* start-up with strong carrier present */
    for(int c=0;c<2;c++){ Key k={100,3000,1e9,0,0,0,0}; N=(long)(1*FS);
      Res R=run(6,caps[c],N,0,N,sig_key,&k,0,0,0,6);
      snprintf(tag,sizeof tag,"S5b start-up with 40dB carrier, T=6, cap=%d (first 1 s)",caps[c]); pr(tag,R);} }
  /* S6: many carriers (30 dB each) + 15 impulses at 30x, T=6 */
  { int ncs[5]={1,4,8,16,32};
    long imps[15]; for(int k=0;k<15;k++) imps[k]=(long)(FS)+k*3000+11;
    for(int q=0;q<5;q++){ Multi m; m.nc=ncs[q]; m.amp=31.6; rs=99;
      for(int k=0;k<m.nc;k++){m.f[k]=(ur()-0.5)*44000; m.p[k]=TWOPI*ur();}
      N=(long)(2*FS);
      Res R=run2(6,20,N,(long)FS,N,sig_multi,&m,imps,15,300,7);
      snprintf(tag,sizeof tag,"S6 %2d carriers @30dB each + 15 imp 300x, T=6",ncs[q]); pr(tag,R);} }
  /* S7: SSB-like 40 dB narrowband with syllabic envelope + impulses */
  { long imps[15]; for(int k=0;k<15;k++) imps[k]=(long)(FS)+k*3000+11;
    double Ts[2]={6,12};
    for(int t=0;t<2;t++){ Ssb s={0}; s.amp=100; s.rs2=12345; s.env=0.5; s.envt=0.5; N=(long)(2*FS);
      Res R=run2(Ts[t],20,N,(long)FS,N,sig_ssb,&s,imps,15,300,8);
      snprintf(tag,sizeof tag,"S7 SSB-like 40dB + 15 imp 300x, T=%.0f",Ts[t]); pr(tag,R);} }
  { NOB a=mk(6,20); int B=1024; double*in=calloc(2*B,8),*out=calloc(2*B,8); a->buffsize=B;a->in=in;a->out=out; rs=3;
    for(int k=0;k<B;k++){double r,i;cn(&r,&i);in[2*k]=r+100*cos(k*.3);in[2*k+1]=i+100*sin(k*.3);}
    struct timespec t0,t1; clock_gettime(CLOCK_MONOTONIC,&t0); for(int it=0;it<3000;it++) xnob(a); clock_gettime(CLOCK_MONOTONIC,&t1);
    double ns=((t1.tv_sec-t0.tv_sec)*1e9+(t1.tv_nsec-t0.tv_nsec))/(3000.0*B);
    printf("CPU: %.2f ns/sample (%.2f%% of one core at 384 kS/s)\n",ns,ns*384000/1e7); }
  return 0;
}
