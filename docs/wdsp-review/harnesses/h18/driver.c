/* Harness for WDSP 2.11 phrot.c finding 18.
 * Built three ways: orig (WDSP as shipped), keep (fix 2 only: no state zeroing,
 * original 15 s A/B tuner), fixed (fix 2 + fix 1: paired shadow chains). */
#include "phrot.c"
#include <fftw3.h>

struct txa_stub txa[1];

#define RATE 48000
#define SIZE 256
#define NST  8

/* ---------------- deterministic RNG ---------------- */
typedef struct { uint64_t s; } rng_t;
static uint64_t rnext(rng_t *r){ uint64_t x=r->s; x^=x>>12; x^=x<<25; x^=x>>27; r->s=x; return x*2685821657736338717ULL; }
static double runi(rng_t *r){ return (rnext(r)>>11)*(1.0/9007199254740992.0); }
static double rgauss(rng_t *r){ double u=runi(r)+1e-300,v=runi(r); return sqrt(-2*log(u))*cos(TWOPI*v); }

/* ---------------- speech-like synthesizer (streaming) ----------------
 * Rosenberg glottal-flow-derivative pulses (asymmetric, sharp closure) ->
 * 4 cascaded formant resonators -> 80 Hz mic high-pass.  Syllables with
 * raised-cosine envelopes, inter-syllable gaps, occasional fricative noise,
 * phrase pauses.  Talker parameters fixed per talker id. */
static const double VOW[5][4]={{730,1090,2440,3400},{530,1840,2480,3500},{270,2290,3010,3700},{570,840,2410,3300},{300,870,2240,3300}};
typedef struct {
    rng_t r; double rate;
    double f0, oq, sq, fscale, bwscale, gain;
    /* segment state */
    int seg_left, seg_type, seg_len, syl_in_phrase;
    double seg_amp, f0_slope, f0_cur;
    double res_a1[4], res_a2[4], res_g[4], res_y1[4], res_y2[4];
    double ph; double T; double jit;
    double hp_x1, hp_y1, hp_c;
    double fr_x1;
} synth_t;

static void syn_set_vowel(synth_t *s){
    int v=(int)(runi(&s->r)*5)%5; int k;
    for(k=0;k<4;k++){
        double f=VOW[v][k]*s->fscale*(1+0.05*rgauss(&s->r));
        double bw=(60+40*k)*s->bwscale;
        double rr=exp(-PI*bw/s->rate), th=TWOPI*f/s->rate;
        s->res_a1[k]=2*rr*cos(th); s->res_a2[k]=-rr*rr; s->res_g[k]=1-2*rr*cos(th)+rr*rr;
    }
}
static void syn_init(synth_t *s, int talker, uint64_t audio_seed, double rate){
    rng_t tr={0x9E3779B97F4A7C15ULL ^ (uint64_t)(talker*7919+1)};
    int i; for(i=0;i<5;i++) rnext(&tr);
    memset(s,0,sizeof(*s));
    s->rate=rate;
    s->r.s=audio_seed*0xD1B54A32D192ED03ULL+0x1234567ULL; for(i=0;i<5;i++) rnext(&s->r);
    s->f0=85+130*runi(&tr);            /* 85..215 Hz */
    s->oq=0.45+0.25*runi(&tr);          /* open quotient */
    s->sq=1.5+2.0*runi(&tr);            /* speed quotient Tp/Tn */
    s->fscale=0.85+0.35*runi(&tr);
    s->bwscale=0.7+0.8*runi(&tr);
    s->gain=1.0;
    if(talker>=100){ s->bwscale=2.0+1.0*runi(&tr); s->sq=3.0+1.5*runi(&tr); s->oq=0.4+0.15*runi(&tr); }  /* high-asymmetry family */
    s->hp_c=exp(-TWOPI*80/rate);
    s->seg_left=0; s->seg_type=0; s->syl_in_phrase=0;
    s->T=rate/s->f0; s->ph=0;
    syn_set_vowel(s);
}
static double syn_next(synth_t *s){
    double x=0, env=1; int k;
    if(s->seg_left<=0){
        /* choose next segment: 0 = pause, 1 = voiced syllable, 2 = gap, 3 = fricative */
        if(s->seg_type==1){
            if(runi(&s->r)<0.2){ s->seg_type=3; s->seg_len=(int)((0.06+0.08*runi(&s->r))*s->rate); }
            else { s->seg_type=2; s->seg_len=(int)((0.03+0.09*runi(&s->r))*s->rate); }
        } else {
            if(s->syl_in_phrase<=0 && s->seg_type!=0){ s->seg_type=0; s->seg_len=(int)((0.4+0.8*runi(&s->r))*s->rate); s->syl_in_phrase=3+(int)(runi(&s->r)*6); }
            else { s->seg_type=1; s->seg_len=(int)((0.12+0.23*runi(&s->r))*s->rate); s->syl_in_phrase--;
                   s->seg_amp=0.5+0.5*runi(&s->r); s->f0_cur=s->f0*(1+0.15*rgauss(&s->r)); s->f0_slope=-0.3*runi(&s->r); syn_set_vowel(s); }
        }
        s->seg_left=s->seg_len;
    }
    {
        int pos=s->seg_len-s->seg_left;
        double tt=(double)pos/s->seg_len;
        if(s->seg_type==1){
            double a=0.02*s->rate, d=0.04*s->rate;
            env = pos<a ? 0.5*(1-cos(PI*pos/a)) : (s->seg_left<d ? 0.5*(1-cos(PI*s->seg_left/d)) : 1.0);
            env*=s->seg_amp;
            /* glottal source */
            {
                double T=s->T, Tp=s->oq*T*s->sq/(1+s->sq), Tn=s->oq*T/(1+s->sq), t=s->ph, g;
                if(t<Tp) g=0.5*PI/Tp*sin(PI*t/Tp);
                else if(t<Tp+Tn) g=-(PI/(2*Tn))*sin(PI*(t-Tp)/(2*Tn));
                else g=0;
                x=g*T*0.05*env;
                s->ph+=1.0;
                if(s->ph>=T){ s->ph-=T; s->T=s->rate/(s->f0_cur*(1+s->f0_slope*tt)*(1+0.01*rgauss(&s->r))); }
            }
            for(k=0;k<4;k++){ double y=s->res_g[k]*x+s->res_a1[k]*s->res_y1[k]+s->res_a2[k]*s->res_y2[k]; s->res_y2[k]=s->res_y1[k]; s->res_y1[k]=y; x=y; }
        } else {
            for(k=0;k<4;k++){ double y=s->res_a1[k]*s->res_y1[k]+s->res_a2[k]*s->res_y2[k]; s->res_y2[k]=s->res_y1[k]; s->res_y1[k]=y; x=y; }
            if(s->seg_type==3){ double n=rgauss(&s->r)*0.03*sin(PI*tt); x+= n - s->fr_x1; s->fr_x1=n; }
        }
    }
    s->seg_left--;
    { double y=s->hp_c*(s->hp_y1+x-s->hp_x1); s->hp_x1=x; s->hp_y1=y; return (double)(float)(y*s->gain); }
}
/* calibrate gain so the long-term peak is about 0.5 */
static double syn_calib(int talker){
    synth_t s; syn_init(&s,talker,999,RATE); double p=0; long i;
    for(i=0;i<RATE*20;i++){ double v=fabs(syn_next(&s)); if(v>p)p=v; }
    return 0.5/p;
}

