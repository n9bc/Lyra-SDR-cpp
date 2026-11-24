/* WDSP 2.11 lmath.c asolve, verbatim arithmetic; only observation counters added (no behaviour change) */
#include "comm.h"
void asolve(int xsize, int asize, double* x, double* a, double* r, double* z)
{
    int i, j, k;
    double beta, alpha, t;
    int unstable = 0, bad = 0;
	memset(r, 0, (asize + 1) * sizeof(double));		// work space
	memset(z, 0, (asize + 1) * sizeof(double));		// work space
    for (i = 0; i <= asize; i++)
    {
		for (j = 0; j < xsize; j++)
			r[i] += x[j] * x[j - i];
    }
    z[0] = 1.0;
    beta = r[0];
    for (k = 0; k < asize; k++)
    {
        alpha = 0.0;
        for (j = 0; j <= k; j++)
            alpha -= z[j] * r[k + 1 - j];
        alpha /= beta;
        if (fabs(alpha) >= 1.0 || !(beta > 0.0)) unstable = 1;
        if (fabs(alpha) > g_asolve_maxabs_k && isfinite(alpha)) g_asolve_maxabs_k = fabs(alpha);
        for (i = 0; i <= (k + 1) / 2; i++)
        {
            t = z[k + 1 - i] + alpha * z[i];
            z[i] = z[i] + alpha * z[k + 1 - i];
            z[k + 1 - i] = t;
        }
        beta *= 1.0 - alpha * alpha;
    }
    for (i = 0; i < asize; i++)
	{
        a[i] = - z[i + 1];
        if (!isfinite(a[i])) bad = 1;
		if (a[i] != a[i]) a[i] = 0.0;
        if (fabs(a[i]) > g_asolve_maxabs_a && isfinite(a[i])) g_asolve_maxabs_a = fabs(a[i]);
	}
    g_asolve_calls++; g_asolve_unstable += unstable; g_asolve_nan += bad;
}
