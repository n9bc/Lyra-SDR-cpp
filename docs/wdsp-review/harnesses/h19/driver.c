/* h19 driver: exercises the REAL WDSP 2.11 calcc.c calc() (extracted verbatim,
   built against nurbs_fit.c / nurbs_spline.c / extrapolate.c) with a synthetic
   PA + feedback model, and mirrors pscc()'s bs_count / LRESET handling around it.

   Scenario: N good cycles (stable PA) -> one bad capture (feedback phase jump
   or PA transient) -> M good cycles.  A reference run uses the identical RNG
   stream but the bad cycle is replaced by a good one.  We report:
     - per-cycle accept/reject and binfo flags
     - consecutive rejections after the bad capture, and LRESETs (bs_count>=3)
     - max |delta| of the committed calavg tables (m,c,s) vs the reference run
     - max phase-table error in degrees vs the reference run
*/
#include "calc_extract.c"

int g_dprint = 0;

/* ---------- deterministic RNG ---------- */
static uint64_t rng_s;
static double urand(void) {
	rng_s ^= rng_s << 13; rng_s ^= rng_s >> 7; rng_s ^= rng_s << 17;
	return (double)(rng_s >> 11) * (1.0 / 9007199254740992.0);
}
static double grand(void) {
	double u1 = urand(), u2 = urand();
	if (u1 < 1e-300) u1 = 1e-300;
	return sqrt(-2.0 * log(u1)) * cos(2.0 * PI * u2);
}

/* ---------- harness constructor: create_calcc minus txa/threads/delays ---------- */
static CALCC make_calcc(void) {
	CALCC a = (CALCC)malloc0(sizeof(calcc));
	a->hw_scale = 1.0;
	a->ps_colct = build_collection();
	a->info = (int*)malloc0(16 * sizeof(int));
	a->binfo = (int*)malloc0(16 * sizeof(int));
	InitializeCriticalSectionAndSpinCount(&a->disp.cs_disp, 2500);
	size_calcc(a);
	return a;
}

/* verbatim state reset from pscc() case LRESET (minus thread signalling) */
static void lreset(CALCC a) {
	ns_free(a->m_spline); a->m_spline = NULL;
	ns_free(a->c_spline); a->c_spline = NULL;
	ns_free(a->s_spline); a->s_spline = NULL;
	a->m_prev_y = 1.0; a->c_prev_y = 1.0; a->s_prev_y = 0.0;
	curve_ema_init2(&a->m_calavg, PS_NS_EMA_ALPHA, PS_NS_EMA_ALPHA_LO, PS_NS_EMA_X_BND,  0.1, 2.0);
	curve_ema_init2(&a->c_calavg, PS_NS_EMA_ALPHA, PS_NS_EMA_ALPHA_LO, PS_NS_EMA_X_BND, -1.1, 1.1);
	curve_ema_init2(&a->s_calavg, PS_NS_EMA_ALPHA, PS_NS_EMA_ALPHA_LO, PS_NS_EMA_X_BND, -1.1, 1.1);
	a->m_fold_prev = 0;
	a->m_ctrl_ema_valid = 0; a->c_ctrl_ema_valid = 0; a->s_ctrl_ema_valid = 0;
	a->m_y_pin_valid = 0; a->m_y_pin_ema = 1.0; a->m_pin_cycle = 0;
	a->c_y_pin_valid = 0; a->c_y_pin_ema = 1.0; a->c_pin_cycle = 0;
	a->s_y_pin_valid = 0; a->s_y_pin_ema = 0.0; a->s_pin_cycle = 0;
	a->scheck_valid = 0;
}

/* ---------- PA / feedback model ---------- */
typedef struct {
	double c3;      /* AM/AM: F(a) = a*(1 - c3*a^2) */
	double kpm;     /* AM/PM: phase = ph0 + kpm*a^2 (rad) */
	double ph0;     /* static feedback phase (rad) */
	double g;       /* loop gain */
	double noise;   /* complex AWGN sigma on rx */
} PA;

static void fill_cycle(CALCC a, const PA* pa) {
	PSCOLLECTION c = a->ps_colct;
	sampleCollectClear(c);
	long guard = 0;
	for (;;) {
		double amp = 0.005 + 0.995 * urand();
		double th = 2.0 * PI * urand();
		double n1 = grand(), n2 = grand();
		double tx[2] = { amp * cos(th), amp * sin(th) };
		double F = amp * (1.0 - pa->c3 * amp * amp);
		double ph = th + pa->ph0 + pa->kpm * amp * amp;
		double rx[2] = { pa->g * F * cos(ph) + pa->noise * n1,
		                 pa->g * F * sin(ph) + pa->noise * n2 };
		putSample(tx, rx, a->hw_scale, c);
		if (sampleCheckAndUpdate(c)) break;
		if (++guard > 50000000) { fprintf(stderr, "fill stuck\n"); exit(2); }
	}
}

