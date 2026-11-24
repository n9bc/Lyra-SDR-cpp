/* Harness for WDSP 2.11 wbfm.c finding #8.
   Built twice: against orig/wbfm.c and fixed/wbfm.c (the .c is #included so static
   helpers such as calc_bqs / bqsecRun / nopwrRun are reachable).
   Modes:
     filter <fs>             : measure squelch noise bandpass (real calc_bqs + bqsecRun) with sines and white noise
     dmph                    : full xwbfm, 3-tone mono FM; toggle SetRXAWBFMdmph mid-stream; Goertzel per phase
     sql <sca%> <rds%> <cnr_dB|inf> : full xwbfm, station with pilot + optional SCA(67k) + RDS(57k) + AWGN; squelch stats
*/
#include "wbfm.c"

rxa_stub rxa[MAX_CHANNELS];
ch_stub ch[MAX_CHANNELS];

/* deterministic RNG: xorshift64* + Box-Muller */
static uint64_t rng_s = 0x9E3779B97F4A7C15ULL;
static double urand(void){ rng_s ^= rng_s >> 12; rng_s ^= rng_s << 25; rng_s ^= rng_s >> 27;
	return ((rng_s * 2685821657736338717ULL) >> 11) * (1.0 / 9007199254740992.0); }
static double grand(void){ double u1 = urand(); if (u1 < 1e-300) u1 = 1e-300; double u2 = urand();
	return sqrt(-2.0 * log(u1)) * cos(TWOPI * u2); }

static double db(double x){ return 20.0 * log10(x); }

/* ---------------------------------------------------------------- filter */
static double run_sine(double fs, double f)
{
	bqs sec[2]; calc_bqs(fs, 58000.0, 75000.0, sec);
	int n = (int)(0.2 * fs), half = n / 2;
	double* b = malloc(n * sizeof(double));
	for (int i = 0; i < n; i++) b[i] = sin(TWOPI * f * i / fs);
	bqsecRun(&sec[0], n, b); bqsecRun(&sec[1], n, b);
	double p = 0; for (int i = half; i < n; i++) p += b[i] * b[i];
	free(b);
	return sqrt(2.0 * p / (n - half));     /* amplitude gain */
}

static void mode_filter(double fs)
{
	bqs sec[2]; calc_bqs(fs, 58000.0, 75000.0, sec);
	for (int k = 0; k < 2; k++)
		printf("section %d: b0=%.6f b1=%.6f b2=%.6f a1=%.6f a2=%.6f\n", k, sec[k].b0, sec[k].b1, sec[k].b2, sec[k].a1, sec[k].a2);
	double pk = 0, fpk = 0, lo = -1, hi = -1;
	double fmax = fs / 2 - 100;
	for (double f = 1000; f < fmax; f += 50) { double g = run_sine(fs, f); if (g > pk) { pk = g; fpk = f; } }
	for (double f = 1000; f < fmax; f += 50) { double g = run_sine(fs, f); if (lo < 0 && g >= pk / sqrt(2.0)) lo = f; if (g >= pk / sqrt(2.0)) hi = f; }
	printf("peak %.2f dB at %.0f Hz; -3dB(rel peak) band %.0f-%.0f Hz (%.0f Hz wide)\n", db(pk), fpk, lo, hi, hi - lo);
	double fl[] = { 15000, 19000, 38000, 53000, 57000, 58000, 62000, 66000, 67000, 70000, 75000, 80000, 90000 };
	for (int i = 0; i < 13; i++) if (fl[i] < fmax) printf("  |H(%5.0f)| = %7.2f dB\n", fl[i], db(run_sine(fs, fl[i])));
	/* noise bandwidth via white noise through the real code */
	int n = (int)(4.0 * fs);
	double* b = malloc(n * sizeof(double));
	for (int i = 0; i < n; i++) b[i] = grand();
	bqsecRun(&sec[0], n, b); bqsecRun(&sec[1], n, b);
	double p = 0; for (int i = n / 10; i < n; i++) p += b[i] * b[i]; p /= (n - n / 10);
	printf("white-noise (var 1) output power %.5f -> ENBW = %.0f Hz (|H|^2-weighted, one-sided)\n", p, p * fs / 2.0);
	free(b);
}

/* ---------------------------------------------------------------- full block */
static WBFM setup(double fs, int size, double** in, double** out)
{
	*in = malloc0(size * sizeof(complex));
	*out = malloc0(size * sizeof(complex));
	InitializeCriticalSectionAndSpinCount(&ch[0].csDSP, 0);
	WBFM a = create_wbfm(1, size, *in, *out, fs);
	rxa[0].wbfm.p = a;
	return a;
}

