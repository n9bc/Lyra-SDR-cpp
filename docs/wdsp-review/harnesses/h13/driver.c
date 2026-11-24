// Driver for WDSP doublepole: same source links against orig/ (fircore FIR) or fixed/ (recursive one-pole).
#include "comm.h"
#include <time.h>
#include <stdint.h>

static uint64_t rs = 0x9E3779B97F4A7C15ull;
static double urand(void){ rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return ((rs >> 11) + 0.5) * (1.0/9007199254740992.0); }
static double grand(void){ return sqrt(-2.0*log(urand())) * cos(TWOPI*urand()); }
static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec + 1e-9*t.tv_nsec; }

int main(int argc, char** argv)
{
	const char* test = argv[1];
	if (!strcmp(test, "imp")) {            // imp <bw> <rate> <size> <N> <outfile>
		double bw = atof(argv[2]); int rate = atoi(argv[3]); int size = atoi(argv[4]); int N = atoi(argv[5]);
		double* buf = malloc0(2 * size * sizeof(complex)) /* RXA midbuff is 2*dsp_size; fircore crev writes 2*size */;
		DOUBLEPOLE a = create_doublepole(1, 0, size, buf, buf, 600.0, bw, rate, 2.0, 0);
		FILE* f = fopen(argv[6], "wb");
		for (int b = 0; b < N / size; b++) {
			memset(buf, 0, size * sizeof(complex));
			if (b == 0) buf[0] = 1.0;
			xdoublepole(a, 0);
			fwrite(buf, sizeof(complex), size, f);
		}
		fclose(f); printf("nc=%d\n", a->nc); destroy_doublepole(a);
	}
	else if (!strcmp(test, "noise")) {     // noise <bw> <rate> <size> <N> <outfile>  (mode 2, gaussian noise)
		double bw = atof(argv[2]); int rate = atoi(argv[3]); int size = atoi(argv[4]); int N = atoi(argv[5]);
		double* buf = malloc0(2 * size * sizeof(complex)) /* RXA midbuff is 2*dsp_size; fircore crev writes 2*size */;
		DOUBLEPOLE a = create_doublepole(1, 0, size, buf, buf, 600.0, bw, rate, 2.0, 2);
		FILE* f = fopen(argv[6], "wb");
		for (int b = 0; b < N / size; b++) {
			for (int i = 0; i < size; i++) { buf[2*i] = grand(); buf[2*i+1] = grand(); }
			xdoublepole(a, 0);
			fwrite(buf, sizeof(complex), size, f);
		}
		fclose(f); destroy_doublepole(a);
	}
	else if (!strcmp(test, "switch")) {    // switch <bw0> <bw1> <rate> <size> <N> <switchblock> <outfile>  (mode 2, steady tone at fc=600)
		double bw0 = atof(argv[2]), bw1 = atof(argv[3]); int rate = atoi(argv[4]); int size = atoi(argv[5]); int N = atoi(argv[6]); int sb = atoi(argv[7]);
		double* buf = malloc0(2 * size * sizeof(complex)) /* RXA midbuff is 2*dsp_size; fircore crev writes 2*size */;
		DOUBLEPOLE a = create_doublepole(1, 0, size, buf, buf, 600.0, bw0, rate, 2.0, 2);
		FILE* f = fopen(argv[8], "wb");
		long n = 0; double tcall = 0;
		for (int b = 0; b < N / size; b++) {
			if (b == sb) { double t0 = now(); CalcDoublepoleFilter(a, 600.0, bw1, a->gain); tcall = now() - t0; }
			for (int i = 0; i < size; i++, n++) { double s = cos(TWOPI * 600.0 * n / rate); buf[2*i] = s; buf[2*i+1] = 0.0; }
			xdoublepole(a, 0);
			fwrite(buf, sizeof(complex), size, f);
		}
		fclose(f); printf("nc_after=%d calc_call_ms=%.3f\n", a->nc, tcall * 1e3); destroy_doublepole(a);
	}
	else if (!strcmp(test, "retune")) {    // retune <rate> <size> <ncalls>: time CalcDoublepoleFilter alternating bw across 68 Hz threshold
		int rate = atoi(argv[2]); int size = atoi(argv[3]); int nc = atoi(argv[4]);
		double* buf = malloc0(2 * size * sizeof(complex)) /* RXA midbuff is 2*dsp_size; fircore crev writes 2*size */;
		DOUBLEPOLE a = create_doublepole(1, 0, size, buf, buf, 600.0, 70.0, rate, 2.0, 2);
		for (int k = 0; k < nc; k++) {
			double t0 = now(); CalcDoublepoleFilter(a, 600.0, (k & 1) ? 70.0 : 60.0, a->gain); double t = now() - t0;
			printf("call %d bw=%g nc=%d ms=%.3f\n", k, (k & 1) ? 70.0 : 60.0, a->nc, t * 1e3);
		}
		destroy_doublepole(a);
	}
	else if (!strcmp(test, "bench")) {     // bench <bw> <rate> <size> <seconds_of_audio>
		double bw = atof(argv[2]); int rate = atoi(argv[3]); int size = atoi(argv[4]); double secs = atof(argv[5]);
		double* buf = malloc0(2 * size * sizeof(complex)) /* RXA midbuff is 2*dsp_size; fircore crev writes 2*size */;
		DOUBLEPOLE a = create_doublepole(1, 0, size, buf, buf, 600.0, bw, rate, 2.0, 2);
		int nb = (int)(secs * rate / size); double acc = 0;
		for (int i = 0; i < size; i++) { buf[2*i] = grand(); buf[2*i+1] = grand(); }
		for (int b = 0; b < 50; b++) xdoublepole(a, 0);
		double t0 = now();
		for (int b = 0; b < nb; b++) { buf[0] += 1e-3; xdoublepole(a, 0); acc += buf[2]; if (fabs(buf[2]) > 1e6) memset(buf,0,size*sizeof(complex)); }
		double t = now() - t0;
		printf("bw=%g rate=%d size=%d nc=%d ns_per_sample=%.2f realtime_frac=%.6f (chk %g)\n", bw, rate, size, a->nc, t * 1e9 / ((double)nb * size), t / secs, acc);
		destroy_doublepole(a);
	}
	return 0;
}