/* ---------------- plain allpass chain (identical recursion to xphrot) ---------------- */
typedef struct { double b0; double x0[NST],x1[NST],y0[NST],y1[NST]; } ap_t;
static void ap_init(ap_t *c,double fc){ double g=tan(PI*fc/RATE); memset(c,0,sizeof(*c)); c->b0=(g-1)/(g+1); }
static inline double ap_step(ap_t *c,double in){ int n; c->x0[0]=in;
    for(n=0;n<NST;n++){ if(n>0)c->x0[n]=c->y0[n-1]; c->y0[n]=c->b0*c->x0[n]+1.0*c->x1[n]-c->b0*c->y1[n]; c->y1[n]=c->y0[n]; c->x1[n]=c->x0[n]; }
    return c->y0[NST-1]; }

/* RBJ biquad for a 300-3000 Hz band-limited view of errors */
typedef struct { double b0,b1,b2,a1,a2,x1,x2,y1,y2; } bq_t;
static void bq_set(bq_t*q,int hp,double f,double Q){ double w=TWOPI*f/RATE,al=sin(w)/(2*Q),c=cos(w),a0=1+al; memset(q,0,sizeof(*q));
    if(hp){q->b0=(1+c)/2/a0;q->b1=-(1+c)/a0;q->b2=(1+c)/2/a0;} else {q->b0=(1-c)/2/a0;q->b1=(1-c)/a0;q->b2=(1-c)/2/a0;}
    q->a1=-2*c/a0;q->a2=(1-al)/a0; }
static inline double bq(bq_t*q,double x){ double y=q->b0*x+q->b1*q->x1+q->b2*q->x2-q->a1*q->y1-q->a2*q->y2; q->x2=q->x1;q->x1=x;q->y2=q->y1;q->y1=y;return y; }

static PHROT mk(double fc){
    double *buf=(double*)calloc(2*SIZE,sizeof(double));
    PHROT a=create_phrot(1,SIZE,buf,buf,RATE,fc,NST);
    return a;
}

