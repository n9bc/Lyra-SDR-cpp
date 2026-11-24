/* Driver for WDSP nbp.c make_nbp / min_notch_width finding (id=10). Build with -DFIXED for the fixed tree. */
#include "comm.h"
#ifdef FIXED
#define MAKE_NBP(nn,act,c,w,lo,hi,mw,ai,fl,fh,bl,bh,hv) make_nbp(nn,act,c,w,lo,hi,mw,ai,fl,fh,bl,bh,hv,1025)
int make_nbp (int, int*, double*, double*, double*, double*, double, int, double, double, double*, double*, int*, int);
#else
#define MAKE_NBP(nn,act,c,w,lo,hi,mw,ai,fl,fh,bl,bh,hv) make_nbp(nn,act,c,w,lo,hi,mw,ai,fl,fh,bl,bh,hv)
int make_nbp (int, int*, double*, double*, double*, double*, double, int, double, double, double*, double*, int*);
#endif
double min_notch_width (NBP a);
int RXANBPAddNotch (int channel, int notch, double fcenter, double fwidth, int active);
void RXANBPSetNotchesRun (int channel, int run);

static double* buf;
static NBP dummy_snba;

static void setup(int size, int nc, double flow, double fhigh, int wintype, int autoincr)
{
	buf = (double*)malloc0(2 * size * sizeof(complex)); /* like RXA midbuff: fircore crev writes 2*size */
	pthread_mutex_init(&ch[0].csDSP, NULL);
	rxa[0].ndb.p = create_notchdb(0, 1024);
	rxa[0].nbp0.p = create_nbp(1, 0, 0, size, nc, 0, buf, buf, flow, fhigh, 48000, wintype, 1.0, autoincr, 1025, &rxa[0].ndb.p);
	dummy_snba = (NBP)malloc0(sizeof(nbp)); dummy_snba->fnfrun = 0;
	rxa[0].bpsnba.p = (BPSNBA)malloc0(sizeof(bpsnba));
	rxa[0].bpsnba.p->bpsnba = dummy_snba;
	rxa[0].bpsnba.p->wintype = wintype; rxa[0].bpsnba.p->autoincr = autoincr;
}
static void teardown(void)
{
	destroy_nbp(rxa[0].nbp0.p); destroy_notchdb(rxa[0].ndb.p); free(rxa[0].ndb.p);
	free(dummy_snba); free(rxa[0].bpsnba.p); free(buf);
}
/* steady-state gain (dB) of the real fircore for a complex tone at f Hz */
static double tone_db(double f)
{
	NBP a = rxa[0].nbp0.p; int size = a->size; int nblk = a->nc / size + 4; double p = 0;
	flush_fircore(a->p);
	long n = 0;
	for (int b = 0; b < nblk; b++) {
		for (int i = 0; i < size; i++, n++) { double ph = TWOPI * f * n / 48000.0; buf[2*i] = cos(ph); buf[2*i+1] = -sin(ph); } /* WDSP fir_bandpass(rtype 1) places +f passband at e^{-j2pi f n} in this I/Q convention (verified by probe.c) */
		xnbp(a, 0);
		if (b == nblk - 1) { p = 0; for (int i = 0; i < size; i++) p += buf[2*i]*buf[2*i] + buf[2*i+1]*buf[2*i+1]; p /= size; }
	}
	return 10 * log10(p + 1e-30);
}
static void print_bands(const char* tag)
{
	NBP a = rxa[0].nbp0.p; printf("  %s numpb=%d bands:", tag, a->numpb);
	for (int i = 0; i < a->numpb; i++) printf(" [%.0f,%.0f]", a->bplow[i], a->bphigh[i]); printf("\n");
}

/* ---------- independent reference: passband minus union of notch intervals ---------- */
static int cmpd(const void* x, const void* y) { const double* a = x; const double* b = y; return (a[0] > b[0]) - (a[0] < b[0]); }
static int reference(int nn, double* nl, double* nh, double flow, double fhigh, double* out /*pairs*/)
{
	double iv[64][2]; int m = 0;
	for (int k = 0; k < nn; k++) if (nh[k] > flow && nl[k] < fhigh) { iv[m][0] = nl[k]; iv[m][1] = nh[k]; m++; }
	qsort(iv, m, sizeof iv[0], cmpd);
	int nb = 0; double cur = flow;
	for (int k = 0; k < m && cur < fhigh; k++) {
		if (iv[k][0] > cur) { out[2*nb] = cur; out[2*nb+1] = fmin(iv[k][0], fhigh); nb++; }
		if (iv[k][1] > cur) cur = iv[k][1];
	}
	if (cur < fhigh) { out[2*nb] = cur; out[2*nb+1] = fhigh; nb++; }
	return nb;
}
static uint64_t rs = 0x9E3779B97F4A7C15ULL;
static double urand(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (rs >> 11) * (1.0 / 9007199254740992.0); }

/* measure of disagreement in Hz: |symmetric difference| between two band sets over [flow,fhigh] */
static double symdiff_hz(int na, double* a, int nb, double* b, double flow, double fhigh)
{
	double step = 1.0, err = 0;
	for (double f = flow + 0.5; f < fhigh; f += step) {
		int ia = 0, ib = 0;
		for (int i = 0; i < na; i++) if (f > a[2*i] && f < a[2*i+1]) ia = 1;
		for (int i = 0; i < nb; i++) if (f > b[2*i] && f < b[2*i+1]) ib = 1;
		if (ia != ib) err += step;
	}
	return err;
}

