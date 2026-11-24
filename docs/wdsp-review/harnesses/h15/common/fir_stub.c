#include "comm.h"
double* fir_bandpass (int N, double f_low, double f_high, double samplerate, int wintype, int rtype, double scale)
{

	double *c_impulse = (double *) malloc0 (N * sizeof (complex));
	double ft = (f_high - f_low) / (2.0 * samplerate);
	double ft_rad = TWOPI * ft;
	double w_osc = PI * (f_high + f_low) / samplerate;
	int i, j;
	double m = 0.5 * (double)(N - 1);
	double delta = PI / m;
	double cosphi;
	double posi, posj;
	double sinc, window, coef;

	if (N & 1)
	{
		switch (rtype)
		{
		case 0:
			c_impulse[N >> 1] = scale * 2.0 * ft;
			break;
		case 1:
			c_impulse[N - 1] = scale * 2.0 * ft;
			c_impulse[  N  ] = 0.0;
			break;
		}
	}
	for (i = (N + 1) / 2, j = N / 2 - 1; i < N; i++, j--)
	{
		posi = (double)i - m;
		posj = (double)j - m;
		sinc = sin (ft_rad * posi) / (PI * posi);
		switch (wintype)
		{
		case 0:	// Blackman-Harris 4-term
			cosphi = cos (delta * i);
			window  =             + 0.21747
					+ cosphi *  ( - 0.45325
					+ cosphi *  ( + 0.28256
					+ cosphi *  ( - 0.04672 )));
			break;
		case 1:	// Blackman-Harris 7-term
		default:
			cosphi = cos (delta * i);
			window	=			  + 6.3964424114390378e-02
					+ cosphi *  ( - 2.3993864599352804e-01
					+ cosphi *  ( + 3.5015956323820469e-01
					+ cosphi *	( - 2.4774111897080783e-01
					+ cosphi *  ( + 8.5438256055858031e-02
					+ cosphi *	( - 1.2320203369293225e-02
					+ cosphi *	( + 4.3778825791773474e-04 ))))));
			break;
		}
		coef = scale * sinc * window;
		switch (rtype)
		{
		case 0:
			c_impulse[i] = + coef * cos (posi * w_osc);
			c_impulse[j] = + coef * cos (posj * w_osc);
			break;
		case 1:
			c_impulse[2 * i + 0] = + coef * cos (posi * w_osc);
			c_impulse[2 * i + 1] = - coef * sin (posi * w_osc);
			c_impulse[2 * j + 0] = + coef * cos (posj * w_osc);
			c_impulse[2 * j + 1] = - coef * sin (posj * w_osc);
			break;
		}
	}


	return c_impulse;
}
