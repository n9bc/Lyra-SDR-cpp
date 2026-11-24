/* Driver: runs the real WDSP 2.11 SNBA (create_snba/xsnba/execFrame/asolve/xHat/invf/det/scanFrame)
   at 12 kHz with RXA.c defaults, resampler bypassed (inrate == internalrate). */
#include "comm.h"
#include <stdint.h>
static uint64_t rs = 0x9E3779B97F4A7C15ull;
static double urand(void){ rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (rs >> 11) * (1.0/9007199254740992.0); }
static double grand(void){ double u1 = urand(), u2 = urand(); if (u1 < 1e-300) u1 = 1e-300; return sqrt(-2*log(u1))*cos(2*M_PI*u2); }
#define FS 12000.0
static void bandpass(double* x, int n, double f1, double f2){ /* windowed-sinc FIR, 255 taps */
  int L = 255, M = L/2; double h[255]; double* y = calloc(n, sizeof(double));
  for (int i=0;i<L;i++){ int m=i-M; double w=0.42-0.5*cos(2*M_PI*i/(L-1))+0.08*cos(4*M_PI*i/(L-1));
    double s2 = m==0? 2*f2/FS : sin(2*M_PI*f2/FS*m)/(M_PI*m); double s1 = m==0? 2*f1/FS : sin(2*M_PI*f1/FS*m)/(M_PI*m); h[i]=(s2-s1)*w; }
  for (int i=0;i<n;i++){ double a=0; for(int k=0;k<L;k++){ int j=i-k; if(j>=0) a+=h[k]*x[j]; } y[i]=a; }
  memcpy(x,y,n*sizeof(double)); free(y); }
static double rms(const double* x, int n){ double s=0; for(int i=0;i<n;i++) s+=x[i]*x[i]; return sqrt(s/n); }
static void scale_to(double* x, int n, double r){ double c = r/rms(x,n); for(int i=0;i<n;i++) x[i]*=c; }

