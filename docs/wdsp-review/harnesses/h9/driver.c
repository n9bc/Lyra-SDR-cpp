// Harness for finding 9: WDSP amd.c SAM PLL, original vs proposed fix.
// Feeds complex baseband (as produced by nbp0 at dsp_rate 48 kHz) into the real xamd()
// one sample at a time so the VCO phase can be compared with the true carrier phase.
#include "comm.h"
#include <stdio.h>
#include <stdint.h>

#ifdef AMD_FIXED
extern int amd_fix_arm_order; extern double amd_fix_arm_fc; extern int amd_fix_fade; extern int amd_fix_acq;
#endif

#define FS 48000.0
#define NTAP 255

static uint64_t rs;
static double urand(void){ rs ^= rs >> 12; rs ^= rs << 25; rs ^= rs >> 27; return ((rs * 2685821657736338717ULL) >> 11) * (1.0 / 9007199254740992.0); }
static double grand(void){ double u1 = urand(), u2 = urand(); if (u1 < 1e-300) u1 = 1e-300; return sqrt(-2 * log(u1)) * cos(TWOPI * u2); }
static double wrap(double x){ while (x > PI) x -= TWOPI; while (x <= -PI) x += TWOPI; return x; }

static double lp_taps[NTAP];
static void design_lp(double fc){ // Blackman windowed sinc, unity DC gain
	double s = 0; int M = NTAP - 1;
	for (int n = 0; n < NTAP; n++){ double k = n - M / 2.0; double h = (k == 0) ? 2 * fc / FS : sin(TWOPI * fc / FS * k) / (PI * k);
		double w = 0.42 - 0.5 * cos(TWOPI * n / M) + 0.08 * cos(2 * TWOPI * n / M); lp_taps[n] = h * w; s += lp_taps[n]; }
	for (int n = 0; n < NTAP; n++) lp_taps[n] /= s;
}
// complex white noise filtered to [fc0-bw/2, fc0+bw/2], normalised to unit power
static void band_noise(double *out, int N, double fcenter, double half_bw){
	design_lp(half_bw);
	double *w = malloc(sizeof(double) * 2 * (N + NTAP));
	for (int n = 0; n < N + NTAP; n++){ w[2*n] = grand(); w[2*n+1] = grand(); }
	double p = 0, HR[NTAP], HI[NTAP];
	for (int k = 0; k < NTAP; k++){ HR[k] = lp_taps[k] * cos(TWOPI * fcenter / FS * k); HI[k] = lp_taps[k] * sin(TWOPI * fcenter / FS * k); }
	for (int n = 0; n < N; n++){ double re = 0, im = 0;
		for (int k = 0; k < NTAP; k++){
			double xr = w[2*(n+NTAP-1-k)], xi = w[2*(n+NTAP-1-k)+1]; double hr = HR[k], hi = HI[k];
			re += xr * hr - xi * hi; im += xr * hi + xi * hr; }
		out[2*n] = re; out[2*n+1] = im; p += re*re + im*im; }
	p = sqrt(p / N); for (int n = 0; n < 2 * N; n++) out[n] /= p; free(w);
}
// real speech-like message: 300-3000 Hz noise x syllabic envelope, rms ~ 0.3*mod
static void message(double *m, int N, double mod, double envphase){
	double *c = malloc(sizeof(double) * 2 * N); band_noise(c, N, 1650, 1350);
	double p = 0; for (int n = 0; n < N; n++){ m[n] = c[2*n]; }
	for (int n = 0; n < N; n++){ double t = n / FS; double env = 0.25 + 0.75 * fabs(sin(PI * 4.0 * t + envphase)); m[n] *= env; p += m[n]*m[n]; }
	p = sqrt(p / N); for (int n = 0; n < N; n++){ m[n] = mod * 0.33 * m[n] / p; if (m[n] > 0.98) m[n] = 0.98; if (m[n] < -0.98) m[n] = -0.98; }
	free(c);
}

