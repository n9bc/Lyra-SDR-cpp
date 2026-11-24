/* Harness for finding 20: WDSP analyzer.c window averaging (av_mode 2) never clears av_sum.
 * Drives the REAL analyzer.c (XCreateAnalyzer/SetAnalyzer/stitch/GetPixels and the real
 * SetDisplayNumAverage/SetDisplayAverageMode/ResetPixelBuffers) with synthetic per-bin FFT power
 * written into a->result[0] (what eliminate()/Celiminate() would produce), bypassing only the
 * FFT thread pool. Ideal = exact boxcar mean (double) of the t_pixels frames since the last reset,
 * converted with the same mlog10, so mlog10's table error cancels. */
#include "comm.h"

extern void stitch(int disp);
extern void SetDisplayNumAverage(int disp, int pixout, int num);
extern void SetDisplayAverageMode(int disp, int pixout, int mode);
extern void SetDisplayAvBackmult(int disp, int pixout, double mult);
extern void ResetPixelBuffers(int disp);
extern void GetPixels(int disp, int pixout, dOUTREAL *pix, int *flag);

#define SZ 1024
#define NPIX 512
#define NBINS (SZ - 1)
#define CARR_BIN 600
#define HIST 128

static uint64_t rng = 0x9E3779B97F4A7C15ull;
static double urand(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return ((rng >> 11) + 0.5) * (1.0 / 9007199254740992.0); }

static int disp_ctr = 0;
static int D;               /* current display */
static double hist[HIST][NPIX];
static int hcount;          /* frames since last reset (for ideal) */
static int hidx;
static int Nint;            /* intended window length */
static float pix[NPIX];
static int carr_pix = -1;

static void create(void)
{
	int ok, flp[1] = {0};
	D = disp_ctr++;
	XCreateAnalyzer(D, &ok, SZ, 1, 1, "");
	SetAnalyzer(D, 1, 1, 1, flp, SZ, SZ, 4, 14.0, 0, 0, 0.0, 0.0, NPIX, 1, 0, 0.0, 0.0, SZ);
	hcount = 0; hidx = 0;
}
static void mark_reset(int N) { hcount = 0; Nint = N; }

/* floor_p: mean noise power per bin (t_pixels units); carrier: power in carrier bin (0 = off) */
static void frame(double floor_p, double carrier)
{
	DP a = pdisp[D];
	int k, flag;
	for (k = 0; k < NBINS; k++) a->result[0][k] = -log(urand()) * floor_p;
	if (carrier > 0) a->result[0][CARR_BIN] = carrier;
	a->ss_bins[0] = NBINS;
	stitch(D);
	GetPixels(D, 0, pix, &flag);
	if (!flag) { fprintf(stderr, "no pixels\n"); exit(1); }
	memcpy(hist[hidx], a->t_pixels[0], sizeof(double) * NPIX);
	hidx = (hidx + 1) % HIST; hcount++;
	if (carr_pix < 0) {    /* locate the pixel that holds the carrier bin */
		int i; double mx = -1;
		if (carrier > 0) for (i = 0; i < NPIX; i++) if (a->t_pixels[0][i] > mx) { mx = a->t_pixels[0][i]; carr_pix = i; }
	}
}

typedef struct { double floor_err, floor_maxabs, out_floor, ideal_floor, carr_err, carr_out, carr_ideal; int neg_sum; } meas_t;

static meas_t measure(void)
{
	DP a = pdisp[D];
	meas_t m = {0};
	int i, j, n = 0, neff = hcount < Nint ? hcount : Nint;
	for (i = 0; i < NPIX; i++) {
		double s = 0, ideal;
		for (j = 1; j <= neff; j++) s += hist[(hidx - j + HIST) % HIST][i];
		ideal = 10.0 * mlog10(a->scale * s / neff + 1.0e-60);
		double err = (double)pix[i] - ideal;
		if (a->av_sum[0][i] < 0) m.neg_sum++;
		if (carr_pix >= 0 && abs(i - carr_pix) <= 2) {
			if (i == carr_pix) { m.carr_err = err; m.carr_out = pix[i]; m.carr_ideal = ideal; }
			continue;
		}
		m.floor_err += err; m.out_floor += pix[i]; m.ideal_floor += ideal; n++;
		if (fabs(err) > m.floor_maxabs) m.floor_maxabs = fabs(err);
	}
	m.floor_err /= n; m.out_floor /= n; m.ideal_floor /= n;
	return m;
}

static void report(const char *tag, int f)
{
	meas_t m = measure();
	printf("  %-34s f=%5d  floor: out %8.2f ideal %8.2f err %+8.3f dB (max|err| %7.3f)", tag, f, m.out_floor, m.ideal_floor, m.floor_err, m.floor_maxabs);
	if (carr_pix >= 0) printf("  carrpix: out %8.2f ideal %8.2f err %+8.2f", m.carr_out, m.carr_ideal, m.carr_err);
	printf("  neg_av_sum=%d\n", m.neg_sum);
}

static double FLOOR = 1.0e-7;   /* ~ -130 dB displayed with scale 1/SZ^2 */
static double CARR = 105.0;     /* ~ -40 dB displayed */

static void run(int f0, int nfr, double fl, double c, const int *at, int nat, const char *tag)
{
	int f, k;
	for (f = 0; f < nfr; f++) {
		frame(fl, c);
		for (k = 0; k < nat; k++) if (f + 1 == at[k]) { char t[80]; snprintf(t, sizeof t, "%s +%d", tag, at[k]); report(t, f0 + f + 1); }
	}
}