int main(void)
{
	setvbuf(stdout, NULL, _IONBF, 0);
#ifdef FIXED
	printf("=== FIXED build ===\n");
#else
	printf("=== ORIGINAL build ===\n");
#endif
	/* ---- Test A: the finding's example through the real RXA API + fircore ---- */
	printf("\n[A] passband 0..3000 Hz, nc=2048, size=1024, wintype 0, autoincr 1. Notches added in order: 1000/200, 2000/200, 925/2050\n");
	setup(1024, 2048, 0.0, 3000.0, 0, 1);
	RXANBPSetNotchesRun(0, 1);
	RXANBPAddNotch(0, 0, 1000.0, 200.0, 1);
	RXANBPAddNotch(0, 1, 2000.0, 200.0, 1);
	print_bands("after 2 notches:");
	RXANBPAddNotch(0, 2, 925.0, 2050.0, 1);
	print_bands("after 3 notches:");
	printf("  expected bands: [2100,3000]\n");
	double fA[] = { 450, 1500, 2500, 2800 };
	for (int i = 0; i < 4; i++) printf("  tone %5.0f Hz -> %7.2f dB  (should be %s)\n", fA[i], tone_db(fA[i]), fA[i] > 2100 ? "~0 dB, passband" : "notched");
	teardown();

	/* ---- Test A2: same notches but wide one first (sorted-by-center order) ---- */
	printf("\n[A2] same three notches, wide notch inserted at index 0 (database ordered by center)\n");
	setup(1024, 2048, 0.0, 3000.0, 0, 1);
	RXANBPSetNotchesRun(0, 1);
	RXANBPAddNotch(0, 0, 1000.0, 200.0, 1);
	RXANBPAddNotch(0, 1, 2000.0, 200.0, 1);
	RXANBPAddNotch(0, 0, 925.0, 2050.0, 1);
	print_bands("after 3 notches:");
	for (int i = 0; i < 4; i++) printf("  tone %5.0f Hz -> %7.2f dB\n", fA[i], tone_db(fA[i]));
	teardown();

	/* ---- Test B: randomized make_nbp vs independent reference ---- */
	for (int order = 0; order < 2; order++) {
		int trials = 200000, bad = 0, badbandcount = 0; double worst = 0, sumerr = 0;
		rs = 0x9E3779B97F4A7C15ULL;
		for (int t = 0; t < trials; t++) {
			int nn = 2 + (int)(urand() * 7);
			double c[16], w[16], lo[16], hi[16]; int act[16];
			for (int k = 0; k < nn; k++) { c[k] = -200 + urand() * 3400; w[k] = 20 + urand() * (urand() < 0.3 ? 2500 : 400); act[k] = 1; }
			if (order == 1) { /* sort by center */
				for (int i = 1; i < nn; i++) for (int j = i; j > 0 && c[j-1] > c[j]; j--) { double tc = c[j]; c[j] = c[j-1]; c[j-1] = tc; double tw = w[j]; w[j] = w[j-1]; w[j-1] = tw; }
			}
			for (int k = 0; k < nn; k++) { lo[k] = c[k] - 0.5 * w[k]; hi[k] = c[k] + 0.5 * w[k]; }
			double bl[1025], bh[1025]; int hv;
			int nb = MAKE_NBP(nn, act, c, w, lo, hi, 0.0, 0, 0.0, 3000.0, bl, bh, &hv);
			double got[2050], ref[64]; for (int i = 0; i < nb; i++) { got[2*i] = bl[i]; got[2*i+1] = bh[i]; }
			int nr = reference(nn, lo, hi, 0.0, 3000.0, ref);
			qsort(got, nb, 2 * sizeof(double), cmpd);
			int ok = (nb == nr);
			for (int i = 0; ok && i < nb; i++) if (fabs(got[2*i] - ref[2*i]) > 1e-9 || fabs(got[2*i+1] - ref[2*i+1]) > 1e-9) ok = 0;
			if (!ok) {
				bad++; if (nb != nr) badbandcount++;
				double e = symdiff_hz(nb, got, nr, ref, 0.0, 3000.0); sumerr += e; if (e > worst) worst = e;
			}
		}
		printf("\n[B] random make_nbp trials (%s notch order), passband 0..3000, 2-8 notches: %d/%d wrong (%.3f%%), wrong band count in %d; mean wrong-spectrum %.0f Hz when wrong, worst %.0f Hz\n",
			order ? "sorted-by-center" : "arbitrary", bad, trials, 100.0 * bad / trials, badbandcount, bad ? sumerr / bad : 0.0, worst);
	}

	/* ---- Test C: min_notch_width integer division ---- */
	printf("\n[C] min_notch_width (rate 48000):\n");
	{
		int ncs[] = { 128, 255, 256, 384, 640, 2048, 3072 };
		for (int i = 0; i < 7; i++) for (int wt = 0; wt < 2; wt++) {
			nbp tmp; memset(&tmp, 0, sizeof tmp); tmp.nc = ncs[i]; tmp.rate = 48000; tmp.wintype = wt;
			printf("  nc=%4d wintype=%d -> %.2f Hz\n", ncs[i], wt, min_notch_width(&tmp));
		}
	}
	printf("\n[C2] nc=128, size=128, autoincr 1: one 50 Hz notch at 1000 Hz, passband 0..3000\n");
	setup(128, 128, 0.0, 3000.0, 0, 1);
	RXANBPSetNotchesRun(0, 1);
	RXANBPAddNotch(0, 0, 1000.0, 50.0, 1);
	print_bands("bands:");
	double fC[] = { 500, 1000, 2000 };
	for (int i = 0; i < 3; i++) printf("  tone %5.0f Hz -> %7.2f dB\n", fC[i], tone_db(fC[i]));
	teardown();
	return 0;
}