#define MAXCYC 200
typedef struct {
	int ok[MAXCYC];
	int resets[MAXCYC];
	int b1[MAXCYC], b2[MAXCYC], b3[MAXCYC], b6[MAXCYC];
	int ncf_m[MAXCYC], ncf_c[MAXCYC], ncf_s[MAXCYC];
	double m[MAXCYC][CURVE_EMA_PTS], c[MAXCYC][CURVE_EMA_PTS], s[MAXCYC][CURVE_EMA_PTS];
	int calavg_count[MAXCYC];
	int clip_viol[MAXCYC];
} Trace;

/* run ncyc cycles; cycle 'badcyc' uses pa_bad (if badcyc>=0) */
static void run(Trace* T, int ncyc, int badcyc, const PA* good, const PA* bad, uint64_t seed) {
	rng_s = seed;
	CALCC a = make_calcc();
	int bs_count = 0;
	for (int k = 0; k < ncyc; k++) {
		const PA* pa = (k == badcyc || (getenv("STEP") && badcyc >= 0 && k > badcyc)) ? bad : good;
		fill_cycle(a, pa);
		calc(a);
		T->ok[k] = a->scOK;
		T->b1[k] = a->binfo[1]; T->b2[k] = a->binfo[2]; T->b3[k] = a->binfo[3]; T->b6[k] = a->binfo[6];
		T->ncf_m[k] = a->m_nfres->n_ctrl_final; T->ncf_c[k] = a->c_nfres->n_ctrl_final; T->ncf_s[k] = a->s_nfres->n_ctrl_final;
		T->resets[k] = 0;
		if (a->scOK) {
			/* hand-off to iqc (doPSCorrChange case 3) */
			ns_free(a->m_spline); a->m_spline = NULL;
			ns_free(a->c_spline); a->c_spline = NULL;
			ns_free(a->s_spline); a->s_spline = NULL;
			bs_count = 0;
		} else if (++bs_count >= 3) {
			lreset(a); T->resets[k] = 1; bs_count = 0;
		}
		int viol = 0;
		for (int i = 0; i < CURVE_EMA_PTS; i++) {
			T->m[k][i] = a->m_calavg.ys[i]; T->c[k][i] = a->c_calavg.ys[i]; T->s[k][i] = a->s_calavg.ys[i];
			if (a->m_calavg.ys[i] < 0.1 || a->m_calavg.ys[i] > 2.0) viol++;
			if (a->c_calavg.ys[i] < -1.1 || a->c_calavg.ys[i] > 1.1) viol++;
			if (a->s_calavg.ys[i] < -1.1 || a->s_calavg.ys[i] > 1.1) viol++;
		}
		T->clip_viol[k] = viol;
		T->calavg_count[k] = a->m_calavg.count;
	}
}

static double maxdev(const double* x, const double* y) {
	double d = 0; for (int i = 1; i < CURVE_EMA_PTS; i++) { double e = fabs(x[i] - y[i]); if (e > d) d = e; } return d;
}
static double maxphdeg(const Trace* A, const Trace* R, int k) {
	double d = 0;
	for (int i = 1; i < CURVE_EMA_PTS; i++) {
		double pa = atan2(A->s[k][i], A->c[k][i]), pr = atan2(R->s[k][i], R->c[k][i]);
		double e = pa - pr; while (e > PI) e -= 2 * PI; while (e < -PI) e += 2 * PI;
		e = fabs(e) * 180.0 / PI; if (e > d) d = e;
	}
	return d;
}
/* phase-table error vs the TRUE inverse (ideal) in degrees, mag table relative error */
static double true_ph_err(const Trace* A, int k, const PA* pa) {
	double F1 = 1.0 - pa->c3, d = 0;
	for (int i = 13; i < CURVE_EMA_PTS; i++) { /* x >= ~0.05 */
		double x = (double)i / (CURVE_EMA_PTS - 1);
		double lo = 0, hi = 1.0;          /* invert x = F(a)/F(1) */
		for (int it = 0; it < 60; it++) { double m = 0.5 * (lo + hi); if (m * (1 - pa->c3 * m * m) / F1 < x) lo = m; else hi = m; }
		double am = 0.5 * (lo + hi);
		double phi = pa->ph0 + pa->kpm * am * am;   /* yc=cos(phi), ys=-sin(phi) */
		double pt = atan2(-sin(phi), cos(phi));
		double pe = atan2(A->s[k][i], A->c[k][i]);
		double e = pe - pt; while (e > PI) e -= 2 * PI; while (e < -PI) e += 2 * PI;
		e = fabs(e) * 180 / PI; if (e > d) d = e;
	}
	return d;
}

static Trace TA, TR;

