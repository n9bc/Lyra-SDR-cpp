// Driver: real WDSP emnr (xemnr full path) with RXA defaults.
// Phase 1: Gaussian noise T1 s; Phase 2: exact zeros Z s; Phase 3: noise T3 s.
// Metrics: NR noise suppression (out/in power, dB) in steady state before and after
// the silence; lambda_d / true per-bin noise power (dB, median over bins);
// NaN counts in estimator state; frames since sigma2N last changed.
#include "comm.h"
#include <stdint.h>

static uint64_t rs = 0x9E3779B97F4A7C15ull;
static double urand(void){ rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return ((rs >> 11) + 0.5) * (1.0/9007199254740992.0); }
static double grand(void){ double u1=urand(), u2=urand(); return sqrt(-2.0*log(u1))*cos(2*PI*u2); }

static int cmpd(const void*a,const void*b){ double x=*(const double*)a,y=*(const double*)b; return (x>y)-(x<y); }

int main(int argc, char** argv)
{
	if (getenv("FTZ")) { uint64_t f; __asm__ volatile("mrs %0, fpcr":"=r"(f)); f |= (1ull<<24); __asm__ volatile("msr fpcr, %0"::"r"(f)); }
	double Z = argc > 1 ? atof(argv[1]) : 2.0;
	int npe = argc > 2 ? atoi(argv[2]) : 0;
	if (argc > 4) { rs = 0x9E3779B97F4A7C15ull ^ (uint64_t)atoll(argv[4]) * 0x2545F4914F6CDD1Dull; }
	double T1 = 15.0, T3 = argc > 3 ? atof(argv[3]) : 60.0;
	double sig = 1.0e-3;               // noise rms per sample (real channel)
	int rate = 48000, bsize = 1024, fsize = 4096, ovrlp = 4;
	double *buf = (double*)malloc0(2 * bsize * sizeof(double));
	double *inb = (double*)malloc0(2 * bsize * sizeof(double));
	EMNR a = create_emnr(1, 0, bsize, buf, buf, fsize, ovrlp, rate, 0, 1.0, 2, npe, 1);
	// expected per-bin noise power: sig^2 * sum(window^2)
	double w2 = 0; for (int i = 0; i < fsize; i++) w2 += (double)a->window[i] * a->window[i];
	double truelam = sig * sig * w2;
	long n1 = (long)(T1 * rate) / bsize, n2 = (long)(Z * rate) / bsize, n3 = (long)(T3 * rate) / bsize;
	long ntot = n1 + n2 + n3;
	double pin1=0,pout1=0,pin3a=0,pout3a=0,pin3b=0,pout3b=0;
	double *prevs = (double*)malloc(a->msize * sizeof(double));
	double *ld = (double*)malloc(a->msize * sizeof(double));
	long last_change_blk = -1;
	int delay = fsize; // skip transient of block alignment
	for (long b = 0; b < ntot; b++)
	{
		int phase = b < n1 ? 1 : (b < n1 + n2 ? 2 : 3);
		for (int i = 0; i < bsize; i++)
		{
			double x = (phase == 2) ? (getenv("P2") ? atof(getenv("P2")) * sig * grand() : 0.0) : sig * grand();
			buf[2*i] = x; buf[2*i+1] = 0.0; inb[2*i] = x;
		}
		double *s2 = npe == 0 ? (double*)a->np.sigma2N : (double*)a->nps.sigma2N;
		for (int k = 0; k < a->msize; k++) prevs[k] = s2[k];
		xemnr(a, 0);
		int changed = 0;
		for (int k = 0; k < a->msize; k++) if (memcmp(&prevs[k], &s2[k], sizeof(double))) { changed = 1; break; }
		if (changed) last_change_blk = b;
		double pi = 0, po = 0;
		for (int i = 0; i < bsize; i++) { pi += inb[2*i]*inb[2*i]; po += buf[2*i]*buf[2*i]; }
		(void)delay;
		long b3 = b - n1 - n2;
		if (phase == 1 && b >= n1 - (long)(5.0*rate/bsize)) { pin1 += pi; pout1 += po; }
		if (phase == 3 && b3 >= (long)(5.0*rate/bsize) && b3 < (long)(10.0*rate/bsize)) { pin3a += pi; pout3a += po; }
		if (phase == 3 && b3 >= n3 - (long)(5.0*rate/bsize)) { pin3b += pi; pout3b += po; }
		if (b == n1 - 1 || b == n1 + n2 - 1 || b == ntot - 1)
		{
			int nan = 0, neg = 0, m = 0;
			for (int k = 0; k < a->msize; k++) {
				double v = a->g.lambda_d[k];
				if (v != v) nan++;
				if (k >= 16 && k < a->msize - 16) ld[m++] = v;
			}
			qsort(ld, m, sizeof(double), cmpd);
			double med = ld[m/2];
			int pnan = 0;
			if (npe == 0) for (int k = 0; k < a->msize; k++) { if (a->np.p[k] != a->np.p[k]) pnan++; if (a->np.p2bar[k] - a->np.pbar[k]*a->np.pbar[k] < 0) neg++; }
			// mean mask
			double mm = 0; for (int k = 16; k < a->msize - 16; k++) mm += a->mask[k]; mm /= (a->msize - 32);
			printf("  end-phase%d blk=%ld: lambda_d median=%.3e (%.1f dB re true), lambda_d NaN=%d, p NaN=%d, varHat<0 bins=%d, mean mask=%.3f, sigma2N last changed blk %ld\n",
				phase, b, med, 10*log10(med/truelam), nan, pnan, neg, mm, last_change_blk);
		}
	}
	printf("  suppression: pre-silence %.2f dB | post 5-10s %.2f dB | post last 5s %.2f dB | sigma2N frozen for %ld blocks at end\n",
		10*log10(pout1/pin1), 10*log10(pout3a/pin3a), 10*log10(pout3b/pin3b), ntot - 1 - last_change_blk);
	destroy_emnr(a);
	return 0;
}