static double goertzel_amp(const double* x, int stride, int n, double f, double fs)
{
	double w = TWOPI * f / fs, c = 2 * cos(w), s1 = 0, s2 = 0;
	for (int i = 0; i < n; i++) { double s0 = x[i * stride] + c * s1 - s2; s2 = s1; s1 = s0; }
	double re = s1 - s2 * cos(w), im = s2 * sin(w);
	return 2.0 * sqrt(re * re + im * im) / n;
}

static void mode_dmph(void)
{
	const double fs = 384000.0; const int size = 1024;
	double *in, *out; WBFM a = setup(fs, size, &in, &out);
	const double tf[3] = { 1000.0, 10000.0, 15000.0 }, dev = 10000.0;
	double phi = 0; long n = 0;
	const int blocks_per_phase = (int)(2.0 * fs / size);
	const int meas_blocks = (int)(0.5 * fs / size);
	int ml = meas_blocks * size;
	double* Lrec = malloc(ml * sizeof(double));
	struct { const char* name; int run, type, doset; } ph[] = {
		{ "default (create: on, 75us)", 1, 0, 0 },
		{ "Set(on, 50us)",             1, 1, 1 },
		{ "Set(off)",                  0, 0, 1 },
		{ "Set(on, 75us)",             1, 0, 1 },
	};
	/* theoretical analog responses */
	for (int t = 0; t < 2; t++) { double tau = t ? 50e-6 : 75e-6;
		printf("theory %s: ", t ? "50us" : "75us");
		for (int k = 1; k < 3; k++) { double w = TWOPI * tf[k]; printf("%.0fHz rel 1k %.2f dB  ", tf[k],
			10 * log10((1 + pow(TWOPI * tf[0] * tau, 2)) / (1 + w * w * tau * tau))); }
		printf("\n"); }
	double prev_last = 0, maxstep_steady = 0;
	for (int p = 0; p < 4; p++)
	{
		if (ph[p].doset) SetRXAWBFMdmph(0, ph[p].run, ph[p].type);
		double maxstep_switch = 0;
		for (int b = 0; b < blocks_per_phase; b++)
		{
			for (int i = 0; i < size; i++, n++)
			{
				double t = (double)n / fs;
				double m = 0; for (int k = 0; k < 3; k++) m += sin(TWOPI * tf[k] * t);
				phi += TWOPI * dev * m / fs; if (phi > PI) phi -= TWOPI; if (phi < -PI) phi += TWOPI;
				in[2 * i] = cos(phi); in[2 * i + 1] = sin(phi);
			}
			xwbfm(a);
			for (int i = 0; i < size; i++)
			{
				double y = out[2 * i];
				double d = fabs(y - prev_last); prev_last = y;
				if (b == 0 && i < 64) { if (d > maxstep_switch) maxstep_switch = d; }
				else if (p == 0 && b > blocks_per_phase / 2 && d > maxstep_steady) maxstep_steady = d;
			}
			int mb = b - (blocks_per_phase - meas_blocks);
			if (mb >= 0) for (int i = 0; i < size; i++) Lrec[mb * size + i] = out[2 * i];
		}
		double A[3]; for (int k = 0; k < 3; k++) A[k] = goertzel_amp(Lrec, 1, ml, tf[k], fs);
		printf("phase %d %-28s dmphL.run=%d tau=%.0fus | A1k=%.4f A10k=%.4f A15k=%.4f | 10k rel 1k %.2f dB, 15k rel 1k %.2f dB | sqgain=%.3f | max|dy| first 64 samples after set=%.4f\n",
			p, ph[p].name, a->dmphL->run, a->dmphL->tau * 1e6, A[0], A[1], A[2], db(A[1] / A[0]), db(A[2] / A[0]), a->sqgain, maxstep_switch);
	}
	printf("steady-state max|dy| (phase 0, second half) = %.4f\n", maxstep_steady);
}

