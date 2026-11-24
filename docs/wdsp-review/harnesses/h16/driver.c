/* Harness for WDSP cfcomp (finding 16).  Built twice: against orig/ and fixed/.
   usage: driver <method> <fsize> <bsize> <rate> <precomp_dB> [ratio knee tatt trel]
   Prints: latency, identity SNR, talk-power, interharmonic distortion, envelope ripple. */
#include "comm.h"
#include <stdio.h>

static uint64_t rs = 0x9E3779B97F4A7C15ULL;
static double urand(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (double)(rs >> 11) / 9007199254740992.0; }
static double nrand(void) { double u1 = urand() + 1e-300, u2 = urand(); return sqrt(-2 * log(u1)) * cos(TWOPI * u2); }

static int g_method, g_fsize, g_bsize, g_rate; static double g_pre, g_ratio = 20, g_knee = 6, g_tatt = 0.001, g_trel = 0.06;

/* run a whole signal through a fresh cfcomp; output length n (zero-padded input at end) */
static void run_cfc(const double *x, double *y, int n)
{
	double F[5] = {200.0, 1000.0, 2000.0, 3000.0, 4000.0};
	double G[5] = {0.0, 5.0, 10.0, 10.0, 5.0};
	double E[5] = {7.0, 7.0, 7.0, 7.0, 7.0};
	int bs = g_bsize, i, k;
	double *buf = (double *)malloc0(2 * bs * sizeof(double));
	CFCOMP a = create_cfcomp(1, 0, 0, bs, buf, buf, g_fsize, 4, g_rate, 1, g_method, 5, 5, g_pre, 0.0, F, G, F, E, 0.25, 0.50);
#ifdef FIXED
	a->ratio = g_ratio; a->knee = g_knee; a->tatt = g_tatt; a->trel = g_trel;
	setSize_cfcomp(a, bs); /* recompute attack/release multipliers */
#endif
	for (k = 0; k + bs <= n; k += bs)
	{
		for (i = 0; i < bs; i++) { buf[2 * i] = x[k + i]; buf[2 * i + 1] = 0.0; }
		xcfcomp(a, 0);
		for (i = 0; i < bs; i++) y[k + i] = buf[2 * i];
	}
	for (; k < n; k++) y[k] = 0.0;
	destroy_cfcomp(a);
	free(buf);
}

static void run_cfc_flat(const double *x, double *y, int n)	/* identity gain curve: G = 0 dB, precomp 0 */
{
	double F[5] = {200.0, 1000.0, 2000.0, 3000.0, 4000.0};
	double G[5] = {0, 0, 0, 0, 0};
	int bs = g_bsize, i, k;
	double *buf = (double *)malloc0(2 * bs * sizeof(double));
	CFCOMP a = create_cfcomp(1, 0, 0, bs, buf, buf, g_fsize, 4, g_rate, 1, g_method, 5, 5, 0.0, 0.0, F, G, F, G, 0.25, 0.50);
	for (k = 0; k + bs <= n; k += bs)
	{
		for (i = 0; i < bs; i++) { buf[2 * i] = x[k + i]; buf[2 * i + 1] = 0.0; }
		xcfcomp(a, 0);
		for (i = 0; i < bs; i++) y[k + i] = buf[2 * i];
	}
	for (; k < n; k++) y[k] = 0.0;
	destroy_cfcomp(a);
	free(buf);
}

/* two-pole resonator */
typedef struct { double b0, a1, a2, y1, y2; } reson;
static void reson_set(reson *r, double f, double bw, double fs) { double R = exp(-PI * bw / fs); r->a1 = 2 * R * cos(TWOPI * f / fs); r->a2 = -R * R; r->b0 = 1 - R; }
static double reson_run(reson *r, double x) { double y = r->b0 * x + r->a1 * r->y1 + r->a2 * r->y2; r->y2 = r->y1; r->y1 = y; return y; }

