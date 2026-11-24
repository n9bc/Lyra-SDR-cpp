/* Complex Burg AR fit + Etter-style two-sided extrapolation with raised-cosine cross-fade.
   Interleaved double IQ arrays. Proposed NOB-II mode 5 (harness version). */
#include <complex.h>
#include <stdlib.h>
#include <math.h>
typedef double _Complex cpx;

/* fit order p on x[0..n-1] (time order), return a[0..p], a[0]=1 */
static int burg(const cpx *x, int n, int p, cpx *a)
{
	cpx *f = malloc(n*sizeof(cpx)), *b = malloc(n*sizeof(cpx)), *t = malloc((p+1)*sizeof(cpx));
	for (int i=0;i<n;i++) f[i]=b[i]=x[i];
	for (int i=0;i<=p;i++) a[i]=0; a[0]=1;
	int ok=1;
	for (int m=1;m<=p;m++){
		cpx num=0; double den=0;
		for (int i=m;i<n;i++){ num += f[i]*conj(b[i-1]); den += creal(f[i]*conj(f[i]))+creal(b[i-1]*conj(b[i-1])); }
		if (den<=1e-300){ok=0;break;}
		cpx k = -2.0*num/den;
		for (int i=0;i<=m;i++) t[i]=a[i];
		for (int i=1;i<=m;i++) a[i]=t[i]+k*conj(t[m-i]);
		for (int i=n-1;i>=m;i--){ cpx fi=f[i], bi=b[i-1]; f[i]=fi+k*bi; b[i]=bi+conj(k)*fi; }
	}
	free(f);free(b);free(t);return ok;
}

/* left: nl samples immediately before gap (time order). right: nr samples immediately after gap.
   out: g samples. Returns 0 if no usable context (caller zero-fills). */
int ar_gap_fill(const double *left, int nl, const double *right, int nr, int g, int p, double *out)
{
	int useL = nl >= 4*p, useR = nr >= 4*p;
	if (!useL && !useR) return 0;
	cpx *fw = calloc(g, sizeof(cpx)), *bw = calloc(g, sizeof(cpx));
	cpx *a = malloc((p+1)*sizeof(cpx));
	cpx *buf = malloc((size_t)(nl+nr+g+p+1)*sizeof(cpx));
	if (useL){
		for (int i=0;i<nl;i++) buf[i]=left[2*i]+I*left[2*i+1];
		if (!burg(buf,nl,p,a)) useL=0; else
		for (int t=0;t<g;t++){ cpx s=0; for(int k=1;k<=p;k++) s-=a[k]*buf[nl+t-k]; buf[nl+t]=s; fw[t]=s; }
	}
	if (useR){ /* reverse right context, fit, extrapolate forward in reversed time */
		for (int i=0;i<nr;i++) buf[i]=right[2*(nr-1-i)]+I*right[2*(nr-1-i)+1];
		if (!burg(buf,nr,p,a)) useR=0; else
		for (int t=0;t<g;t++){ cpx s=0; for(int k=1;k<=p;k++) s-=a[k]*buf[nr+t-k]; buf[nr+t]=s; bw[g-1-t]=s; }
	}
	int ret = useL||useR;
	for (int t=0;t<g;t++){
		double w = useL&&useR ? 0.5-0.5*cos(M_PI*(t+1)/(g+1)) : (useR?1.0:0.0);
		cpx v=(1-w)*fw[t]+w*bw[t];
		out[2*t]=ret?creal(v):0; out[2*t+1]=ret?cimag(v):0;
	}
	free(fw);free(bw);free(a);free(buf);return ret;
}
