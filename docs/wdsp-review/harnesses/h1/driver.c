/* EMNR musical-noise harness driver.
   Usage: drv method ae cep soft3 ximin snr_db scenario(0=speech,1=tone) [wavout]
   Shadow-filtering evaluation: after each EMNR frame the final mask (after gain, cepstral smoothing,
   aepf) is applied to the separately computed STFTs of clean speech S and noise W (same window, same
   frame alignment as EMNR), so speech distortion and residual noise are measured per TF cell. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>
#include "fftw3.h"
#define __declspec(x)
#define PORT
typedef double complex[2];
#include "orig/emnr.h"

extern int fix_cep __attribute__((weak));
extern int fix_soft3 __attribute__((weak));
extern int fix_ximin __attribute__((weak));
extern int emnr_dbg_N;
extern double emnr_dbg_zeta;

#define FS 48000
#define FSIZE 4096
#define OVR 4
#define INCR 1024
#define MS (FSIZE/2+1)

static uint64_t rs = 0x9E3779B97F4A7C15ull;
static double urand(void){ rs ^= rs<<13; rs ^= rs>>7; rs ^= rs<<17; return ((rs>>11)+0.5)/9007199254740992.0; }
static double grand(void){ double u1=urand(),u2=urand(); return sqrt(-2*log(u1))*cos(2*M_PI*u2); }

static void bpfilter(double* x, int n)
{   /* linear-phase FIR bandpass 200-2900 Hz, 1023 taps, Blackman (models nbp0 ahead of EMNR) */
    int L=1023, h2=L/2, i, j; double* h=malloc(L*sizeof(double)); double* y=calloc(n,sizeof(double));
    double f1=200.0/FS, f2=2900.0/FS;
    for(i=0;i<L;i++){ int m=i-h2; double v = (m==0)? 2*(f2-f1) : (sin(2*M_PI*f2*m)-sin(2*M_PI*f1*m))/(M_PI*m);
        double w=0.42-0.5*cos(2*M_PI*i/(L-1))+0.08*cos(4*M_PI*i/(L-1)); h[i]=v*w; }
    for(i=0;i<n;i++){ double acc=0; for(j=0;j<L;j++){ int k=i-j+h2; if(k>=0&&k<n) acc+=h[j]*x[k]; } y[i]=acc; }
    memcpy(x,y,n*sizeof(double)); free(h); free(y);
}