/* speech-like signal: syllables of glottal pulse train through 3 formants + fricative bursts, with pauses */
static void make_speech(double *x, int n, int fs)
{
	static const double vf[3][3] = {{730, 1090, 2440}, {270, 2290, 3010}, {300, 870, 2240}};
	int i = 0; double ph = 0;
	memset(x, 0, n * sizeof(double));
	while (i < n)
	{
		int gap = (int)((0.05 + 0.15 * urand()) * fs); if (urand() < 0.12) gap += (int)(0.4 * fs);
		i += gap; if (i >= n) break;
		int len = (int)((0.15 + 0.15 * urand()) * fs); if (i + len > n) len = n - i;
		int v = (int)(3 * urand()); if (v > 2) v = 2;
		double f0a = 100 + 80 * urand(), f0b = 100 + 80 * urand(), amp = 0.4 + 0.6 * urand();
		reson r[3]; int j; memset(r, 0, sizeof r);
		for (j = 0; j < 3; j++) reson_set(&r[j], vf[v][j] * (0.95 + 0.1 * urand()), 60 + 40 * j, fs);
		int fric = urand() < 0.35; int flen = fric ? (int)(0.06 * fs) : 0; reson rf; memset(&rf, 0, sizeof rf); reson_set(&rf, 3000, 1500, fs);
		for (j = 0; j < len; j++)
		{
			double t = (double)j / len, env = sin(PI * t); env *= env;
			double f0 = f0a + (f0b - f0a) * t;
			ph += f0 / fs; double pulse = 0; if (ph >= 1) { ph -= 1; pulse = 1; }
			double s = 0, src = pulse - 0.02 * nrand() * 0.1;
			s += 1.0 * reson_run(&r[0], src) + 0.5 * reson_run(&r[1], src) + 0.25 * reson_run(&r[2], src);
			x[i + j] += amp * env * s;
			if (j < flen) x[i + j] += 0.15 * amp * reson_run(&rf, nrand()) * sin(PI * j / (double)flen);
		}
		i += len;
	}
	double pk = 0; for (i = 0; i < n; i++) if (fabs(x[i]) > pk) pk = fabs(x[i]);
	for (i = 0; i < n; i++) x[i] *= 0.5 / pk;
}

/* steady/AM vowel: F0 harmonics with formant-shaped amplitudes; returns harmonic amplitudes so peak about 0.5 */
static void make_vowel(double *x, int n, int fs, double f0, double am_hz)
{
	int i, h; double ph[40];
	for (h = 0; h < 40; h++) ph[h] = TWOPI * urand();
	for (i = 0; i < n; i++)
	{
		double s = 0;
		for (h = 1; h * f0 < 4000 && h < 40; h++)
		{
			double f = h * f0;
			double a = 1.0 / (1 + pow((f - 700) / 150, 2)) + 0.5 / (1 + pow((f - 1200) / 200, 2)) + 0.25 / (1 + pow((f - 2500) / 300, 2)) + 0.02;
			s += a * sin(TWOPI * f * i / fs + ph[h]);
		}
		double env = am_hz > 0 ? 0.5 - 0.5 * cos(TWOPI * am_hz * i / fs) : 1.0;
		x[i] = s * env;
	}
	double pk = 0; for (i = 0; i < n; i++) if (fabs(x[i]) > pk) pk = fabs(x[i]);
	for (i = 0; i < n; i++) x[i] *= 0.5 / pk;
}

/* interharmonic distortion: energy within +/-tol Hz of harmonics vs elsewhere in 80..4200 Hz */
static double interharm_db(const double *y, int fs, double f0, double tol)
{
	int N = 1 << 17, i;
	double *in = fftw_malloc(N * sizeof(double)); fftw_complex *out = fftw_malloc((N / 2 + 1) * sizeof(fftw_complex));
	for (i = 0; i < N; i++) { double c = cos(TWOPI * i / N); double w = 0.35875 - 0.48829 * c + 0.14128 * cos(2 * TWOPI * i / N) - 0.01168 * cos(3 * TWOPI * i / N); in[i] = y[i] * w; }
	fftw_plan p = fftw_plan_dft_r2c_1d(N, in, out, FFTW_ESTIMATE); fftw_execute(p);
	double eh = 0, ei = 0;
	for (i = 0; i <= N / 2; i++)
	{
		double f = (double)i * fs / N; if (f < 80 || f > 4200) continue;
		double P = out[i][0] * out[i][0] + out[i][1] * out[i][1];
		double r = fmod(f, f0); if (r > f0 / 2) r = f0 - r;
		if (r <= tol) eh += P; else ei += P;
	}
	fftw_destroy_plan(p); fftw_free(in); fftw_free(out);
	return 10 * log10(ei / eh);
}