/* ================= E1: switch mechanism, transient vs a 10 ms crossfade reference =================
 * Variants at a block-aligned instant s (old fc -> new fc):
 *   PHROT : the build's own recalc_fc() called on a real phrot object (orig = zero state, keep/fixed = keep state)
 *   zero  : emulated state zeroing           keep : emulated keep-state coefficient change
 *   copy  : hard switch to a shadow chain that ran at new fc (skeptic's "seamless" state copy)
 *   xfade : 10 ms raised-cosine crossfade (the reference itself; error is 0 by construction)
 * Click metric: peak of the 300-3000 Hz band-limited (actual - xfade reference) over 100 ms, dB re 0.5 (talker peak).
 * Tone extra: peak output above 3 kHz (4th-order HP) in the 50 ms after s, vs the same before s. */
#define W1 (RATE/10)
#define FADE ((int)(0.010*RATE))
static double fadew(int j){ return j>=FADE?1.0:0.5*(1.0-cos(PI*(double)(j+1)/(double)(FADE+1))); }
static void e1(const char *tag, double fc_old, double fc_new, int sig){
    long N=(long)(32.0*RATE), i; double *x=(double*)malloc(N*sizeof(double)), *yo=(double*)malloc(N*sizeof(double)), *yn=(double*)malloc(N*sizeof(double));
    synth_t sy; if(sig){ syn_init(&sy,3,4242,RATE); sy.gain=syn_calib(3); }
    for(i=0;i<N;i++) x[i]= sig? syn_next(&sy) : 0.5*sin(TWOPI*200*i/RATE)+0.3*sin(TWOPI*700*i/RATE+1.0);
    ap_t O,Nw; ap_init(&O,fc_old); ap_init(&Nw,fc_new);
    for(i=0;i<N;i++){ yo[i]=ap_step(&O,x[i]); yn[i]=ap_step(&Nw,x[i]); }
    int ninst = sig? 80 : 3, k, v; const char *vn[5]={"PHROT","zero","keep","copy","xfade"};
    double res[5][80], resh[5][80]; int nvalid=0; double hf_pre=0, hf_post[5]={0,0,0,0,0}; double maxdiff_phrot_vs_emul=0;
    for(k=0;k<ninst;k++){
        long s = ((long)((1.0 + k*(sig?0.37:3.1))*RATE))/SIZE*SIZE;
        double ers=0; for(i=s;i<s+W1;i++){ double r=(1-fadew(i-s))*yo[i]+fadew(i-s)*yn[i]; ers+=r*r; }
        if(sig && sqrt(ers/W1) < 0.5*0.0316) continue;   /* skip windows quieter than -30 dB re 0.5 */
        /* old chain state at s */
        ap_t Os; ap_init(&Os,fc_old); for(i=0;i<s;i++) ap_step(&Os,x[i]);
        /* real phrot */
        PHROT A=mk(fc_old); double *ya=(double*)malloc(W1*sizeof(double)); long t;
        for(t=0;t<s+W1;t+=SIZE){ int j; if(t==s) recalc_fc(A,fc_new);
            for(j=0;j<SIZE;j++){A->in[2*j]=x[t+j];A->in[2*j+1]=0;} xphrot(A);
            for(j=0;j<SIZE;j++) if(t+j>=s && t+j<s+W1) ya[t+j-s]=A->out[2*j]; }
        destroy_phrot(A);
        for(v=0;v<5;v++){
            ap_t C=Os; if(v==1){ memset(C.x0,0,sizeof C.x0);memset(C.x1,0,sizeof C.x1);memset(C.y0,0,sizeof C.y0);memset(C.y1,0,sizeof C.y1);} 
            C.b0=Nw.b0;
            bq_t h,l; bq_set(&h,1,300,.707); bq_set(&l,0,3000,.707);
            bq_t g1,g2; bq_set(&g1,1,3000,.5412); bq_set(&g2,1,3000,1.3066);
            double pk=0, hf=0, pkh=0; bq_t e1h,e2h; bq_set(&e1h,1,3000,.5412); bq_set(&e2h,1,3000,1.3066);
            /* prime the HF filter with 20 ms of pre-switch output for the tone metric */
            if(!sig){ for(i=s-RATE/50;i<s;i++){ double z=bq(&g2,bq(&g1,yo[i])); if(i>s-RATE/100 && fabs(z)>hf_pre) hf_pre=fabs(z);} }
            for(i=s;i<s+W1;i++){
                double r=(1-fadew(i-s))*yo[i]+fadew(i-s)*yn[i], y;
                if(v==0) y=ya[i-s];
                else if(v==1||v==2) y=ap_step(&C,x[i]);
                else if(v==3) y=yn[i];
                else y=r;
                if(v==1||v==2){ /* cross-check emulation against the real phrot of this build */ }
                double e=bq(&l,bq(&h,y-r)); if(fabs(e)>pk)pk=fabs(e);
                { double eh=bq(&e2h,bq(&e1h,y-r)); if(fabs(eh)>pkh)pkh=fabs(eh); }
                if(!sig && i<s+RATE/20){ double z=bq(&g2,bq(&g1,y)); if(fabs(z)>hf)hf=fabs(z); }
            }
            res[v][nvalid]=20*log10(pk/0.5+1e-15); resh[v][nvalid]=20*log10(pkh/0.5+1e-15);
            if(hf>hf_post[v]) hf_post[v]=hf;
        }
        /* cross-check: PHROT must equal zero (orig) or keep (keep/fixed) emulation */
        { ap_t Z=Os, K=Os; memset(Z.x0,0,sizeof Z.x0);memset(Z.x1,0,sizeof Z.x1);memset(Z.y0,0,sizeof Z.y0);memset(Z.y1,0,sizeof Z.y1); Z.b0=K.b0=Nw.b0;
          double dz=0,dk=0; for(i=s;i<s+W1;i++){ double z=ap_step(&Z,x[i]),kk=ap_step(&K,x[i]); dz=fmax(dz,fabs(z-ya[i-s])); dk=fmax(dk,fabs(kk-ya[i-s])); }
          double m=fmin(dz,dk); if(m>maxdiff_phrot_vs_emul) maxdiff_phrot_vs_emul=m; }
        free(ya); nvalid++;
    }
    printf("E1 %-5s %-6s fc %4.0f->%4.0f  n=%d  click(peak BL err vs 10ms xfade, dB re 0.5) median/max:", tag, sig?"speech":"tone", fc_old, fc_new, nvalid);
    for(v=0;v<4;v++){ double a[80]; int j,m; memcpy(a,res[v],nvalid*sizeof(double));
        for(j=1;j<nvalid;j++){ double q=a[j]; m=j-1; while(m>=0&&a[m]>q){a[m+1]=a[m];m--;} a[m+1]=q; }
        printf("  %s %.1f/%.1f", vn[v], a[nvalid/2], a[nvalid-1]); }
    printf("\n      click HF (peak >3kHz of err vs xfade, dB re 0.5) median/max:");
    for(v=0;v<4;v++){ double a[80]; int j,m; memcpy(a,resh[v],nvalid*sizeof(double));
        for(j=1;j<nvalid;j++){ double q=a[j]; m=j-1; while(m>=0&&a[m]>q){a[m+1]=a[m];m--;} a[m+1]=q; }
        printf("  %s %.1f/%.1f", vn[v], a[nvalid/2], a[nvalid-1]); }
    if(!sig){ printf("  | HF>3k peak dB re 0.5: pre %.1f, post:", 20*log10(hf_pre/0.5+1e-15)); for(v=0;v<5;v++) printf(" %s %.1f", vn[v], 20*log10(hf_post[v]/0.5+1e-15)); }
    printf("  | PHROT==emulation maxdiff %.1e\n", maxdiff_phrot_vs_emul);
    free(x); free(yo); free(yn);
}

