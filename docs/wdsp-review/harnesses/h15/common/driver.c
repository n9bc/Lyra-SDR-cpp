/* Drives the real WDSP rmatch (create_rmatchV defaults) with two simulated clocks.
   Input side: 48 kHz nominal, actual rate 48000*(1+ppm*1e-6), complex 1 kHz tone.
   Output side: exactly 48 kHz.  Between t_stall0 and t_stall1 the input side makes
   no calls (radio stall) while the output side keeps calling xrmatchOUT.
   usage: driver insize outsize ppm pre_s stall_s post_s report_s           */
#include "comm.h"
static int cmpd(const void* x,const void* y){double a=*(const double*)x,b=*(const double*)y;return a<b?-1:a>b;}
int main(int argc, char** argv)
{
	int insize  = argc>1 ? atoi(argv[1]) : 64;
	int outsize = argc>2 ? atoi(argv[2]) : 64;
	double ppm  = argc>3 ? atof(argv[3]) : 20.0;
	double pre  = argc>4 ? atof(argv[4]) : 60.0;
	double stall= argc>5 ? atof(argv[5]) : 400.0;
	double post = argc>6 ? atof(argv[6]) : 600.0;
	double rep  = argc>7 ? atof(argv[7]) : 10.0;
	const double fs = 48000.0, ftone = 1000.0;
	double in_rate = fs * (1.0 + ppm * 1e-6);
	double t_in_step = insize / in_rate, t_out_step = outsize / fs;
	double ts0 = pre, ts1 = pre + stall, tend = pre + stall + post;
	RMATCH a = (RMATCH)create_rmatchV(insize, outsize, 48000, 48000, 4096, 1.0);
	double* in  = (double*)calloc(2*insize, sizeof(double));
	double* out = (double*)calloc(2*outsize, sizeof(double));
	double ph = 0.0, dph = 2.0*PI*ftone/fs;      /* tone defined per input sample */
	double tin = 0.0, tout = 0.0, next_rep = rep;
	long ov0 = 0, un0 = 0; double prI = 0, prQ = 0; double accI = 0, accQ = 0;
	long nin_calls = 0, nout_calls = 0, nout_stall = 0;
	double* finst = (double*)malloc(sizeof(double)*(size_t)(rep*fs+4*outsize)); long nf = 0, nglitch = 0; double amin = 1e9, amax = 0, as = 0, as2 = 0; long na = 0;
	double max_ff = 0; int ff_inf = 0; double first_inf_t = -1;
	printf("# insize=%d outsize=%d ppm=%.1f pre=%.0f stall=%.0f post=%.0f\n", insize, outsize, ppm, pre, stall, post);
	printf("# t_s phase var feed_forward pos neg ovfl_win unfl_win mean_tone_Hz median_inst_Hz glitch_samples(|f-1000|>20Hz)\n");
	while (tout < tend)
	{
		int do_in = (tin <= tout);
		if (do_in)
		{
			int stalled = (tin >= ts0 && tin < ts1);
			if (!stalled)
			{
				for (int i = 0; i < insize; i++) { in[2*i] = 0.5*cos(ph); in[2*i+1] = 0.5*sin(ph); ph += dph; if (ph > PI) ph -= 2*PI; }
				xrmatchIN(a, in);
				nin_calls++;
			}
			tin += t_in_step;
		}
		else
		{
			xrmatchOUT(a, out);
			nout_calls++;
			if (tout >= ts0 && tout < ts1) nout_stall++;
			for (int i = 0; i < outsize; i++)
			{
				double I = out[2*i], Q = out[2*i+1];
				accI += I*prI + Q*prQ; accQ += Q*prI - I*prQ;   /* z[n]*conj(z[n-1]) */
				if (I*I+Q*Q > 1e-6 && prI*prI+prQ*prQ > 1e-6) { double fi = atan2(Q*prI - I*prQ, I*prI + Q*prQ)*fs/(2*PI); finst[nf++] = fi; if (fabs(fi-ftone) > 20.0) nglitch++; }
				{ double m = sqrt(I*I+Q*Q); if (m < amin) amin = m; if (m > amax) amax = m; as += m; as2 += m*m; na++; }
				prI = I; prQ = Q;
			}
			if (!isfinite(a->feed_forward) && !ff_inf) { ff_inf = 1; first_inf_t = tout; }
			if (isfinite(a->feed_forward) && a->feed_forward > max_ff) max_ff = a->feed_forward;
			tout += t_out_step;
			if (tout >= next_rep)
			{
				const char* phs = tout <= ts0 ? "pre" : (tout <= ts1 ? "stall" : "post");
				double f = (accI*accI+accQ*accQ) > 1e-30 ? atan2(accQ, accI) * fs / (2*PI) : 0.0;
				double med = 0; if (nf) { qsort(finst, nf, sizeof(double), cmpd); med = finst[nf/2]; }
				printf("%7.1f %-5s %.6f %-12.6g %10d %10d %6ld %6ld %8.2f %8.2f %7ld amp[min=%.4f max=%.4f sd=%.4f] nring=%d\n", tout, phs, a->var, a->feed_forward,
					a->ffmav->pos, a->ffmav->neg, a->overflows - ov0, a->underflows - un0, f, med, nglitch, na?amin:0, amax, na? sqrt(fmax(0,as2/na-(as/na)*(as/na))):0, a->n_ring);
				nf = 0; nglitch = 0; amin = 1e9; amax = 0; as = as2 = 0; na = 0;
				ov0 = a->overflows; un0 = a->underflows; accI = accQ = 0; next_rep += rep;
			}
		}
	}
	printf("# in_calls=%ld out_calls=%ld out_calls_during_stall=%ld ff_went_inf=%d first_inf_t=%.1f max_finite_ff=%.6g final_var=%.6f final_ff=%g total_ovfl=%ld total_unfl=%ld\n",
		nin_calls, nout_calls, nout_stall, ff_inf, first_inf_t, max_ff, a->var, a->feed_forward, a->overflows, a->underflows);
	return 0;
}
