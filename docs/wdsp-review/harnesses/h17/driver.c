/* Harness driver for WDSP dexp.c finding 17 (retrigger in DECAY; setters reset state/ring).
   Same driver links against orig/dexp.c or fixed/dexp.c. */
#include "comm.h"
#include <stdio.h>
#include <stdint.h>

extern void SetDEXPAttackThreshold(int id, double thresh);
extern void SetDEXPReleaseTime(int id, double t);
extern void SetDEXPDetectorTau(int id, double t);
extern void SetDEXPExpansionRatio(int id, double r);

#define RATE 48000
#define BS 256
static double inb[2 * BS], outb[2 * BS];
static int vox_on_calls = 0, vox_off_calls = 0;
static void pushvox(int id, int active) { (void)id; if (active) vox_on_calls++; else vox_off_calls++; }

static uint64_t rng = 0x9E3779B97F4A7C15ull;
static double urand(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (double)(rng >> 11) / 9007199254740992.0; }
static double grand(void) { double u1 = urand() + 1e-12, u2 = urand(); return sqrt(-2.0 * log(u1)) * cos(TWOPI * u2); }

typedef struct { double thresh, hyst, tattack, tdecay, thold, ratio, dettau, audelay; int run_audelay; } P;

typedef struct { int at_sample; int kind; double val; } Ev;  /* kind 0=thresh 1=release 2=dettau 3=ratio */

/* in: complex input (2*N); out: complex output (2*N). Setter events applied before the block containing at_sample. */
static void run(const P* p, const double* in, double* out, int N, const Ev* ev, int nev)
{
	create_dexp(0, 1, BS, inb, outb, RATE, p->dettau, p->tattack, p->tdecay, p->thold, p->ratio, p->hyst, p->thresh,
		1024, 0, 100.0, 3000.0, 0, 1, p->run_audelay, p->audelay, pushvox, 0, 64, RATE, 1.0, 0.01);
	vox_on_calls = vox_off_calls = 0;
	int e = 0;
	for (int b = 0; b + BS <= N; b += BS)
	{
		while (e < nev && ev[e].at_sample < b + BS)
		{
			switch (ev[e].kind)
			{
			case 0: SetDEXPAttackThreshold(0, ev[e].val); break;
			case 1: SetDEXPReleaseTime(0, ev[e].val); break;
			case 2: SetDEXPDetectorTau(0, ev[e].val); break;
			case 3: SetDEXPExpansionRatio(0, ev[e].val); break;
			}
			e++;
		}
		memcpy(inb, in + 2 * b, 2 * BS * sizeof(double));
		xdexp(0);
		memcpy(out + 2 * b, outb, 2 * BS * sizeof(double));
	}
	destroy_dexp(0);
}

/* complex tone with envelope env[n] */
static void make_tone(const double* env, double* x, int N, double f)
{
	for (int n = 0; n < N; n++) { double ph = TWOPI * f * n / RATE; x[2 * n] = env[n] * cos(ph); x[2 * n + 1] = env[n] * sin(ph); }
}
static double mag(const double* x, int n) { return sqrt(x[2 * n] * x[2 * n] + x[2 * n + 1] * x[2 * n + 1]); }
static double db(double r) { return 10.0 * log10(r > 1e-300 ? r : 1e-300); }

/* ---------- Test A: burst / gap / burst sweep ---------- */
static void testA(FILE* f, double tdecay, double ratio, int audelay)
{
	P p = { 0.05, 0.5, 0.002, tdecay, 0.5, ratio, 0.01, 0.06, audelay };
	int D = audelay ? (int)(0.06 * RATE) : 0;
	int gaps_ms[] = { 300, 450, 510, 520, 550, 600, 700, 900, 1200, 1400, 1600 };
	double A = 0.3, floor = 1e-4;
	for (unsigned gi = 0; gi < sizeof(gaps_ms) / sizeof(gaps_ms[0]); gi++)
	{
		int g = gaps_ms[gi];
		int n1 = RATE * 600 / 1000, ng = RATE * g / 1000, n2 = RATE * 400 / 1000;
		int N = n1 + ng + n2 + D; N = (N / BS + 1) * BS;
		double* env = calloc(N, sizeof(double)); double* x = calloc(2 * N, sizeof(double)); double* y = calloc(2 * N, sizeof(double));
		for (int n = 0; n < N; n++) env[n] = (n < n1 || (n >= n1 + ng && n < n1 + ng + n2)) ? A : floor;
		make_tone(env, x, N, 1000.0);
		run(&p, x, y, N, NULL, 0);
		int s2 = n1 + ng;
		double ein50 = 0, eout50 = 0, ein100 = 0, eout100 = 0, einA = 0, eoutA = 0, gmin = 1e9, gstep = 0; int t99 = -1;
		for (int n = s2; n < s2 + n2 && n + D < N; n++)
		{
			double gi_ = mag(y, n + D) / mag(x, n);
			if (gi_ < gmin) gmin = gi_;
			if (t99 < 0 && gi_ >= 0.99) t99 = n - s2;
			double ei = mag(x, n) * mag(x, n), eo = mag(y, n + D) * mag(y, n + D);
			einA += ei; eoutA += eo;
			if (n < s2 + RATE / 20) { ein50 += ei; eout50 += eo; }
			if (n < s2 + RATE / 10) { ein100 += ei; eout100 += eo; }
		}
		for (int n = 1 + D; n < N; n++) { double d = fabs(mag(y, n) / mag(x, n - D) - mag(y, n - 1) / mag(x, n - 1 - D)); if (d > gstep) gstep = d; }
		fprintf(f, "A tdecay=%.3f ratio=%.2f dly=%d gap=%4dms : onset50ms=%7.2f dB onset100ms=%7.2f dB burst400ms=%7.2f dB mingain=%6.2f dB t_to_0.99=%s%6.1f ms max|dgain|/smp=%.4f vox_on=%d off=%d\n",
			tdecay, ratio, audelay, g, db(eout50 / ein50), db(eout100 / ein100), db(eoutA / einA), 20 * log10(gmin), t99 < 0 ? "never(>" : "", t99 < 0 ? 400.0 : t99 / 48.0, gstep, vox_on_calls, vox_off_calls);
		free(env); free(x); free(y);
	}
}