/* ================= E2: tuner running on speech; click per live coefficient event ================= */
static void e2(const char *tag, int talker, double secs){
    long N=(long)(secs*RATE)/SIZE*SIZE, s,i;
    float *xin=(float*)malloc(N*sizeof(float)), *yout=(float*)malloc(N*sizeof(float));
    PHROT A=mk(338.0); synth_t sy; syn_init(&sy,talker,1000+talker,RATE); sy.gain=syn_calib(talker);
    txa[0].phrot.p=A; SetTXAPHROTAutoMode(0,1);
    static long ev_s[4096]; static double ev_fc[4096], ev_fcold[4096]; int nev=0;
    for(s=0;s<N;s+=SIZE){
        double fcb=A->fc; int cnt_before=A->optim_samp_count;
        for(i=0;i<SIZE;i++){ double x=syn_next(&sy); xin[s+i]=(float)x; A->in[2*i]=x; A->in[2*i+1]=0; }
        xphrot(A);
        for(i=0;i<SIZE;i++) yout[s+i]=(float)A->out[2*i];
        int event = (A->fc!=fcb);
#ifndef FIXEDBUILD
        /* the original tuner calls recalc_fc on every optimizer step, even when fc does not change */
        event = event || (A->optim_samp_count==0 && cnt_before+SIZE>=A->optim_interval);
#endif
        if(event && nev<4096 && s+SIZE>RATE && s+SIZE+W1<N){ ev_s[nev]=s+SIZE; ev_fc[nev]=A->fc; ev_fcold[nev]=fcb; nev++; }
    }
    int k; static double pks[4096], pkh_s[4096]; int n30=0,n40=0; double worst=-300;
    for(k=0;k<nev;k++){
        long s0=ev_s[k]; ap_t O,Nw; ap_init(&O,ev_fcold[k]); ap_init(&Nw,ev_fc[k]);
        for(i=s0-RATE;i<s0;i++){ ap_step(&O,(double)xin[i]); ap_step(&Nw,(double)xin[i]); }
        bq_t h,l; bq_set(&h,1,300,.707); bq_set(&l,0,3000,.707); double pk=0, pkh=0;
        bq_t g1,g2; bq_set(&g1,1,3000,.5412); bq_set(&g2,1,3000,1.3066);
        for(i=s0;i<s0+W1;i++){ double r=(1-fadew(i-s0))*ap_step(&O,(double)xin[i])+fadew(i-s0)*ap_step(&Nw,(double)xin[i]);
            double e=bq(&l,bq(&h,(double)yout[i]-r)); if(fabs(e)>pk)pk=fabs(e);
            double eh=bq(&g2,bq(&g1,(double)yout[i]-r)); if(fabs(eh)>pkh)pkh=fabs(eh); }
        pks[k]=20*log10(pk/0.5+1e-15); pkh_s[k]=20*log10(pkh/0.5+1e-15); if(pks[k]>worst)worst=pks[k]; if(pks[k]>-30)n30++; if(pks[k]>-40)n40++;
    }
    for(k=1;k<nev;k++){ double v=pks[k]; int j=k-1; while(j>=0&&pks[j]>v){pks[j+1]=pks[j];j--;} pks[j+1]=v; }
    double wh=-300; for(k=0;k<nev;k++) if(pkh_s[k]>wh) wh=pkh_s[k];
    for(k=1;k<nev;k++){ double v=pkh_s[k]; int j=k-1; while(j>=0&&pkh_s[j]>v){pkh_s[j+1]=pkh_s[j];j--;} pkh_s[j+1]=v; }
    printf("E2 %-5s talker %d %.0fs: live coefficient events %d, final fc %.1f converged %d | click (peak BL err vs 10ms xfade, dB re 0.5): median %.1f worst %.1f; events > -40 dB: %d, > -30 dB: %d | HF>3k click median %.1f worst %.1f\n",
           tag, talker, secs, nev, A->fc, A->auto_converged, nev?pks[nev/2]:-300, worst, n40, n30, nev?pkh_s[nev/2]:-300, wh);
    free(xin); free(yout); destroy_phrot(A);
}

