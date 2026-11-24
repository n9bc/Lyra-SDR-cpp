// Harness for finding 12: fircore filter-exchange click. Builds against orig/ or fixed/ firmin.c.
#include "comm.h"
#include <time.h>
extern int fircore_xfade_blocks __attribute__((weak));

static int S = 64, NC = 2048, MP = 0;
static const double RATE = 48000.0;
#define NTOT (48000*2)

static uint64_t rng = 0x1234567887654321ULL;
static double urand(void){ rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return ((rng >> 11) + 0.5) * (1.0/9007199254740992.0); }
static double grand(void){ return sqrt(-2.0*log(urand())) * cos(TWOPI*urand()); }

static double* bp(double fl, double fh){ return fir_bandpass(NC, fl, fh, RATE, 1, 1, 1.0/(2.0*S)); }
static double* notched(double fl, double fh, double nl, double nh){
	double* a = bp(fl, fh); double* b = bp(nl, nh);
	for (int i = 0; i < 2*NC; i++) a[i] -= b[i];
	free(b); return a;
}

typedef struct { int block; double* imp; int via_update; } change;

// run the filter over x (complex, NTOT), applying changes at given block boundaries
static void run(const double* x, double* y, change* ch, int nch, double* imp0){
	double* in = calloc(2*S, sizeof(double)); double* out = calloc(4*S, sizeof(double));
	FIRCORE p = create_fircore(S, in, out, NC, MP, 16, imp0);
	int ci = 0;
	for (int b = 0; b < NTOT/S; b++){
		while (ci < nch && ch[ci].block == b){
			if (ch[ci].via_update){ setImpulse_fircore(p, ch[ci].imp, 0); setUpdate_fircore(p); } // SetRXABandpassFreqs path
			else setImpulse_fircore(p, ch[ci].imp, 1);                                          // nbp lightweight path
			ci++;
		}
		memcpy(in, &x[2*b*S], 2*S*sizeof(double));
		xfircore(p);
		memcpy(&y[2*b*S], out, 2*S*sizeof(double));
	}
	destroy_fircore(p); free(in); free(out);
}

// windowed spectrum metrics around center sample c, window length L (BH 7-term)
static fftw_complex *fin, *fout; static fftw_plan fp; static int L = 2048;
static double bh7(int i, int n){ double c = cos(TWOPI*i/(n-1)); (void)c;
	double a[7]={6.3964424114390378e-02,2.3993864599352804e-01,3.5015956323820469e-01,2.4774111897080783e-01,8.5438256055858031e-02,1.2320203369293225e-02,4.3778825791773474e-04};
	double w=0; for(int k=0;k<7;k++) w += (k&1?-1:1)*a[k]*cos(TWOPI*k*i/(double)(n-1)); return w; }
// returns power (dB re full-scale tone of amplitude 1) in region: sel=0 out-of-band (outside [lo,hi]), sel=1 in-band excluding +/-ex around tones
static void spec(const double* y, int c, double* pw){
	double wsum = 0, w2 = 0;
	for (int i = 0; i < L; i++){ double w = bh7(i, L); wsum += w; w2 += w*w; fin[i][0] = y[2*(c-L/2+i)]*w; fin[i][1] = -y[2*(c-L/2+i)+1]*w; }
	fftw_execute(fp);
	for (int k = 0; k < L; k++) pw[k] = (fout[k][0]*fout[k][0]+fout[k][1]*fout[k][1])/(L*w2);   // Parseval: a full-window tone of amplitude 1 sums to 1 (0 dB)
}
static double fbin(int k){ return (k < L/2 ? k : k - L) * RATE / L; }
static double db(double p){ return 10*log10(p + 1e-300); }