typedef struct { double lock_s, final_df, rms_e, snr_pll, snr_genie; int slips; int acq; } result;

static AMD mk(int sbmode, double *in, double *out){
	return create_amd(1, 1, in, out, 1, 1, sbmode, (int)FS, -2000.0, 2000.0, 1.0, 250.0, 0.02, 1.4);
}
static void dcblock(double *x, int N){ double y = 0, xp = 0, r = exp(-TWOPI * 30.0 / FS); for (int n = 0; n < N; n++){ double v = x[n] - xp + r * y; xp = x[n]; y = v; x[n] = v; } }

// run the PLL (genie=0) or a genie with phs forced to the true phase (genie=1)
static void run(int sbmode, const double *x, int N, const double *theta, int genie, double *audio, double *phs, int *acq){
	double in[2], out[2]; AMD a = mk(sbmode, in, out);
	for (int n = 0; n < N; n++){
		if (genie){ double p = fmod(theta[n], TWOPI); if (p < 0) p += TWOPI; a->phs = p; }
		if (phs) phs[n] = a->phs;
		in[0] = x[2*n]; in[1] = x[2*n+1]; xamd(a); audio[n] = out[0];
	}
#ifdef AMD_FIXED
	if (acq) *acq = a->acq_count;
#else
	if (acq) *acq = 0;
#endif
	destroy_amd(a);
}

static result evaluate(int sbmode, const double *x, const double *xclean, int N, const double *theta, double f_true_end, double tskip){
	result r = {0}; double *aud = malloc(8*N), *ref = malloc(8*N), *gn = malloc(8*N), *phs = malloc(8*N);
	run(sbmode, x, N, theta, 0, aud, phs, &r.acq);
	run(sbmode, xclean, N, theta, 1, ref, NULL, NULL);
	run(sbmode, x, N, theta, 1, gn, NULL, NULL);
	dcblock(aud, N); dcblock(ref, N); dcblock(gn, N);
	int n0 = (int)(tskip * FS);
	double U = 0, eprev = 0; int k = 0; double se = 0; r.lock_s = 0;
	for (int n = 0; n < N; n++){
		double e = wrap(theta[n] - phs[n]);
		if (n > 0) U += wrap(e - eprev); eprev = e;
		if (fabs(e) > 0.5) r.lock_s = (n + 1) / FS;
		if (n >= n0){ if (U - TWOPI * k > 1.5 * PI){ k++; r.slips++; } else if (U - TWOPI * k < -1.5 * PI){ k--; r.slips++; } se += e * e; }
		else k = (int)lround(U / TWOPI);
	}
	r.rms_e = sqrt(se / (N - n0));
	{ int L = (int)(0.5 * FS); double s = 0; for (int n = N - L; n < N; n++) s += wrap(phs[n] - phs[n-1]); r.final_df = s / L * FS / TWOPI - f_true_end; }
	double ps = 0, pe = 0, pg = 0;
	for (int n = n0; n < N; n++){ ps += ref[n]*ref[n]; pe += (aud[n]-ref[n])*(aud[n]-ref[n]); pg += (gn[n]-ref[n])*(gn[n]-ref[n]); }
	r.snr_pll = 10 * log10(ps / pe); r.snr_genie = 10 * log10(ps / pg);
	free(aud); free(ref); free(gn); free(phs); return r;
}

static const char *label = "orig";