/* ================= objective landscapes (asymmetry and SSB analytic-envelope crest) ================= */
static int LAND_SEED=50000; static int NGRID; static double GRID[200];
static void mkgrid(void){ double f; NGRID=0; for(f=50;f<=600;f+=10) GRID[NGRID++]=f; for(f=650;f<=2000;f+=50) GRID[NGRID++]=f; }

/* mean voiced-block raw asymmetry with phrot's own envelope trackers and the paired gate */
static double asym_obj(const float *x, long N, double fc, int bypass){
    ap_t c; ap_init(&c,fc); double dt=(double)SIZE/RATE, ca=exp(-dt/PHROT_ATTACK_SECS), cd=exp(-dt/PHROT_DECAY_SECS), cg=exp(-dt/3.0);
    double ep=0,en=0,gp=0,sum=0; long nv=0,s; int i;
    for(s=0;s+SIZE<=N;s+=SIZE){
        double bp=0,bn=0,ip=0;
        for(i=0;i<SIZE;i++){ double in=x[s+i]; double y= bypass? in : ap_step(&c,in); if(y>bp)bp=y; if(-y>bn)bn=-y; if(fabs(in)>ip)ip=fabs(in); }
        double cp=bp>ep?ca:cd, cn=bn>en?ca:cd; ep=cp*ep+(1-cp)*bp; en=cn*en+(1-cn)*bn;
        double d=ep+en, raw=d>1e-20?fabs(ep-en)/d:0;
        gp = ip>gp? ip : cg*gp;
        if(s>RATE/2 && ip>0.3*gp && ip>1e-3){ sum+=raw; nv++; }
    }
    return sum/(nv?nv:1);
}
/* 300-2700 Hz analytic-envelope crest: peak (max and 99.99 pct) over RMS, and real-waveform crest */
static fftw_complex *FB; static fftw_plan PF,PB; static long FN;
static int cmpd(const void*a,const void*b){ double x=*(double*)a,y=*(double*)b; return x<y?-1:x>y; }
static void crest(const float *x, long N, double fc, int bypass, double *env_max_db, double *env_p9999_db, double *real_db){
    ap_t c; ap_init(&c,fc); long i;
    for(i=0;i<FN;i++){ double in=i<N?x[i]:0; FB[i][0]= bypass?in:ap_step(&c,in); FB[i][1]=0; }
    fftw_execute(PF);
    for(i=0;i<FN;i++){ double f=(double)i*RATE/FN; double m = (i<FN/2 && f>=300 && f<=2700) ? 2.0/FN : 0.0; FB[i][0]*=m; FB[i][1]*=m; }
    fftw_execute(PB);
    double *e=(double*)malloc(N*sizeof(double)); double pk=0,ss=0,rpk=0,rss=0;
    for(i=RATE/2;i<N;i++){ double re=FB[i][0],im=FB[i][1],m=sqrt(re*re+im*im); e[i-RATE/2]=m; if(m>pk)pk=m; ss+=m*m; if(fabs(re)>rpk)rpk=fabs(re); rss+=re*re; }
    long M=N-RATE/2; double rms=sqrt(ss/M), rrms=sqrt(rss/M);
    qsort(e,M,sizeof(double),cmpd);
    *env_max_db=20*log10(pk/rms); *env_p9999_db=20*log10(e[(long)(0.9999*M)]/rms); *real_db=20*log10(rpk/rrms);
    free(e);
}