typedef struct { double oob, inb, far, d2; } metr;
// oob: total power at f outside [lo,hi]; inb: power inside [lo,hi] but > ex Hz from any tone; d2: max |second diff| in +/-S*4 around c
static metr measure(const double* y, int c, double lo, double hi, const double* tones, int nt, double ex){
	double pw[8192]; spec(y, c, pw); metr m = {0,0,0,0};
	for (int k = 0; k < L; k++){ double f = fbin(k);
		if (f < lo || f > hi) m.oob += pw[k];
		else { int near = 0; for (int t = 0; t < nt; t++) if (fabs(f - tones[t]) < ex) near = 1; if (!near) m.inb += pw[k]; int nearf = 0; for (int t = 0; t < nt; t++) if (fabs(f - tones[t]) < 1000) nearf = 1; if (!nearf) m.far += pw[k]; } }
	for (int n = c - 4*S; n < c + 4*S; n++){
		double dr = y[2*(n+1)] - 2*y[2*n] + y[2*(n-1)], di = y[2*(n+1)+1] - 2*y[2*n+1] + y[2*(n-1)+1];
		double d = sqrt(dr*dr+di*di); if (d > m.d2) m.d2 = d; }
	m.oob = db(m.oob); m.inb = db(m.inb); m.far = db(m.far); return m;
}

#define PR(name, m, r) printf("%s: oob %7.1f dB (steady %6.1f) | inband>300Hz-from-tone %7.1f dB (steady %6.1f) | inband>1kHz-from-tone %7.1f dB (steady %6.1f) | max|d2| %.4f (steady %.4f)\n", name, m.oob, r.oob, m.inb, r.inb, m.far, r.far, m.d2, r.d2)
static void tone(double* x, double f, double a){ for (int n = 0; n < NTOT; n++){ x[2*n] += a*cos(TWOPI*f*n/RATE); x[2*n+1] -= a*sin(TWOPI*f*n/RATE); } } // WDSP fir_bandpass(fl,fh) passes -fh..-fl (see probe.c), so work in the conjugate domain