static double g_fs = 384000.0;
static void mode_sql(double sca_pct, double rds_pct, double cnr_db, double pilot_pct, double secs)
{
	const double fs = g_fs; const int size = 1024;
	double *in, *out; WBFM a = setup(fs, size, &in, &out);
	const double fd = 75000.0;
	double phi = 0, phs_sca = 0; long n = 0;
	double rds_sym = 1, rds_sm = 0; double rds_next = 0;
	double nsig = isinf(cnr_db) ? 0.0 : sqrt(pow(10.0, -cnr_db / 10.0) / 2.0);  /* per-rail; carrier power 1 over full fs bandwidth */
	int nblocks = (int)(secs * fs / size);
	double pmax = 0, psum = 0, gsum = 0, m19 = 0; int cnt = 0, open_blocks = 0, closes = 0, prevstate = -1;
	for (int b = 0; b < nblocks; b++)
	{
		for (int i = 0; i < size; i++, n++)
		{
			double t = (double)n / fs;
			/* program: two tones, 45% deviation in total */
			double m = 0.30 * sin(TWOPI * 1000.0 * t) + 0.15 * sin(TWOPI * 3100.0 * t);
			m += pilot_pct / 100.0 * sin(TWOPI * 19000.0 * t);
			if (rds_pct > 0) {
				if (t >= rds_next) { rds_next += 1.0 / 2375.0; rds_sym = (urand() < 0.5) ? -1.0 : 1.0; }
				rds_sm += 0.05 * (rds_sym - rds_sm);
				m += rds_pct / 100.0 * rds_sm * sin(3.0 * TWOPI * 19000.0 * t);
			}
			if (sca_pct > 0) {
				phs_sca += TWOPI * (67000.0 + 6000.0 * sin(TWOPI * 1000.0 * t)) / fs;
				if (phs_sca > TWOPI) phs_sca -= TWOPI;
				m += sca_pct / 100.0 * cos(phs_sca);
			}
			phi += TWOPI * fd * m / fs; if (phi > PI) phi -= TWOPI; if (phi < -PI) phi += TWOPI;
			in[2 * i] = cos(phi) + nsig * grand(); in[2 * i + 1] = sin(phi) + nsig * grand();
		}
		xwbfm(a);
		WBSQL s = a->psql;
		if (prevstate == 1 && s->sqstate == 0) closes++;
		prevstate = s->sqstate;
		if (b * size > 1.0 * fs) {   /* after 1 s settle */
			if (s->pwrNoise > pmax) pmax = s->pwrNoise;
			psum += s->pwrNoise; gsum += a->sqgain; m19 += s->mag19; cnt++; open_blocks += s->sqstate;
		}
	}
	printf("fs=%.0f sca=%4.1f%% rds=%4.1f%% pilot=%4.1f%% cnr=%6.1f dB | pwrNoise mean=%.5f max=%.5f (low_th 0.15, high_th 0.50) | mag19=%.4f | open %5.1f%% of blocks, closes=%d, mean sqgain=%.3f\n",
		fs, sca_pct, rds_pct, pilot_pct, cnr_db, psum / cnt, pmax, m19 / cnt, 100.0 * open_blocks / cnt, closes, gsum / cnt);
}


/* probe: composite = single tone f at pct% of 75 kHz deviation, no pilot; report settled pwrNoise.
   Also report what nopwr sees: the squelch's input array layout. */
static void mode_probe(double f, double pct)
{
	const double fs = g_fs; const int size = 1024;
	double *in, *out; WBFM a = setup(fs, size, &in, &out);
	double phi = 0; long n = 0; int nb = (int)(1.5 * fs / size);
	for (int b = 0; b < nb; b++) {
		for (int i = 0; i < size; i++, n++) {
			double m = pct / 100.0 * sin(TWOPI * f * n / fs);
			phi += TWOPI * 75000.0 * m / fs; if (phi > PI) phi -= TWOPI; if (phi < -PI) phi += TWOPI;
			in[2 * i] = cos(phi); in[2 * i + 1] = sin(phi);
		}
		xwbfm(a);
	}
	double expect_pwr = 0.5 * pow(2.0 * pct / 100.0, 2);   /* disc_out sine power before filter */
	printf("fs=%.0f probe f=%6.0f Hz %4.1f%% dev: pwrNoise=%.5f  (disc sine power %.4f -> pwrNoise/power = %7.2f dB)  npwr.in==disc_out:%d npwr.size=%d disc_out[1]=%.3g\n",
		fs, f, pct, a->psql->pwrNoise, expect_pwr, 10 * log10(a->psql->pwrNoise / expect_pwr), a->psql->npwr.in == a->disc_out, a->psql->npwr.size, a->disc_out[1]);
}

int main(int argc, char** argv)
{
	if (argc < 2) return 1;
	if (getenv("FS")) g_fs = atof(getenv("FS"));
	if (!strcmp(argv[1], "probe")) { mode_probe(atof(argv[2]), atof(argv[3])); return 0; }
	if (!strcmp(argv[1], "filter")) mode_filter(atof(argv[2]));
	else if (!strcmp(argv[1], "dmph")) mode_dmph();
	else if (!strcmp(argv[1], "sql")) mode_sql(atof(argv[2]), atof(argv[3]),
		strcmp(argv[4], "inf") ? atof(argv[4]) : INFINITY, argc > 5 ? atof(argv[5]) : 10.0, argc > 6 ? atof(argv[6]) : 4.0);
	return 0;
}