static void landscape(int talker, double secs, double *Jopt_fc, double *Jopt, double *J, int print){
    long N=(long)(secs*RATE), i; float *x=(float*)malloc(N*sizeof(float));
    synth_t sy; syn_init(&sy,talker,LAND_SEED+talker,RATE); sy.gain=syn_calib(talker);
    for(i=0;i<N;i++) x[i]=(float)syn_next(&sy);
    int g; double best=1e9,bf=0;
    for(g=0;g<NGRID;g++){ J[g]=asym_obj(x,N,GRID[g],0); if(J[g]<best){best=J[g];bf=GRID[g];} }
    *Jopt=best; *Jopt_fc=bf;
    if(print){
        double Jb=asym_obj(x,N,0,1);
        FN=1; while(FN<N) FN<<=1;
        FB=fftw_alloc_complex(FN); PF=fftw_plan_dft_1d((int)FN,FB,FB,FFTW_FORWARD,FFTW_ESTIMATE); PB=fftw_plan_dft_1d((int)FN,FB,FB,FFTW_BACKWARD,FFTW_ESTIMATE);
        double em,e9,rd, bem,be9,brd, cbest=1e9,cfc=0, cbest9=1e9,cfc9=0; double em_asym=0,e9_asym=0,rd_asym=0, em338=0,e9338=0,rd338=0; double rbest=1e9, rfc=0;
        crest(x,N,0,1,&bem,&be9,&brd);
        for(g=0;g<NGRID;g++){
            crest(x,N,GRID[g],0,&em,&e9,&rd);
            if(em<cbest){cbest=em;cfc=GRID[g];} if(e9<cbest9){cbest9=e9;cfc9=GRID[g];} if(rd<rbest){rbest=rd;rfc=GRID[g];}
            if(GRID[g]==bf){em_asym=em;e9_asym=e9;rd_asym=rd;}
            if(GRID[g]==340){em338=em;e9338=e9;rd338=rd;}
        }
        printf("L talker %d: asym(no rot)=%.3f asym@340=%.3f asym min=%.3f @%.0f Hz | SSB env crest dB [max / p99.99]: no-rot %.2f/%.2f, @340 %.2f/%.2f, @asym-opt %.2f/%.2f, best-max %.2f@%.0f, best-p9999 %.2f@%.0f | real-wave crest: no-rot %.2f, @asym-opt %.2f, best %.2f@%.0f\n",
               talker, Jb, J[29], best, bf, bem,be9, em338,e9338, em_asym,e9_asym, cbest,cfc, cbest9,cfc9, brd, rd_asym, rbest, rfc);
        fftw_destroy_plan(PF); fftw_destroy_plan(PB); fftw_free(FB);
    }
    free(x);
}
static double interpJ(const double *J,double fc){ int g; for(g=0;g<NGRID-1;g++) if(fc<=GRID[g+1]){ double t=(fc-GRID[g])/(GRID[g+1]-GRID[g]); return J[g]*(1-t)+J[g+1]*t; } return J[NGRID-1]; }

/* ================= E3: convergence and repeatability ================= */
static void e3(const char *tag, int talker, int nseeds, double maxsecs){
    double J[200], Jopt, Jfc; landscape(talker, 60, &Jfc, &Jopt, J, 0);
    int k; double sumt=0, sumex=0, worst_ex=0; int nconv=0; long nswitch_tot=0;
    printf("E3 %-6s talker %d: grid optimum fc=%.0f J*=%.4f, J(338)=%.4f (+%.1f%%)\n", tag, talker, Jfc, Jopt, interpJ(J,338), 100*(interpJ(J,338)/Jopt-1));
    for(k=0;k<nseeds;k++){
        PHROT A=mk(338.0); txa[0].phrot.p=A; SetTXAPHROTAutoMode(0,1);
        synth_t sy; syn_init(&sy,talker,7000+97*k,RATE); sy.gain=syn_calib(talker);
        long s, N=(long)(maxsecs*RATE); int i; double tconv=-1; long nsw=0; double fcprev=A->fc;
        for(s=0;s<N;s+=SIZE){
            for(i=0;i<SIZE;i++){ A->in[2*i]=syn_next(&sy); A->in[2*i+1]=0; }
            xphrot(A);
            if(A->fc!=fcprev){ nsw++; fcprev=A->fc; }
            if(A->auto_converged){ tconv=(double)(s+SIZE)/RATE; break; }
        }
        double ex=100*(interpJ(J,A->fc)/Jopt-1);
        printf("   seed %2d: final fc %7.1f  converged %s t=%6.1f s  coefficient changes %ld  objective excess over grid optimum %+.2f%%\n",
               k, A->fc, tconv>0?"yes":"NO ", tconv>0?tconv:maxsecs, nsw, ex);
        if(tconv>0){ nconv++; sumt+=tconv; }
        sumex+=ex; if(ex>worst_ex)worst_ex=ex; nswitch_tot+=nsw;
        destroy_phrot(A);
    }
    printf("E3 %-6s talker %d SUMMARY: converged %d/%d, mean time %.1f s, mean excess %.2f%%, worst excess %.2f%%, mean fc changes %.1f\n",
           tag, talker, nconv, nseeds, nconv?sumt/nconv:0, sumex/nseeds, worst_ex, (double)nswitch_tot/nseeds);
}