// Build desired signal e^{j theta}(gc + m); optional two-path channel; plus noise and LSB-side interferer.
static result scenario(double dur, double f0, double mod, double cnr_db, double int_db, int sbmode,
                       double dip_db, double dip_ms, double dip_period, double mp_beta, double mp_fd, double tskip, uint64_t seed){
	int N = (int)(dur * FS); rs = seed;
	double *m = malloc(8*N), *th = malloc(8*N), *xc = malloc(16*N), *x = malloc(16*N), *nz = malloc(16*N), *it = malloc(16*N), *gc = malloc(8*N);
	message(m, N, mod, 0.0);
	double phi0 = TWOPI * urand();
	for (int n = 0; n < N; n++){ double t = n / FS; th[n] = phi0 + TWOPI * f0 * t; gc[n] = 1.0;
		if (dip_ms > 0){ double tp = fmod(t, dip_period) - 1.0; double half = dip_ms / 2000.0;
			if (tp > -half && tp < half){ double depth = pow(10, dip_db / 20); double w = 0.5 + 0.5 * cos(PI * tp / half); gc[n] = 1.0 - (1.0 - depth) * w; } }
		xc[2*n] = (gc[n] + m[n]) * cos(th[n]); xc[2*n+1] = (gc[n] + m[n]) * sin(th[n]); }
	if (mp_beta > 0){ // two-path selective fading, 0.5 ms differential delay, rotating second path
		int D = 24; double *y = malloc(16*N);
		for (int n = 0; n < N; n++){ double t = n / FS, ps = TWOPI * mp_fd * t; double br = mp_beta * cos(ps), bi = mp_beta * sin(ps);
			double dr = n >= D ? xc[2*(n-D)] : 0, di = n >= D ? xc[2*(n-D)+1] : 0;
			y[2*n] = xc[2*n] + br * dr - bi * di; y[2*n+1] = xc[2*n+1] + br * di + bi * dr;
			// composite carrier phase: theta + arg(1 + beta e^{j(psi - 2 pi f0 tau)})
			double q = ps - TWOPI * f0 * D / FS; th[n] = th[n] + atan2(mp_beta * sin(q), 1 + mp_beta * cos(q)); }
		memcpy(xc, y, 16*N); free(y);
	}
	band_noise(nz, N, 0, 5000); double sn = pow(10, -cnr_db / 20);
	if (int_db > -200){ band_noise(it, N, +1650, 1350); /* +f side = side rejected by sbmode 2, see sbcheck.c */ double si = pow(10, int_db / 20);
		for (int n = 0; n < N; n++){ double env = 0.25 + 0.75 * fabs(sin(PI * 3.1 * n / FS + 1.0)); it[2*n] *= si * env * 1.25; it[2*n+1] *= si * env * 1.25; } }
	else memset(it, 0, 16*N);
	for (int n = 0; n < 2*N; n++) x[n] = xc[n] + sn * nz[n] + it[n];
	result r = evaluate(sbmode, x, xc, N, th, f0, tskip);
	free(m); free(th); free(xc); free(x); free(nz); free(it); free(gc); return r;
}

static void pr(const char *sc, const char *par, result r){
	printf("%-6s %-4s %-34s lock_s=%6.3f fin_df=%8.3fHz rms_e=%6.3frad slips=%4d snr_pll=%6.2fdB snr_genie=%6.2fdB acq=%d\n",
	       label, sc, par, r.lock_s, r.final_df, r.rms_e, r.slips, r.snr_pll, r.snr_genie, r.acq);
	fflush(stdout);
}

