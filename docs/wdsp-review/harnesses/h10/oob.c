/* 1024 non-overlapping notches -> nbp reaches 1025 -> original reads del[1024] (heap OOB). Run under ASan. */
#include "comm.h"
#ifdef FIXED
int make_nbp (int, int*, double*, double*, double*, double*, double, int, double, double, double*, double*, int*, int);
#else
int make_nbp (int, int*, double*, double*, double*, double*, double, int, double, double, double*, double*, int*);
#endif
int main(void)
{
	int nn = 1024; static double c[1024], w[1024], lo[1024], hi[1024]; static int act[1024];
	for (int k = 0; k < nn; k++) { c[k] = 100.0 + 10.0 * k; w[k] = 2.0; lo[k] = c[k] - 1; hi[k] = c[k] + 1; act[k] = 1; }
	double* bl = malloc0(1025 * sizeof(double)); double* bh = malloc0(1025 * sizeof(double)); int hv;
#ifdef FIXED
	int nb = make_nbp(nn, act, c, w, lo, hi, 0.0, 0, 0.0, 20000.0, bl, bh, &hv, 1025);
#else
	int nb = make_nbp(nn, act, c, w, lo, hi, 0.0, 0, 0.0, 20000.0, bl, bh, &hv);
#endif
	printf("nbp=%d\n", nb);
	return 0;
}