/* ================= E4: decision-statistic noise, unpaired (original) vs paired ================= */
static void e4(int talker, double fa, double fb, double secs){
    long N=(long)(secs*RATE)/SIZE*SIZE, s; int i;
    synth_t sy; syn_init(&sy,talker,90000+talker,RATE); sy.gain=syn_calib(talker);
    ap_t A,B; ap_init(&A,fa); ap_init(&B,fb);
    double dt=(double)SIZE/RATE, ca=exp(-dt/PHROT_ATTACK_SECS), cd=exp(-dt/PHROT_DECAY_SECS), cf=exp(-dt/PHROT_ASYM_FAST_SECS), cg=exp(-dt/3.0);
    long nb=N/SIZE, b; double *afA=malloc(nb*sizeof(double)), *afB=malloc(nb*sizeof(double)), *rA=malloc(nb*sizeof(double)), *rB=malloc(nb*sizeof(double)); char *vo=malloc(nb);
    double epA=0,enA=0,epB=0,enB=0,fA=0,fB=0,gp=0; long nvoiced=0;
    for(b=0;b<nb;b++){
        double pa=0,na=0,pb=0,nbk=0,ip=0;
        for(i=0;i<SIZE;i++){ double x=syn_next(&sy), ya=ap_step(&A,x), yb=ap_step(&B,x); if(ya>pa)pa=ya; if(-ya>na)na=-ya; if(yb>pb)pb=yb; if(-yb>nbk)nbk=-yb; if(fabs(x)>ip)ip=fabs(x); }
        double c1=pa>epA?ca:cd, c2=na>enA?ca:cd; epA=c1*epA+(1-c1)*pa; enA=c2*enA+(1-c2)*na;
        c1=pb>epB?ca:cd; c2=nbk>enB?ca:cd; epB=c1*epB+(1-c1)*pb; enB=c2*enB+(1-c2)*nbk;
        double ra=(epA+enA)>1e-20?fabs(epA-enA)/(epA+enA):0, rb=(epB+enB)>1e-20?fabs(epB-enB)/(epB+enB):0;
        fA=cf*fA+(1-cf)*ra; fB=cf*fB+(1-cf)*rb; afA[b]=fA; afB[b]=fB; rA[b]=ra; rB[b]=rb;
        gp = ip>gp? ip : cg*gp; vo[b] = (b*SIZE>RATE/2 && ip>0.3*gp && ip>1e-3); if(vo[b]) nvoiced++;
    }
    /* truth: voiced-mean over the whole run */
    double JA=0,JB=0; for(b=0;b<nb;b++) if(vo[b]){JA+=rA[b];JB+=rB[b];} JA/=nvoiced; JB/=nvoiced; double dtrue=(JA-JB)/JA;
    /* unpaired: asym_fast(A) at t, asym_fast(B) at t+15 s (original A/B); trials every 15 s */
    long L=(long)(PHROT_OPTIM_SECS*RATE/SIZE); double su=0,su2=0; int nu=0, wu=0, cu=0;
    for(b=2*L; b+L<nb; b+=L){ double d=(afA[b]-afB[b+L])/afA[b]; su+=d; su2+=d*d; nu++;
        if((d>0)!=(dtrue>0)) wu++; if((dtrue>0 && d>PHROT_IMPROVE_THRESH)||(dtrue<0 && -d>PHROT_IMPROVE_THRESH)) cu++; }
    /* paired: voiced-mean over the same 2 voiced seconds */
    long need=(long)(2.0*RATE/SIZE); double sp=0,sp2=0; int np=0, wp=0, cpk=0; double mA=0,mB=0; long cnt=0, start=0; double wall=0;
    for(b=RATE/SIZE; b<nb; b++){ if(!vo[b]) continue; if(cnt==0) start=b; mA+=rA[b]; mB+=rB[b]; cnt++;
        if(cnt>=need){ double d=(mA-mB)/mA; sp+=d; sp2+=d*d; np++; wall+=(double)(b-start+1)*SIZE/RATE;
            if((d>0)!=(dtrue>0)) wp++; if((dtrue>0 && d>PHROT_IMPROVE_THRESH)||(dtrue<0 && -d>PHROT_IMPROVE_THRESH)) cpk++; mA=mB=0; cnt=0; } }
    double mu=su/nu, sdu=sqrt(su2/nu-mu*mu), mp=sp/np, sdp=sqrt(sp2/np-mp*mp);
    printf("E4 talker %3d fc %4.0f vs %4.0f: true rel diff %+6.2f%% | UNPAIRED (15 s apart, 1 s EMA): n=%3d mean %+6.2f%% sd %5.2f%% wrong-sign %4.1f%% correct-accept %4.1f%%, 30 s/decision"
           " | PAIRED (same 2 voiced s): n=%3d mean %+6.2f%% sd %5.2f%% wrong-sign %4.1f%% correct-accept %4.1f%%, %.1f s/decision\n",
           talker, fa, fb, 100*dtrue, nu, 100*mu, 100*sdu, 100.0*wu/nu, 100.0*cu/nu, np, 100*mp, 100*sdp, 100.0*wp/np, 100.0*cpk/np, wall/np);
    free(afA);free(afB);free(rA);free(rB);free(vo);
}