/* per-band short-term level spread: std-dev (dB) of 20 ms band levels over active frames, averaged over 1/3-oct bands 250..3150 Hz */
static double band_spread(const double *s, const double *ref, int n, int fs, double *meanlvl)
{
	int N = 1024, hop = fs / 50, i, f, b, nb = 12;
	double *in = fftw_malloc(N * sizeof(double)); fftw_complex *out = fftw_malloc((N / 2 + 1) * sizeof(fftw_complex));
	fftw_plan p = fftw_plan_dft_r2c_1d(N, in, out, FFTW_ESTIMATE);
	double sum[12] = {0}, sq[12] = {0}; int cnt = 0;
	double refmax = 0; for (i = 0; i < n; i++) if (fabs(ref[i]) > refmax) refmax = fabs(ref[i]);
	for (f = 0; f + N < n; f += hop)
	{
		double er = 0; for (i = 0; i < N; i++) er += ref[f + i] * ref[f + i]; er = sqrt(er / N);
		if (er < refmax * 0.03) continue;	/* active frames only (ref within ~30 dB of peak) */
		for (i = 0; i < N; i++) in[i] = s[f + i] * (0.5 - 0.5 * cos(TWOPI * i / N));
		fftw_execute(p);
		for (b = 0; b < nb; b++)
		{
			double fc = 250 * pow(2, b / 3.0), lo = fc / pow(2, 1 / 6.0), hi = fc * pow(2, 1 / 6.0), e = 1e-30;
			for (i = (int)ceil(lo * N / fs); i <= (int)(hi * N / fs); i++) e += out[i][0] * out[i][0] + out[i][1] * out[i][1];
			double L = 10 * log10(e); sum[b] += L; sq[b] += L * L;
		}
		cnt++;
	}
	double sd = 0, ml = 0; for (b = 0; b < nb; b++) { double m = sum[b] / cnt; sd += sqrt(sq[b] / cnt - m * m); ml += m; }
	fftw_destroy_plan(p); fftw_free(in); fftw_free(out);
	if (meanlvl) *meanlvl = ml / nb;
	return sd / nb;
}