int main(int argc, char **argv){
	const char *which = argc > 1 ? argv[1] : "all";
#ifdef AMD_FIXED
	// argv[2..5]: arm_order arm_fc fade acq
	if (argc > 5){ amd_fix_arm_order = atoi(argv[2]); amd_fix_arm_fc = atof(argv[3]); amd_fix_fade = atoi(argv[4]); amd_fix_acq = atoi(argv[5]); }
	static char lb[64]; snprintf(lb, 64, "a%d/%g/f%d/q%d", amd_fix_arm_order, amd_fix_arm_fc, amd_fix_fade, amd_fix_acq); label = lb;
#endif
	char p[128];
	if (!strcmp(which, "all") || !strcmp(which, "S1")){ // acquisition vs offset, CNR 30 dB, 50% mod, 12 s
		double offs[] = {20, 100, 300, 500, 1000, 1500, 1900, -1500};
		for (int i = 0; i < 8; i++){ snprintf(p, 128, "off=%gHz cnr=30", offs[i]);
			pr("S1", p, scenario(12, offs[i], 0.5, 30, -999, 0, 0, 0, 1, 0, 0, 11, 1000 + i)); }
		for (int i = 0; i < 3; i++){ double o = (double[]){500, 1000, 1500}[i]; snprintf(p, 128, "off=%gHz cnr=10", o);
			pr("S1", p, scenario(12, o, 0.5, 10, -999, 0, 0, 0, 1, 0, 0, 11, 1100 + i)); }
	}
	if (!strcmp(which, "all") || !strcmp(which, "S2")){ // interferer on rejected (LSB) side, USB demod, on-frequency
		double ib[] = {-10, 0, 6, 10, 15, 20, 25};
		for (int i = 0; i < 7; i++){ snprintf(p, 128, "I/C=%+gdB usb cnr=30", ib[i]);
			pr("S2", p, scenario(20, 5.0, 0.5, 30, ib[i], 2, 0, 0, 1, 0, 0, 1.0, 2000 + i)); }
	}
	if (!strcmp(which, "all") || !strcmp(which, "S3")){ // carrier-only dips (sidebands intact), plus noise
		double dd[] = {-20, -30, -40}; int sb[] = {0, 2};
		for (int s = 0; s < 2; s++) for (int i = 0; i < 3; i++){ snprintf(p, 128, "dip=%gdB 300ms/1.5s sb=%d cnr=25", dd[i], sb[s]);
			pr("S3", p, scenario(20, 5.0, 0.7, 25, -999, sb[s], dd[i], 300, 1.5, 0, 0, 1.0, 3000 + 10*s + i)); }
		for (int i = 0; i < 2; i++){ snprintf(p, 128, "dip=-30dB 300ms/1.5s sb=2 cnr=15 I/C=%s", i ? "+6" : "none");
			pr("S3", p, scenario(20, 5.0, 0.7, 15, i ? 6 : -999, 2, -30, 300, 1.5, 0, 0, 1.0, 3100 + i)); }
	}
	if (!strcmp(which, "all") || !strcmp(which, "S4")){ // two-path selective fading (0.5 ms, rotating)
		double be[] = {0.9, 0.97}; double fd[] = {0.3, 1.0};
		for (int b = 0; b < 2; b++) for (int f = 0; f < 2; f++) for (int s = 0; s < 2; s++){ int sbm = s ? 2 : 0;
			snprintf(p, 128, "beta=%g fd=%gHz sb=%d cnr=25", be[b], fd[f], sbm);
			pr("S4", p, scenario(20, 5.0, 0.7, 25, -999, sbm, 0, 0, 1, be[b], fd[f], 1.0, 4000 + 10*b + f)); }
	}
	if (!strcmp(which, "all") || !strcmp(which, "S5")){ // low CNR sweep, on frequency
		double cn[] = {0, 3, 6, 10, 15, 20}; int sb[] = {0, 2};
		for (int s = 0; s < 2; s++) for (int i = 0; i < 6; i++){ snprintf(p, 128, "cnr=%gdB sb=%d", cn[i], sb[s]);
			pr("S5", p, scenario(20, 5.0, 0.5, cn[i], -999, sb[s], 0, 0, 1, 0, 0, 1.0, 5000 + i)); }
		snprintf(p, 128, "clean cnr=60 sb=2");
		pr("S5", p, scenario(10, 5.0, 0.5, 60, -999, 2, 0, 0, 1, 0, 0, 1.0, 5100));
	}
	if (!strcmp(which, "S6")){ // very low CNR, on frequency, DSB
		double cn[] = {-3, -6, -9, -12};
		for (int i = 0; i < 4; i++){ snprintf(p, 128, "cnr=%gdB sb=0", cn[i]);
			pr("S6", p, scenario(20, 5.0, 0.5, cn[i], -999, 0, 0, 0, 1, 0, 0, 1.0, 6000 + i)); }
	}
	return 0;
}