int main(int argc, char **argv){
    const char *tag = argc>2? argv[2] : "?";
    mkgrid();
    if(!strcmp(argv[1],"e1")){
        e1(tag,338,288,0); e1(tag,338,338,0); e1(tag,100,50,0); e1(tag,338,288,1); e1(tag,338,338,1); e1(tag,100,50,1); e1(tag,288,338,1);
    } else if(!strcmp(argv[1],"e3")){
        int ns=argc>3?atoi(argv[3]):8; double ms=argc>4?atof(argv[4]):1200; int t;
        for(t=5;t<argc;t++) e3(tag,atoi(argv[t]),ns,ms);
    } else if(!strcmp(argv[1],"land")){
        int t; double J[200],a,b; for(t=3;t<argc;t++) landscape(atoi(argv[t]),60,&a,&b,J,1);
    } else if(!strcmp(argv[1],"e4")){
        int t; static const double P[][2]={{338,288},{338,388},{338,328},{260,320},{200,250},{850,900}};
        for(t=3;t<argc;t++){ int k; for(k=0;k<6;k++) e4(atoi(argv[t]),P[k][0],P[k][1],1800); }
    } else if(!strcmp(argv[1],"jdump")){
        int t,g; double J[200],a,b; for(t=3;t<argc;t++){ landscape(atoi(argv[t]),60,&a,&b,J,0); printf("J talker %s:",argv[t]); for(g=0;g<NGRID;g++) if(GRID[g]<=600? ((int)GRID[g]%30==20):1) printf(" %.0f:%.4f",GRID[g],J[g]); printf("\n"); }
    } else if(!strcmp(argv[1],"jsplit")){
        /* repeatability of the landscape on independent 60 s segments of the same talker */
        int t,g,r; double J[4][200],a[4],b[4];
        for(t=3;t<argc;t++){ for(r=0;r<4;r++){ LAND_SEED=50000+1000*r; landscape(atoi(argv[t]),60,&a[r],&b[r],J[r],0);} 
            printf("talker %s argmin per segment: %.0f %.0f %.0f %.0f |", argv[t], a[0],a[1],a[2],a[3]);
            double sd=0, rng=0; int ng=0; for(g=0;g<NGRID;g++){ if(GRID[g]>600) continue; double m=(J[0][g]+J[1][g]+J[2][g]+J[3][g])/4, v=0; for(r=0;r<4;r++) v+=(J[r][g]-m)*(J[r][g]-m); sd+=sqrt(v/3)/m; ng++; }
            double mx=0,mn=1; for(g=0;g<NGRID;g++){ if(GRID[g]>600) continue; double m=(J[0][g]+J[1][g]+J[2][g]+J[3][g])/4; if(m>mx)mx=m; if(m<mn)mn=m; }
            /* adjacent-step (10 Hz) relative change of the mean landscape, a measure of ruggedness */
            double adj=0; int na=0; for(g=1;g<NGRID;g++){ if(GRID[g]>600) continue; double m0=(J[0][g-1]+J[1][g-1]+J[2][g-1]+J[3][g-1])/4, m1=(J[0][g]+J[1][g]+J[2][g]+J[3][g])/4; adj+=fabs(m1-m0)/m0; na++; }
            printf(" 50-600Hz: mean rel. SD across segments %.1f%%, mean |dJ|/J per 10 Hz step %.1f%%, J range %.4f..%.4f\n", 100*sd/ng, 100*adj/na, mn, mx); }
    } else if(!strcmp(argv[1],"e2")){
        int t; for(t=3;t<argc;t++) e2(tag,atoi(argv[t]),300);
    }
    return 0;
}