/* ---------- Test S: speech-like syllables with random pauses ---------- */
static void testS(FILE* f, double tdecay, double thold, double ratio)
{
	P p = { 0.05, 0.5, 0.002, tdecay, thold, ratio, 0.01, 0.06, 0 };
	int N = RATE * 60; N = (N / BS) * BS;
	double* env = calloc(N, sizeof(double)); double* x = calloc(2 * N, sizeof(double)); double* y = calloc(2 * N, sizeof(double));
	int* syl_start = calloc(2000, sizeof(int)); int nsyl = 0;
	rng = 0x1234567ull;
	int n = RATE / 2;
	for (int i = 0; i < N; i++) env[i] = 1e-4 * (1.0 + 0.2 * grand());
	while (n < N - RATE)
	{
		int ns = (int)(RATE * (0.12 + 0.10 * urand()));          /* 120-220 ms syllable */
		double amp = 0.15 + 0.25 * urand();
		syl_start[nsyl++] = n;
		for (int k = 0; k < ns && n + k < N; k++)
		{
			double w = (k < 240) ? 0.5 * (1 - cos(PI * k / 240.0)) : (k > ns - 480 ? 0.5 * (1 - cos(PI * (ns - k) / 480.0)) : 1.0);
			env[n + k] = amp * w * (0.8 + 0.2 * sin(TWOPI * 4.0 * k / RATE));
		}
		n += ns;
		int pause = (urand() < 0.6) ? (int)(RATE * (0.03 + 0.15 * urand())) : (int)(RATE * (0.3 + 1.2 * urand()));
		n += pause;
	}
	make_tone(env, x, N, 700.0);
	run(&p, x, y, N, NULL, 0);
	double ein = 0, eout = 0, eon_in = 0, eon_out = 0; int bad1 = 0, bad3 = 0;
	for (int s = 0; s < nsyl; s++)
	{
		double a = 0, b = 0;
		for (int k = 0; k < RATE * 60 / 1000 && syl_start[s] + k < N; k++) { int m = syl_start[s] + k; a += mag(x, m) * mag(x, m); b += mag(y, m) * mag(y, m); }
		eon_in += a; eon_out += b;
		if (db(b / a) < -1.0) bad1++;
		if (db(b / a) < -3.0) bad3++;
	}
	for (int i = 0; i < N; i++) if (env[i] > 0.01) { ein += mag(x, i) * mag(x, i); eout += mag(y, i) * mag(y, i); }
	fprintf(f, "S tdecay=%.3f thold=%.3f ratio=%.2f : syllables=%d  first60ms loss=%6.2f dB  syl>1dB loss=%d  syl>3dB loss=%d  voiced energy=%6.2f dB  vox_on=%d off=%d\n",
		tdecay, thold, ratio, nsyl, db(eon_out / eon_in), bad1, bad3, db(eout / ein), vox_on_calls, vox_off_calls);
	free(env); free(x); free(y); free(syl_start);
}