int main(int argc, char** argv){
	if (argc > 1) S = atoi(argv[1]);
	if (argc > 2 && &fircore_xfade_blocks) fircore_xfade_blocks = atoi(argv[2]);
	if (argc > 3) MP = atoi(argv[3]);
	int xb = (&fircore_xfade_blocks) ? fircore_xfade_blocks : 0;
	fin = fftw_malloc(sizeof(fftw_complex)*L); fout = fftw_malloc(sizeof(fftw_complex)*L);
	fp = fftw_plan_dft_1d(L, fin, fout, FFTW_FORWARD, FFTW_ESTIMATE);
	double *x = calloc(2*NTOT, sizeof(double)), *y = calloc(2*NTOT, sizeof(double)), *yo = calloc(2*NTOT, sizeof(double));
	int B = 24000 / S;           // switch block (t = 0.5 s)
	int c = B * S;               // switch sample
	int cs = 72000;              // steady-state reference centre
	printf("# build=%s size=%d nc=%d mp=%d xfade_blocks=%d\n", xb ? "fixed" : "orig", S, NC, MP, xb);

	// S1: low edge drag 200 -> 1500 across a 0 dBFS carrier at 1000 Hz (SetRXABandpassFreqs path)
	{ memset(x,0,2*NTOT*sizeof(double)); tone(x, 1000, 1.0);
	  double* i0 = bp(200,3000); change chg = { B, bp(1500,3000), 1 };
	  run(x, y, &chg, 1, i0); run(x, yo, NULL, 0, i0);
	  if (getenv("DUMP")){ FILE* f = fopen(getenv("DUMP"), "wb"); fwrite(y, sizeof(double), 2*NTOT, f); fclose(f); }
	  double t[1]={1000}; metr m = measure(y,c,150,3050,t,1,300), r = measure(yo,cs,150,3050,t,1,300);
	  PR("S1 edge-across-carrier ", m, r); }
	// S2: notch insertion on 0 dBFS carrier (nbp setImpulse(...,1) path)
	{ memset(x,0,2*NTOT*sizeof(double)); tone(x, 1000, 1.0);
	  double* i0 = bp(200,3000); change chg = { B, notched(200,3000,950,1050), 0 };
	  run(x, y, &chg, 1, i0); run(x, yo, NULL, 0, i0);
	  double t[1]={1000}; metr m = measure(y,c,150,3050,t,1,300), r = measure(yo,cs,150,3050,t,1,300);
	  PR("S2 notch-insert        ", m, r); }
	// S3: CW narrowing 300..1300 -> 600..800, wanted 700 Hz @ -20 dB, strong 1100 Hz @ 0 dB
	{ memset(x,0,2*NTOT*sizeof(double)); tone(x, 700, 0.1); tone(x, 1100, 1.0);
	  double* i0 = bp(300,1300); change chg = { B, bp(600,800), 1 };
	  run(x, y, &chg, 1, i0); run(x, yo, NULL, 0, i0);
	  // after narrowing, splatter that lands in the new passband 600..800 around the wanted tone is what the listener hears
	  double t[2]={700,1100}; metr m = measure(y,c,250,1350,t,2,150), r = measure(yo,cs,250,1350,t,2,150);
	  PR("S3 cw-narrow           ", m, r); }
	// S4: edge move 3000 -> 2800 with white noise only (-20 dBFS per complex sample)
	{ rng = 0x1234567887654321ULL; for (int n = 0; n < 2*NTOT; n++) x[n] = 0.1*grand()/sqrt(2.0);
	  double* i0 = bp(200,3000); change chg = { B, bp(200,2800), 1 };
	  run(x, y, &chg, 1, i0); run(x, yo, NULL, 0, i0);
	  metr m = measure(y,c,150,3050,NULL,0,0), r = measure(yo,cs,150,3050,NULL,0,0);
	  PR("S4 edge-in-noise       ", m, r); }
	// S5: continuous drag, low edge 200 -> 1990 Hz in 10 Hz steps, one step per block, across 0 dBFS carrier at 1000 Hz
	{ memset(x,0,2*NTOT*sizeof(double)); tone(x, 1000, 1.0);
	  int nst = 180; change* chg = malloc(nst*sizeof(change));
	  for (int s = 0; s < nst; s++){ chg[s].block = B - nst/2 + s; chg[s].imp = bp(200 + 10*(s+1), 3000); chg[s].via_update = 1; }
	  double* i0 = bp(200,3000);
	  run(x, y, chg, nst, i0); run(x, yo, NULL, 0, i0);
	  double t[1]={1000}; metr m = measure(y,c,150,3050,t,1,300), r = measure(yo,cs,150,3050,t,1,300);
	  PR("S5 continuous-drag     ", m, r); }
	// S6: continuous nbp-style retune: notch tracking a carrier that the VFO moves (notch moves 10 Hz/block, carrier fixed => notch walks off carrier)
	{ memset(x,0,2*NTOT*sizeof(double)); tone(x, 1000, 1.0);
	  int nst = 60; change* chg = malloc(nst*sizeof(change));
	  for (int s = 0; s < nst; s++){ double nc0 = 1000 + 10*(s+1); chg[s].block = B - 5 + s; chg[s].imp = notched(200,3000,nc0-50,nc0+50); chg[s].via_update = 0; }
	  double* i0 = notched(200,3000,950,1050);
	  run(x, y, chg, nst, i0); run(x, yo, NULL, 0, i0);
	  double t[1]={1000}; metr m = measure(y,c,150,3050,t,1,300), r = measure(yo,cs,150,3050,t,1,300);
	  PR("S6 notch-walk-off      ", m, r); }

	// cost: time per xfircore on normal blocks and on exchange blocks
	{ double* in = calloc(2*S,sizeof(double)); double* out = calloc(4*S,sizeof(double));
	  double* ia = bp(200,3000); double* ib = bp(300,3000);
	  FIRCORE p = create_fircore(S, in, out, NC, MP, 16, ia);
	  for (int i = 0; i < 2*S; i++) in[i] = 0.01*i;
	  int N = 20000; struct timespec t0, t1; double tn, tf = 0;
	  clock_gettime(CLOCK_MONOTONIC, &t0); for (int i = 0; i < N; i++) xfircore(p); clock_gettime(CLOCK_MONOTONIC, &t1);
	  tn = ((t1.tv_sec-t0.tv_sec)*1e9 + (t1.tv_nsec-t0.tv_nsec))/N;
	  for (int i = 0; i < 2000; i++){ setImpulse_fircore(p, (i&1)?ia:ib, 0); setUpdate_fircore(p);
	    clock_gettime(CLOCK_MONOTONIC, &t0); xfircore(p); clock_gettime(CLOCK_MONOTONIC, &t1);
	    tf += ((t1.tv_sec-t0.tv_sec)*1e9 + (t1.tv_nsec-t0.tv_nsec)); }
	  printf("COST xfircore ns/block: normal %.0f, exchange-block %.0f\n", tn, tf/2000); }
	return 0;
}