int main(int argc, char **argv)
{
	if (argc < 6) { fprintf(stderr, "usage\n"); return 1; }
	g_method = atoi(argv[1]); g_fsize = atoi(argv[2]); g_bsize = atoi(argv[3]); g_rate = atoi(argv[4]); g_pre = atof(argv[5]);
	if (argc > 9) { g_ratio = atof(argv[6]); g_knee = atof(argv[7]); g_tatt = atof(argv[8]); g_trel = atof(argv[9]); }
	int fs = g_rate, n, i, lat = -1;
	/* 1. latency: impulse through identity-gain CFC */
	n = 4 * 16384 + 8 * g_bsize; n -= n % g_bsize;
	double *x = calloc(n, sizeof(double)), *y = calloc(n, sizeof(double));
	int n0 = 2 * g_fsize + 17; x[n0] = 1e-3;
	run_cfc_flat(x, y, n);
	{ double pk = 0; for (i = 0; i < n; i++) if (fabs(y[i]) > pk) { pk = fabs(y[i]); lat = i - n0; } printf("latency_samples %d latency_ms %.2f impulse_peak_gain %.4f\n", lat, 1000.0 * lat / fs, pk / 1e-3); }
	free(x); free(y);
	/* identity reconstruction SNR on low-level noise */
	n = 4 * fs; n -= n % g_bsize; x = calloc(n, sizeof(double)); y = calloc(n, sizeof(double));
	for (i = 0; i < n; i++) x[i] = 1e-4 * nrand();
	run_cfc_flat(x, y, n);
	{ double e = 0, s = 0; for (i = g_fsize * 2; i < n - lat - 1; i++) { double d = y[i + lat] - x[i]; e += d * d; s += x[i] * x[i]; } printf("identity_snr_db %.1f\n", 10 * log10(s / e)); }
	free(x); free(y);
	/* 2. speech-like: talk power */
	n = 12 * fs; n -= n % g_bsize; x = calloc(n, sizeof(double)); y = calloc(n, sizeof(double));
	rs = 12345; make_speech(x, n, fs);
	run_cfc(x, y, n);
	{
		int s0 = 2 * g_fsize, s1 = n - lat - 1; double pi = 0, po = 0, ei = 0, eo = 0;
		for (i = s0; i < s1; i++) { double a = fabs(x[i]), b = fabs(y[i + lat]); if (a > pi) pi = a; if (b > po) po = b; ei += x[i] * x[i]; eo += y[i + lat] * y[i + lat]; }
		double papr_in = 20 * log10(pi / sqrt(ei / (s1 - s0))), papr_out = 20 * log10(po / sqrt(eo / (s1 - s0)));
		/* 99.9th-percentile-normalised also, less sensitive to single overshoots */
		double mli, mlo, sdi = band_spread(x + s0, x + s0, s1 - s0, fs, &mli), sdo = band_spread(y + s0 + lat, x + s0, s1 - s0, fs, &mlo);
		printf("speech band_level_sd_in_db %.2f band_level_sd_out_db %.2f (reduction %.2f dB)\n", sdi, sdo, sdi - sdo);
		printf("speech papr_in_db %.2f papr_out_db %.2f talkpower_gain_db %.2f rms_gain_db %.2f\n", papr_in, papr_out, papr_in - papr_out, 10 * log10(eo / ei));
		FILE *f = fopen(getenv("OUTRAW") ? getenv("OUTRAW") : "/dev/null", "wb"); if (f) { fwrite(y + lat, sizeof(double), n - lat, f); fclose(f); }
	}
	free(x); free(y);
	/* 3. steady vowel and 4 Hz AM vowel: interharmonic distortion and envelope ripple */
	{
		double am[2] = {0.0, 4.0}; int k;
		for (k = 0; k < 2; k++)
		{
			n = 8 * fs; n -= n % g_bsize; x = calloc(n, sizeof(double)); y = calloc(n, sizeof(double));
			rs = 777; make_vowel(x, n, fs, 150.0, am[k]);
			run_cfc(x, y, n);
			int s0 = 2 * fs; double dx = interharm_db(x + s0, fs, 150.0, am[k] > 0 ? 13.0 : 3.0), dy = interharm_db(y + s0 + lat, fs, 150.0, am[k] > 0 ? 13.0 : 3.0);
			/* envelope ripple: CV of 10 ms RMS over steady region (steady vowel only) */
			double cv = 0;
			if (am[k] == 0)
			{
				int w = fs / 100, m = 0; double sm = 0, sq = 0;
				for (i = s0; i + w < n - lat - fs; i += w) { double e = 0; int j; for (j = 0; j < w; j++) e += y[i + lat + j] * y[i + lat + j]; e = sqrt(e / w); sm += e; sq += e * e; m++; }
				sm /= m; cv = sqrt(sq / m - sm * sm) / sm;
			}
			printf("vowel_am%.0f interharm_in_db %.1f interharm_out_db %.1f env_cv %.4f\n", am[k], dx, dy, cv);
			free(x); free(y);
		}
	}
	/* 4. pre/post echo: 0.6 s vowel burst in silence */
	{
		n = 5 * fs; n -= n % g_bsize; x = calloc(n, sizeof(double)); y = calloc(n, sizeof(double));
		double *v = calloc(n, sizeof(double)); rs = 99; make_vowel(v, n, fs, 150.0, 0.0);
		int on = 2 * fs, len = (int)(0.6 * fs), r = fs / 200;
		for (i = 0; i < len; i++) { double w = 1; if (i < r) w = 0.5 - 0.5 * cos(PI * i / r); if (i > len - r) w = 0.5 - 0.5 * cos(PI * (len - i) / r); x[on + i] = v[on + i] * w; }
		run_cfc(x, y, n);
		double eb = 0, epre = 0, epost = 0, epre2 = 0; int w4 = (int)(0.4 * fs), g = fs / 100;
		for (i = on; i < on + len; i++) eb += y[i + lat] * y[i + lat];
		for (i = on - w4; i < on - g; i++) epre += y[i + lat] * y[i + lat];
		for (i = on - fs / 20; i < on - g; i++) epre2 += y[i + lat] * y[i + lat];
		for (i = on + len + g; i < on + len + w4; i++) epost += y[i + lat] * y[i + lat];
		/* normalise per-sample energies */
		double pb = eb / len, ppre = epre / (w4 - g), ppost = epost / (w4 - g), ppre2 = epre2 / (fs / 20 - g);
		/* earliest output sample above -60 dB of burst RMS, relative to onset */
		int first = -1; double thr = sqrt(pb) * 1e-3; for (i = on - fs; i < on + len; i++) if (fabs(y[i + lat]) > thr) { first = i - on; break; }
		printf("burst pre_echo_400ms_db %.1f pre_echo_50ms_db %.1f post_echo_400ms_db %.1f first_-60dB_sample_rel_onset_ms %.1f\n",
			10 * log10(ppre / pb + 1e-30), 10 * log10(ppre2 / pb + 1e-30), 10 * log10(ppost / pb + 1e-30), 1000.0 * first / fs);
		free(x); free(y); free(v);
	}
	return 0;
}