/* ---------- Test B: setter calls during steady TX with 60 ms audio delay ---------- */
static void testB(FILE* f, const char* label, const Ev* ev, int nev)
{
	P p = { 0.05, 0.5, 0.002, 0.1, 0.5, 3.1623, 0.01, 0.06, 1 };
	int N = RATE * 3; N = (N / BS) * BS;
	double* env = calloc(N, sizeof(double)); double* x = calloc(2 * N, sizeof(double)); double* y = calloc(2 * N, sizeof(double));
	for (int i = 0; i < N; i++) env[i] = 0.3;
	make_tone(env, x, N, 1000.0);
	run(&p, x, y, N, ev, nev);
	int D = (int)(0.06 * RATE);
	int zeros = 0, below099 = 0, firstz = -1; double gmin = 1e9; double maxstep = 0;
	double prevg = -1;
	for (int i = RATE / 2; i < N; i++)   /* skip the initial power-on attack + initial delay fill */
	{
		double g = mag(y, i) / mag(x, i - D);
		if (mag(y, i) < 1e-12) { zeros++; if (firstz < 0) firstz = i; }
		if (g < 0.99) below099++;
		if (g < gmin) gmin = g;
		if (prevg >= 0 && fabs(g - prevg) > maxstep) maxstep = fabs(g - prevg);
		prevg = g;
	}
	fprintf(f, "B %-34s : zero-output samples=%5d (%.1f ms)  samples gain<0.99=%5d (%.1f ms)  min gain=%s%.2f dB  max |dgain|/sample=%.3f\n",
		label, zeros, zeros / 48.0, below099, below099 / 48.0, gmin <= 0 ? "-inf/" : "", gmin > 0 ? 20 * log10(gmin) : -999.0, maxstep);
	free(env); free(x); free(y);
}

/* ---------- Test C: noise hovering near threshold (pumping/chatter risk) ---------- */
static void testC(FILE* f, double level, double tdecay)
{
	P p = { 0.05, 0.5, 0.002, tdecay, 0.1, 3.1623, 0.01, 0.06, 0 };
	int N = RATE * 20; N = (N / BS) * BS;
	double* x = calloc(2 * N, sizeof(double)); double* y = calloc(2 * N, sizeof(double));
	rng = 0xABCDEFull;
	/* complex Gaussian noise whose short-term level wanders around the threshold */
	double lv = 0;
	for (int i = 0; i < N; i++)
	{
		lv = 0.9998 * lv + 0.02 * grand() * 10.0;     /* AR(1) in dB, stationary std ~ 10 dB, ~100 ms corr */
		double s = level * pow(10.0, lv / 20.0);
		x[2 * i] = s * grand() * 0.7071; x[2 * i + 1] = s * grand() * 0.7071;
	}
	run(&p, x, y, N, NULL, 0);
	/* measure gain from a delayed copy is not needed (no delay): gain = |y|/|x| */
	int rises = 0, dir = 0; double tv = 0, prevg = -1;
	for (int i = 0; i < N; i++)
	{
		double m = mag(x, i); if (m < 1e-9) continue;
		double g = mag(y, i) / m;
		if (prevg >= 0)
		{
			double d = g - prevg; tv += fabs(d);
			if (d > 1e-9) { if (dir < 0) rises++; dir = 1; } else if (d < -1e-9) dir = -1;
		}
		prevg = g;
	}
	fprintf(f, "C noise level=%.3f tdecay=%.3f : gain-rise events=%d  vox_on=%d off=%d  total gain variation=%.1f\n", level, tdecay, rises, vox_on_calls, vox_off_calls, tv);
	free(x); free(y);
}

int main(void)
{
	FILE* f = stdout;
	testA(f, 0.100, 3.1623, 0);
	testA(f, 1.000, 3.1623, 0);
	testA(f, 1.000, 10.0, 0);
	testA(f, 1.000, 3.1623, 1);
	testS(f, 0.100, 0.500, 3.1623);
	testS(f, 0.500, 0.500, 3.1623);
	testS(f, 1.000, 0.500, 3.1623);
	testS(f, 1.000, 0.100, 10.0);
	{ Ev e[] = { { 48000, 0, 0.055 } }; testB(f, "1x SetDEXPAttackThreshold", e, 1); }
	{ Ev e[10]; for (int k = 0; k < 10; k++) { e[k].at_sample = 48000 + k * 4800; e[k].kind = 0; e[k].val = 0.05 + 0.001 * k; } testB(f, "10x AttackThreshold @100ms (drag)", e, 10); }
	{ Ev e[] = { { 48000, 1, 0.2 } }; testB(f, "1x SetDEXPReleaseTime", e, 1); }
	{ Ev e[] = { { 48000, 2, 0.02 } }; testB(f, "1x SetDEXPDetectorTau", e, 1); }
	{ Ev e[] = { { 48000, 3, 5.0 } }; testB(f, "1x SetDEXPExpansionRatio", e, 1); }
	testB(f, "no setter (control)", NULL, 0);
	testC(f, 0.02, 0.1);
	testC(f, 0.02, 1.0);
	testC(f, 0.04, 0.1);
	testC(f, 0.04, 1.0);
	return 0;
}