int main(int argc, char** argv)
{
    int method=atoi(argv[1]), ae=atoi(argv[2]), cep=atoi(argv[3]), soft3=atoi(argv[4]), ximin=atoi(argv[5]);
    double snr=atof(argv[6]); int scen=atoi(argv[7]);
    if(&fix_cep){ fix_cep=cep; fix_soft3=soft3; fix_ximin=ximin; }
    else if(cep||soft3||ximin){ fprintf(stderr,"orig build has no fixes\n"); return 2; }
    const double T=18.0; int N=(int)(T*FS);
    double *s=calloc(N,sizeof(double)), *w=calloc(N,sizeof(double));
    int i,k;
    /* noise */
    for(i=0;i<N;i++) w[i]=grand();
    /* signal */
    if(scen==0){
        /* speech-like: 0-4 s silence; 4 sentences of 2.5 s separated by 1.0 s pauses */
        for(int sent=0;sent<4;sent++){
            int st=(int)((4.0+sent*3.5)*FS), en=st+(int)(2.5*FS);
            int pos=st; double ph[40]={0};
            while(pos<en){
                int dur=(int)((0.12+0.16*urand())*FS), gap=(int)((0.03+0.09*urand())*FS);
                double F1=400+400*urand(), F2=1000+1000*urand(), f0a=100+60*urand(), f0b=100+60*urand();
                for(i=0;i<dur && pos+i<en;i++){
                    double tt=(double)i/dur, env=sin(M_PI*tt); env*=env;
                    double f0=f0a+(f0b-f0a)*tt, v=0;
                    for(int h=1;h<40;h++){ double f=h*f0; if(f>3000) break;
                        double a1=1.0/(1+pow((f-F1)/120.0,2)), a2=0.5/(1+pow((f-F2)/180.0,2));
                        ph[h]+=2*M_PI*f/FS; v+=(a1+a2+0.02)*sin(ph[h]); }
                    s[pos+i]=env*v;
                }
                pos+=dur+gap;
            }
        }
    } else {
        /* CW tones from t=2 s: 700 Hz strong and 1500 Hz weak */
        for(i=(int)(2.0*FS);i<N;i++) s[i]=sin(2*M_PI*700.0*i/FS)+0.3*sin(2*M_PI*1500.0*i/FS);
    }
    bpfilter(s,N); bpfilter(w,N);
    /* scale: SNR defined over active speech region (or tone region) within band */
    double es=0,ew=0; int ns=0;
    for(i=(int)(4.0*FS);i<N;i++){ if(fabs(s[i])>0 || scen){ es+=s[i]*s[i]; ns++; } ew+=w[i]*w[i]; }
    ew/= (N-(int)(4.0*FS)); es/= (ns?ns:1);
    double g=sqrt(ew/es*pow(10,snr/10));
    for(i=0;i<N;i++) s[i]*=g;
    double amp=1e-3; /* overall level, typical post-AGC-less RX scale */
    for(i=0;i<N;i++){ s[i]*=amp; w[i]*=amp; }

    EMNR a=create_emnr(1,0,INCR,NULL,NULL,FSIZE,OVR,FS,0,1.0,method,0,ae);
    double *buf=calloc(2*INCR,sizeof(double)), *obuf=calloc(2*INCR,sizeof(double));
    setBuffers_emnr(a,buf,obuf);
    double *fin=fftw_malloc(FSIZE*sizeof(double)); fftw_complex *Sx=fftw_malloc(MS*sizeof(fftw_complex)), *Sw=fftw_malloc(MS*sizeof(fftw_complex)), *Ss=fftw_malloc(MS*sizeof(fftw_complex));
    fftw_plan p=fftw_plan_dft_r2c_1d(FSIZE,fin,Sx,FFTW_ESTIMATE);
    int nfr=(N-FSIZE)/INCR+1;
    float *G=calloc((size_t)nfr*MS,sizeof(float)), *PW=calloc((size_t)nfr*MS,sizeof(float)), *PS=calloc((size_t)nfr*MS,sizeof(float));
    int *Nae=calloc(nfr,sizeof(int)); double *zf=calloc(nfr,sizeof(double));
    double maxalign=0, outE=0; int nan=0;
    FILE* wf = argc>8? fopen(argv[8],"wb"):NULL;
    int calls=N/INCR;
    for(int c=0;c<calls;c++){
        for(i=0;i<INCR;i++){ buf[2*i]=s[c*INCR+i]+w[c*INCR+i]; buf[2*i+1]=0; }
        emnr_dbg_N=-1;
        xemnr(a,0);
        for(i=0;i<INCR;i++){ double o=obuf[2*i]; if(o!=o) nan++; outE+=o*o; if(wf){ float fo=(float)(o/amp*0.05); fwrite(&fo,4,1,wf);} }
        int t=c-3; if(t<0||t>=nfr) continue;
        int st=t*INCR;
        double* srcs[3]={NULL,s,w}; fftw_complex* dst[3]={Sx,Ss,Sw};
        for(int q=0;q<3;q++){
            for(i=0;i<FSIZE;i++) fin[i]=a->window[i]*(q==0? s[st+i]+w[st+i] : srcs[q][st+i]);
            fftw_execute_dft_r2c(p,fin,dst[q]);
        }
        for(k=0;k<MS;k++){ double d=fabs(Sx[k][0]-a->forfftout[2*k]); if(d>maxalign) maxalign=d;
            G[(size_t)t*MS+k]=(float)a->mask[k];
            PW[(size_t)t*MS+k]=(float)(Sw[k][0]*Sw[k][0]+Sw[k][1]*Sw[k][1]);
            PS[(size_t)t*MS+k]=(float)(Ss[k][0]*Ss[k][0]+Ss[k][1]*Ss[k][1]); }
        Nae[t]=emnr_dbg_N; zf[t]=emnr_dbg_zeta;
    }
    if(wf) fclose(wf);
    /* metrics over band 300-2800 Hz */
    int k0=(int)(300.0*FSIZE/FS), k1=(int)(2800.0*FSIZE/FS);
    double binW_mean[MS]; memset(binW_mean,0,sizeof binW_mean);
    for(int t=0;t<nfr;t++) for(k=0;k<MS;k++) binW_mean[k]+=PW[(size_t)t*MS+k]/nfr;
    /* frame classes */
    double fsE[4096]; double maxfs=0;
    for(int t=0;t<nfr;t++){ double e=0; for(k=k0;k<=k1;k++) e+=PS[(size_t)t*MS+k]; fsE[t]=e; if(e>maxfs) maxfs=e; }
    double ws=0,wo=0,ss=0,so=0,sd=0,w4i=0,w2i=0,w4o=0,w2o=0; long nc=0;   /* noise-only frames */
    double xs_ws=0,xs_wo=0,x4i=0,x2i=0,x4o=0,x2o=0; long nx=0;           /* speech-free cells in speech frames */
    double sp_ws=0,sp_wo=0; long iso_in=0, iso_out=0, iso_in_x=0, iso_out_x=0, ncells_x=0;
    int nsp=0,nsp_ae1=0, nno=0;
    double flick=0, gsum=0; long nfl=0;
    for(int t=1;t<nfr-1;t++){
        double tsec=(t*INCR+FSIZE/2)/(double)FS;
        int noiseonly = (scen==0) ? (fsE[t] < 1e-6*maxfs) : (tsec<1.9 && tsec>1.0);
        int sact = (scen==0) ? (fsE[t] > 0.1*maxfs) : (tsec>3.0);
        if(tsec<1.0) continue; /* estimator warm-up */
        if(noiseonly && (scen==1 || tsec>2.0)){
            nno++;
            for(k=k0;k<=k1;k++){ size_t ix=(size_t)t*MS+k; double gg=G[ix], pi=PW[ix], po=gg*gg*pi;
                ws+=pi; wo+=po; w2i+=pi*pi; w4i+=pi*pi*pi*pi; w2o+=po*po; w4o+=po*po*po*po; nc++;
                double ngi=0,ngo=0; for(int dt=-1;dt<=1;dt++) for(int dk=-1;dk<=1;dk++){ if(!dt&&!dk) continue; size_t j=(size_t)(t+dt)*MS+k+dk; ngi+=PW[j]; ngo+=G[j]*G[j]*PW[j]; }
                if(pi>4*ngi/8) iso_in++; if(po>4*ngo/8) iso_out++;
                flick+=fabs(G[ix]-G[ix-MS]); gsum+=G[ix]; nfl++; }
        }
        if(sact){
            nsp++; if(Nae[t]==1) nsp_ae1++;
            for(k=k0;k<=k1;k++){ size_t ix=(size_t)t*MS+k; double gg=G[ix];
                ss+=PS[ix]; so+=gg*gg*PS[ix]; sd+=(1-gg)*(1-gg)*PS[ix]; sp_ws+=PW[ix]; sp_wo+=gg*gg*PW[ix];
                if(PS[ix] < 0.01*binW_mean[k]){ double pi=PW[ix], po=gg*gg*pi; xs_ws+=pi; xs_wo+=po; x2i+=pi*pi; x4i+=pi*pi*pi*pi; x2o+=po*po; x4o+=po*po*po*po; nx++;
                    double ngi=0,ngo=0; for(int dt=-1;dt<=1;dt++) for(int dk=-1;dk<=1;dk++){ if(!dt&&!dk) continue; size_t j=(size_t)(t+dt)*MS+k+dk; ngi+=PW[j]; ngo+=G[j]*G[j]*PW[j]; }
                    ncells_x++; if(pi>4*ngi/8) iso_in_x++; if(po>4*ngo/8) iso_out_x++; }
            }
        }
    }
    #define DB(x) (10*log10(x))
    double kin=(w4i/nc)/pow(w2i/nc,2), kout=(w4o/nc)/pow(w2o/nc,2);
    double kxin=nx?(x4i/nx)/pow(x2i/nx,2):NAN, kxout=nx?(x4o/nx)/pow(x2o/nx,2):NAN;
    printf("align=%.2e nan=%d | NOISE-ONLY(%d fr): NA=%.2f dB LKR=%.3f iso_in=%.4f iso_out=%.4f flicker=%.3f | ",
        maxalign,nan,nno,DB(ws/wo),log(kout/kin),(double)iso_in/nc,(double)iso_out/nc,flick/gsum);
    if(scen==0)
        printf("SPEECH(%d fr, aepfN=1 %.0f%%): SA=%.2f dB SDR=%.2f dB dSNR=%.2f dB | SPFREE cells(%ld): NA=%.2f LKR=%.3f iso_in=%.4f iso_out=%.4f\n",
            nsp,100.0*nsp_ae1/(nsp?nsp:1),DB(ss/so),DB(ss/sd),DB(so/sp_wo)-DB(ss/sp_ws),nx,DB(xs_ws/xs_wo),log(kxout/kxin),(double)iso_in_x/(ncells_x?ncells_x:1),(double)iso_out_x/(ncells_x?ncells_x:1));
    else {
        /* tone loss at tone bins (+-2 bins) after t>3s */
        double ti[2]={0,0}, to[2]={0,0}; double fr[2]={700,1500};
        for(int t=0;t<nfr;t++){ double tsec=(t*INCR+FSIZE/2)/(double)FS; if(tsec<3.0) continue;
            for(int q=0;q<2;q++){ int kc=(int)(fr[q]*FSIZE/FS+0.5); for(k=kc-2;k<=kc+2;k++){ size_t ix=(size_t)t*MS+k; ti[q]+=PS[ix]; to[q]+=G[ix]*G[ix]*PS[ix]; } } }
        printf("TONE: loss700=%.2f dB loss1500=%.2f dB\n",DB(ti[0]/to[0]),DB(ti[1]/to[1]));
    }
    return 0;
}
