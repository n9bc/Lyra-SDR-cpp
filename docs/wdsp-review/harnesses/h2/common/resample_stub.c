#include "comm.h"
RESAMPLE create_resample (int run, int size, double* in, double* out, int in_rate, int out_rate, double fc, int ncoef, double gain)
{ RESAMPLE a = malloc0(sizeof(resample)); a->run=run; a->size=size; a->in=in; a->out=out; if (run) { fprintf(stderr,"resampler not stubbed for run=1\n"); exit(1);} return a; }
void destroy_resample (RESAMPLE a){ free(a); }
void flush_resample (RESAMPLE a){ (void)a; }
int xresample (RESAMPLE a){ if (a->in != a->out) memcpy(a->out, a->in, a->size*sizeof(complex)); return a->size; }
void setFCLow_resample (RESAMPLE a, double fc_low){ (void)a; (void)fc_low; }