int main(void)
{
	static const int at[] = {1, 5, 20, 100, 1000, 3000};
	const int nat = 6;

	printf("S0 control: mode2 N=10 from mode0 start (no change), carrier on\n");
	create(); carr_pix = -1; SetDisplayNumAverage(D, 0, 10); SetDisplayAverageMode(D, 0, 2); mark_reset(10);
	run(0, 300, FLOOR, CARR, (int[]){10, 300}, 2, "steady");

	printf("S1: mode2 N=10 steady 300 frames, then SetDisplayNumAverage(5)\n");
	create(); carr_pix = -1; SetDisplayNumAverage(D, 0, 10); SetDisplayAverageMode(D, 0, 2); mark_reset(10);
	run(0, 300, FLOOR, 0, (int[]){300}, 1, "before");
	SetDisplayNumAverage(D, 0, 5); mark_reset(5);
	run(300, 3000, FLOOR, 0, at, nat, "after N->5");

	printf("S2: mode2 N=30 steady, then N->2\n");
	create(); carr_pix = -1; SetDisplayNumAverage(D, 0, 30); SetDisplayAverageMode(D, 0, 2); mark_reset(30);
	run(0, 300, FLOOR, 0, NULL, 0, "");
	SetDisplayNumAverage(D, 0, 2); mark_reset(2);
	run(300, 3000, FLOOR, 0, at, nat, "after N->2");

	printf("S3 ghost: mode2 N=20 with -40 dB carrier, then carrier OFF and N->10\n");
	create(); carr_pix = -1; SetDisplayNumAverage(D, 0, 20); SetDisplayAverageMode(D, 0, 2); mark_reset(20);
	run(0, 300, FLOOR, CARR, (int[]){300}, 1, "before (carrier on)");
	SetDisplayNumAverage(D, 0, 10); mark_reset(10);
	run(300, 3000, FLOOR, 0, at, nat, "carrier off, N->10");

	printf("S4: mode3 (backmult 0.9) with carrier, then SetDisplayAverageMode(2) N=10; +20 dB floor step at +1500\n");
	create(); carr_pix = -1; SetDisplayNumAverage(D, 0, 10); SetDisplayAvBackmult(D, 0, 0.9); SetDisplayAverageMode(D, 0, 3);
	run(0, 300, FLOOR, CARR, NULL, 0, "");
	SetDisplayAverageMode(D, 0, 2); mark_reset(10);
	run(300, 1500, FLOOR, CARR, (int[]){20, 1500}, 2, "mode3->2");
	run(1800, 1500, FLOOR * 100, CARR, (int[]){20, 1500}, 2, "after +20dB floor step");

	printf("S5: peak-hold (-1) with carrier, then carrier OFF and mode->2 N=10\n");
	create(); carr_pix = -1; SetDisplayNumAverage(D, 0, 10); SetDisplayAverageMode(D, 0, -1);
	run(0, 300, FLOOR, CARR, NULL, 0, "");
	SetDisplayAverageMode(D, 0, 2); mark_reset(10);
	run(300, 3000, FLOOR, 0, at, nat, "peak->2 carrier off");

	printf("S6: mode1 (backmult 0.9) with carrier, then carrier OFF and mode->2 N=10\n");
	create(); carr_pix = -1; SetDisplayNumAverage(D, 0, 10); SetDisplayAvBackmult(D, 0, 0.9); SetDisplayAverageMode(D, 0, 1);
	run(0, 300, FLOOR, CARR, NULL, 0, "");
	SetDisplayAverageMode(D, 0, 2); mark_reset(10);
	run(300, 3000, FLOOR, 0, at, nat, "mode1->2 carrier off");

	printf("S7 control: mode0 with carrier, then carrier OFF and mode->2 N=10\n");
	create(); carr_pix = -1; SetDisplayNumAverage(D, 0, 10); SetDisplayAverageMode(D, 0, 0);
	run(0, 300, FLOOR, CARR, NULL, 0, "");
	SetDisplayAverageMode(D, 0, 2); mark_reset(10);
	run(300, 3000, FLOOR, 0, at, nat, "mode0->2 carrier off");

	printf("S8: mode2 N=10 with carrier, then carrier OFF and ResetPixelBuffers()\n");
	create(); carr_pix = -1; SetDisplayNumAverage(D, 0, 10); SetDisplayAverageMode(D, 0, 2); mark_reset(10);
	run(0, 300, FLOOR, CARR, NULL, 0, "");
	ResetPixelBuffers(D); mark_reset(10);
	run(300, 3000, FLOOR, 0, at, nat, "after Reset, carrier off");

	printf("S9: N=70 (> dMAX_AVERAGE=60) from clean start; carrier on 0..499, off afterwards\n");
	create(); carr_pix = -1; SetDisplayNumAverage(D, 0, 70); SetDisplayAverageMode(D, 0, 2);
	printf("  num_average stored = %d\n", pdisp[D]->num_average[0]);
	mark_reset(pdisp[D]->num_average[0]);
	run(0, 500, FLOOR, CARR, (int[]){60, 70, 100, 500}, 4, "N=70 carrier on");
	run(500, 3000, FLOOR, 0, (int[]){70, 100, 1000, 3000}, 4, "N=70 carrier off");
	return 0;
}
