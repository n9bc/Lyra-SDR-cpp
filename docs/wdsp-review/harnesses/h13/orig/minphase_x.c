#include "comm.h"
void analytic (int N, double* in, double* out)
{
	int i;
	double inv_N = 1.0 / (double)N;
	double two_inv_N = 2.0 * inv_N;
	double* x = (double *) malloc0 (N * sizeof (complex));
	fftw_plan pfor = fftw_plan_dft_1d (N, (fftw_complex *) in,
			(fftw_complex *) x, FFTW_FORWARD, FFTW_PATIENT);
	fftw_plan prev = fftw_plan_dft_1d (N, (fftw_complex *) x,
			(fftw_complex *) out, FFTW_BACKWARD, FFTW_PATIENT);
	fftw_execute (pfor);
	x[0] *= inv_N;
	x[1] *= inv_N;
	for (i = 1; i < N / 2; i++)
	{
		x[2 * i + 0] *= two_inv_N;
		x[2 * i + 1] *= two_inv_N;
	}
	x[N + 0] *= inv_N;
	x[N + 1] *= inv_N;
	memset (&x[N + 2], 0, (N - 2) * sizeof (double));
	fftw_execute (prev);
	fftw_destroy_plan (prev);
	fftw_destroy_plan (pfor);
	_aligned_free (x);
}
typedef struct _minphase
{
    int N;
    int pfactor;
    int size;
    double inv_size;
    double* firpad;
    double* firfreq;
    double* mag;
    double* ana;
    double* anax;
    double* newfreq;
    double* impulse;
    fftw_plan p_fir;
    fftw_plan p_anafor;
    fftw_plan p_anainv;
    fftw_plan p_imp;
} minphase, *MINPHASE;

MINPHASE create_minphase (int N, int pfactor)
{
    MINPHASE a  = (MINPHASE) malloc0 (sizeof (minphase));
    a->N        = N;
    a->pfactor  = pfactor;
    a->size     = N * pfactor;
    a->inv_size = 1.0 / (double) a->size;

    a->firpad  = (double *) malloc0 (a->size * sizeof (complex));
    a->firfreq = (double *) malloc0 (a->size * sizeof (complex));
    a->mag     = (double *) malloc0 (a->size * sizeof (double));
    a->ana     = (double *) malloc0 (a->size * sizeof (complex));
    a->anax    = (double *) malloc0 (a->size * sizeof (complex));
    a->newfreq = (double *) malloc0 (a->size * sizeof (complex));
    a->impulse = (double *) malloc0 (a->size * sizeof (complex));

    a->p_fir    = fftw_plan_dft_1d (a->size, (fftw_complex *) a->firpad,  (fftw_complex *) a->firfreq, FFTW_FORWARD,  FFTW_PATIENT);
    a->p_anafor = fftw_plan_dft_1d (a->size, (fftw_complex *) a->ana,     (fftw_complex *) a->anax,    FFTW_FORWARD,  FFTW_PATIENT);
    a->p_anainv = fftw_plan_dft_1d (a->size, (fftw_complex *) a->anax,    (fftw_complex *) a->ana,     FFTW_BACKWARD, FFTW_PATIENT);
    a->p_imp    = fftw_plan_dft_1d (a->size, (fftw_complex *) a->newfreq, (fftw_complex *) a->impulse, FFTW_BACKWARD, FFTW_PATIENT);

    memset (a->firpad, 0, a->size * sizeof (complex));
    return a;
}

void destroy_minphase (MINPHASE a)
{
    fftw_destroy_plan (a->p_imp);
    fftw_destroy_plan (a->p_anainv);
    fftw_destroy_plan (a->p_anafor);
    fftw_destroy_plan (a->p_fir);
    _aligned_free (a->impulse);
    _aligned_free (a->newfreq);
    _aligned_free (a->anax);
    _aligned_free (a->ana);
    _aligned_free (a->mag);
    _aligned_free (a->firfreq);
    _aligned_free (a->firpad);
    _aligned_free (a);
}

void mp_imp_exec (MINPHASE a, double* fir, double* mpfir)
{
    int i, size = a->size, N = a->N;
    double inv_size = a->inv_size;
    double two_inv_size = 2.0 * inv_size;
    memcpy (a->firpad, fir, N * sizeof (complex));
    fftw_execute (a->p_fir);
    for (i = 0; i < size; i++)
    {
        double re = a->firfreq[2 * i + 0];
        double im = a->firfreq[2 * i + 1];
        double m  = sqrt (re * re + im * im) * inv_size;
        a->mag[i]         = m;
        a->ana[2 * i + 0] = (m > 0.0) ? log (m) : log (1.0e-300);
        a->ana[2 * i + 1] = 0.0;
    }
    fftw_execute (a->p_anafor);
    a->anax[0] *= inv_size;
    a->anax[1] *= inv_size;
    for (i = 1; i < size / 2; i++)
    {
        a->anax[2 * i + 0] *= two_inv_size;
        a->anax[2 * i + 1] *= two_inv_size;
    }
    a->anax[size + 0] *= inv_size;
    a->anax[size + 1] *= inv_size;
    memset (&a->anax[size + 2], 0, (size - 2) * sizeof (double));
    fftw_execute (a->p_anainv);
    for (i = 0; i < size; i++)
    {
        double ph = a->ana[2 * i + 1];
        a->newfreq[2 * i + 0] = + a->mag[i] * cos (ph);
        a->newfreq[2 * i + 1] = - a->mag[i] * sin (ph);
    }
    fftw_execute (a->p_imp);
    memcpy (mpfir,  a->impulse, N * sizeof (complex));
}

typedef struct _fsamp
{
    int N;
    int wintype;
    int nh;
    int even;
    double* cosr;
    double* sinr;
    double* window;
    double* X;
    double* impulse;
    fftw_plan p_c2r;
} fsamp, *FSAMP;
