/* Proposed fix to WDSP asolve.
   FIXMODE 1 (minimal): biased autocorrelation of the frame only (zero outside), Levinson stop on |k|>=0.9999
                        or beta<1e-9*r0 keeping the lower-order model, isfinite guard.
   FIXMODE 2 (proposal items 1-4): Hann-windowed copy, biased autocorrelation, white-noise correction r0*=1+1e-4,
                        same Levinson stop, bandwidth expansion a_i *= 0.995^(i+1), isfinite guard. */
#include "comm.h"
#ifndef FIXMODE
#define FIXMODE 1
#endif
#ifndef WNC
#define WNC 1e-4
#endif
#ifndef GAMMA
#define GAMMA 0.995
#endif
void asolve(int xsize, int asize, double* x, double* a, double* r, double* z)
{
    int i, j, k;
    double beta, alpha, t, r0;
    static double w[8192];
    const double* xs = x;
    int unstable = 0, bad = 0;
	memset(r, 0, (asize + 1) * sizeof(double));
	memset(z, 0, (asize + 1) * sizeof(double));
#if FIXMODE == 2
    for (j = 0; j < xsize; j++) w[j] = x[j] * (0.5 - 0.5 * cos(2.0 * M_PI * (j + 0.5) / xsize));
    xs = w;
#endif
    for (i = 0; i <= asize; i++)
		for (j = i; j < xsize; j++)
			r[i] += xs[j] * xs[j - i];
#if FIXMODE == 2
    r[0] *= 1.0 + WNC;
#endif
    r0 = r[0];
    z[0] = 1.0;
    beta = r[0];
    for (k = 0; k < asize; k++)
    {
        if (!(beta > 1e-9 * r0) || !(r0 > 0.0)) { unstable = 1; break; }
        alpha = 0.0;
        for (j = 0; j <= k; j++)
            alpha -= z[j] * r[k + 1 - j];
        alpha /= beta;
        if (!(fabs(alpha) < 0.9999)) { unstable = 1; break; }
        if (fabs(alpha) > g_asolve_maxabs_k) g_asolve_maxabs_k = fabs(alpha);
        for (i = 0; i <= (k + 1) / 2; i++)
        {
            t = z[k + 1 - i] + alpha * z[i];
            z[i] = z[i] + alpha * z[k + 1 - i];
            z[k + 1 - i] = t;
        }
        beta *= 1.0 - alpha * alpha;
    }
    {
    double g = 1.0;
    for (i = 0; i < asize; i++)
	{
#if FIXMODE == 2
        g *= GAMMA;
#endif
        a[i] = - z[i + 1] * g;
        if (!isfinite(a[i])) { bad = 1; a[i] = 0.0; }
        if (fabs(a[i]) > g_asolve_maxabs_a) g_asolve_maxabs_a = fabs(a[i]);
	}
    }
    g_asolve_calls++; g_asolve_unstable += unstable; g_asolve_nan += bad;
}