int main(int argc, char** argv) {
	int ncyc = 60, badcyc = 20;
	PA good = { .c3 = 0.25, .kpm = 0.35, .ph0 = 0.4, .g = 0.5, .noise = 2e-3 };
	if (getenv("GOODC3")) good.c3 = atof(getenv("GOODC3"));     /* e.g. overdrive / fold */
	if (getenv("GOODKPM")) good.kpm = atof(getenv("GOODKPM"));
	if (getenv("NOISE")) good.noise = atof(getenv("NOISE"));
	const char* scen = argc > 1 ? argv[1] : "phase180";
	PA bad = good;
	if (!strcmp(scen, "phase180")) bad.ph0 += PI;
	else if (!strcmp(scen, "phase90")) bad.ph0 += PI / 2;
	else if (!strcmp(scen, "phase60")) bad.ph0 += PI / 3;
	else if (!strcmp(scen, "phase45")) bad.ph0 += PI / 4;
	else if (!strcmp(scen, "phase30")) bad.ph0 += PI / 6;
	else if (!strcmp(scen, "ampm3x")) bad.kpm *= 4.0;        /* strong AM/PM transient */
	else if (!strcmp(scen, "compress")) bad.c3 = 0.45;       /* heavy compression transient */
	else if (!strcmp(scen, "none")) ;
	else { fprintf(stderr, "unknown scenario\n"); return 1; }
	uint64_t seed = argc > 2 ? strtoull(argv[2], 0, 10) : 0x9E3779B97F4A7C15ULL;
	if (seed == 0) seed = 1;

	run(&TA, ncyc, badcyc, &good, &bad, seed);
	run(&TR, ncyc, -1, &good, &good, seed);

	int verbose = argc > 3 && atoi(argv[3]);
	int rej_after = 0, consec = 0, resets = 0, run_on = 1, clipv = 0, ncmis = 0;
	double dm = 0, dc = 0, ds = 0, dph = 0, dph1 = 0, trueph_worst = 0;
	int ref_rej = 0;
	for (int k = 0; k < ncyc; k++) {
		if (!TR.ok[k] && k >= badcyc) ref_rej++;
		clipv += TA.clip_viol[k];
		if ((TA.ncf_m[k] && TA.ncf_m[k] != PS_NF_N_CTRL) || (TA.ncf_c[k] && TA.ncf_c[k] != PS_NF_N_CTRL) || (TA.ncf_s[k] && TA.ncf_s[k] != PS_NF_N_CTRL)) ncmis++;
		if (verbose)
			printf("cyc %2d %s ok=%d ref_ok=%d b1=%02x b2=%02x b3=%02x b6=%x reset=%d ncf=%d/%d/%d dm=%.4f dc=%.4f ds=%.4f dph=%.2fdeg truephErr=%.2fdeg\n",
				k, k == badcyc ? "BAD" : "   ", TA.ok[k], TR.ok[k], TA.b1[k], TA.b2[k], TA.b3[k], TA.b6[k], TA.resets[k],
				TA.ncf_m[k], TA.ncf_c[k], TA.ncf_s[k],
				maxdev(TA.m[k], TR.m[k]), maxdev(TA.c[k], TR.c[k]), maxdev(TA.s[k], TR.s[k]), maxphdeg(&TA, &TR, k), true_ph_err(&TA, k, getenv("STEP") ? &bad : &good));
		if (k > badcyc) {
			if (!TA.ok[k]) rej_after++;
			if (run_on) { if (!TA.ok[k]) consec++; else run_on = 0; }
			if (TA.resets[k]) resets++;
			double e;
			e = maxdev(TA.m[k], TR.m[k]); if (e > dm) dm = e;
			e = maxdev(TA.c[k], TR.c[k]); if (e > dc) dc = e;
			e = maxdev(TA.s[k], TR.s[k]); if (e > ds) ds = e;
			e = maxphdeg(&TA, &TR, k); if (e > dph) dph = e;
			if (k == badcyc + 1) dph1 = e;
			e = true_ph_err(&TA, k, &good); if (e > trueph_worst) trueph_worst = e;
		}
	}
	printf("RESULT scen=%s seed=%llu badcyc_ok=%d rej_after=%d consec_rej_after=%d lresets_after=%d ref_rej_after=%d "
		"max_dm=%.4f max_dc=%.4f max_ds=%.4f max_dph_deg=%.3f dph_next_deg=%.3f worst_truephErr_deg=%.2f "
		"final_dph_deg=%.4f clip_viol=%d nc_mismatch_cycles=%d\n",
		scen, (unsigned long long)seed, TA.ok[badcyc], rej_after, consec, resets, ref_rej, dm, dc, ds, dph, dph1, trueph_worst,
		maxphdeg(&TA, &TR, ncyc - 1), clipv, ncmis);
	return 0;
}