int main(int argc, char** argv){
  int sig = argc>1? atoi(argv[1]) : 1;
  double impamp = argc>2? atof(argv[2]) : 10.0;   /* impulse peak relative to signal rms, 0 = none */
  int N = 12000*20; int pre = 0;
  double* clean = calloc(N, sizeof(double)); double* tmp = calloc(N, sizeof(double));
  rs = 0x1234567ull + sig;
  for (int i=0;i<N;i++) tmp[i]=grand();
  switch(sig){
   case 1: /* band-limited noise 300-2900 Hz */
     bandpass(tmp,N,300,2900); scale_to(tmp,N,0.1); memcpy(clean,tmp,N*sizeof(double)); break;
   case 2: /* CW 700 Hz + noise at -30 dB, 300-2900 */
     bandpass(tmp,N,300,2900); scale_to(tmp,N,0.1*0.0316/1.414);
     for(int i=0;i<N;i++) clean[i]=0.1*sin(2*M_PI*700*i/FS)+tmp[i]; break;
   case 3: /* strong carrier 1 kHz + weak noise (-50 dB) */
     bandpass(tmp,N,300,2900); scale_to(tmp,N,0.3*0.00316/1.414);
     for(int i=0;i<N;i++) clean[i]=0.3*sin(2*M_PI*1000*i/FS)+tmp[i]; break;
   case 4: { /* speech-like: noise through 2 resonators x syllabic envelope */
     double y1a=0,y1b=0,y2a=0,y2b=0; double f[2]={500,1500}, bw=120, rr=exp(-M_PI*bw/FS);
     for(int i=0;i<N;i++){ double e=tmp[i];
       double o1 = e + 2*rr*cos(2*M_PI*f[0]/FS)*y1a - rr*rr*y1b; y1b=y1a; y1a=o1;
       double o2 = e + 2*rr*cos(2*M_PI*f[1]/FS)*y2a - rr*rr*y2b; y2b=y2a; y2a=o2;
       double env = pow(fabs(sin(M_PI*4.0*i/FS)),2.0); clean[i]=(o1+0.5*o2)*env; }
     bandpass(clean,N,300,2900); scale_to(clean,N,0.1); break; }
   case 5: /* 2 s digital silence then band-limited noise */
     bandpass(tmp,N,300,2900); scale_to(tmp,N,0.1); pre=24000;
     for(int i=0;i<N;i++) clean[i]= i<pre? 0.0 : tmp[i]; break;
   case 6: /* pure tone 700 Hz, no noise (numerically extreme narrowband) */
     for(int i=0;i<N;i++) clean[i]=0.1*sin(2*M_PI*700*i/FS); break;
  }
  double srms = rms(clean+pre, N-pre);
  /* impulses: 1-4 samples, random sign, every 600-1400 samples */
  double* noisy = calloc(N,sizeof(double)); memcpy(noisy,clean,N*sizeof(double));
  int maxi = 1000, nimp=0; int* ipos=calloc(maxi,sizeof(int)); int* ilen=calloc(maxi,sizeof(int));
  rs = 0xABCDEFull;
  if (impamp > 0) for (int p = 2000; p < N-2000 && nimp<maxi; p += 600 + (int)(urand()*800)) {
     int len = 1 + (int)(urand()*4); double sgn = urand()<0.5? -1:1;
     if (p < pre) continue;
     for (int k=0;k<len;k++) noisy[p+k] += sgn*impamp*srms*(k%2? -0.7:1.0);
     ipos[nimp]=p; ilen[nimp]=len; nimp++; }
  int bsize=64;
  double* in = calloc(2*bsize,sizeof(double)); double* out = calloc(2*bsize,sizeof(double));
  SNBA d = create_snba(1, in, out, 12000, 12000, bsize, 4, 256, 64, 2, 8.0, 20.0, 10, 2, 2, 0.5, 200.0, 5400.0);
  double* y = calloc(N,sizeof(double));
  for (int b=0;b+bsize<=N;b+=bsize){ for(int i=0;i<bsize;i++){ in[2*i]=noisy[b+i]; in[2*i+1]=0; }
     xsnba(d); for(int i=0;i<bsize;i++) y[b+i]=out[2*i]; }
  /* delay: maximise correlation with clean over lags 0..600 */
  int D=0; double best=-1e300;
  for (int L=0; L<=600; L++){ double c=0; for(int i=pre+5000;i<pre+60000 && i+L<N;i++) c+=clean[i]*y[i+L]; if(c>best){best=c;D=L;} }
  int nan=0; double maxo=0; for(int i=0;i<N;i++){ if(!isfinite(y[i])) nan++; else if(fabs(y[i])>maxo) maxo=fabs(y[i]); }
  /* overall error after settling */
  double es=0, ss=0; int s0 = pre + 4000;
  for (int i=s0;i+D<N-1000;i++){ double e=y[i+D]-clean[i]; es+=e*e; ss+=clean[i]*clean[i]; }
  /* per-impulse residual: window [p-8, p+len+8) */
  double ie=0, re=0, worst=0; int nclick6=0, nclickm=0, nused=0;
  for (int k=0;k<nimp;k++){ int p=ipos[k]; if (p < s0 || p+D+64 >= N-1000) continue; nused++;
     double a=0,b=0,lp=0; for(int i=p-8;i<p+ilen[k]+8;i++){ double e=y[i+D]-clean[i]; double im=noisy[i]-clean[i]; a+=e*e; b+=im*im; lp+=clean[i]*clean[i]; }
     ie+=b; re+=a; double rel = a/(lp>0?lp:1e-30); if (rel>worst) worst=rel; if (rel>1.0) nclick6++; if (rel>0.1) nclickm++; }
  /* snapshot of the output buffer quality only in silence region (sig 5) */
  double silmax=0; for(int i=0;i<pre-1000;i++) if(fabs(y[i+D])>silmax) silmax=fabs(y[i+D]);
  long nmod=0, ntot=0; int idet=0;
  for (int i=s0;i+D<N-1000;i++){ ntot++; if (fabs(y[i+D]-noisy[i])>1e-9*srms) nmod++; }
  for (int k=0;k<nimp;k++){ int p=ipos[k]; if (p < s0 || p+D+64 >= N-1000) continue; if (fabs(y[p+D]-noisy[p])>0.5*impamp*srms) idet++; }
  printf("mod=%.2f%% impRepaired=%d ", 100.0*nmod/ntot, idet);
  printf("sig=%d imp=%.0f D=%d | asolve calls=%ld unstable/guarded=%ld (%.1f%%) nonfinite=%ld max|a|=%.3g max|k|=%.3g | outNaN=%d max|out|=%.3g silmax=%.3g | SNR=%.2f dB | nimp=%d click: in=%.3g resid=%.3g suppr=%.2f dB worstRel=%.3g n(rel>1)=%d n(rel>0.1)=%d\n",
     sig, impamp, D, g_asolve_calls, g_asolve_unstable, 100.0*g_asolve_unstable/(g_asolve_calls?g_asolve_calls:1), g_asolve_nan, g_asolve_maxabs_a, g_asolve_maxabs_k,
     nan, maxo, silmax, 10*log10(ss/(es>0?es:1e-300)), nused, ie, re, 10*log10(ie/(re>0?re:1e-300)), worst, nclick6, nclickm);
  return 0;
}
