/* driver: argv: scenario(0=two carriers off-DC,1=carrier at DC,2=noise only,3=AM-modulated carrier off-DC) mode hang_ms impulses(0/1) */
#include "comm.h"
#include <stdio.h>
#include <stdint.h>
#include <fftw3.h>
static uint64_t rs=0x9E3779B97F4A7C15ull;
static double urand(void){ rs^=rs<<13; rs^=rs>>7; rs^=rs<<17; return (rs>>11)*(1.0/9007199254740992.0);}
static double gauss(void){ double u=urand()+1e-300,v=urand(); return sqrt(-2*log(u))*cos(2*PI*v);}
#define FS 192000.0
#define NT (192000*2)
#define BS 1024
static double clean[2*NT], inp[2*NT], outp[2*NT]; static int flag[NT];
static double bandpow(double *x, int start, int n, double f1, double f2){
	fftw_complex *b=fftw_malloc(sizeof(fftw_complex)*n); fftw_plan pl=fftw_plan_dft_1d(n,b,b,FFTW_FORWARD,FFTW_ESTIMATE);
	for(int i=0;i<n;i++){double w=0.5-0.5*cos(2*PI*i/n); b[i][0]=x[2*(start+i)]*w; b[i][1]=x[2*(start+i)+1]*w;}
	fftw_execute(pl); double s=0; for(int k=0;k<n;k++){ double f=(k<n/2?k:k-n)*FS/n; if(f>=f1&&f<=f2) s+=b[k][0]*b[k][0]+b[k][1]*b[k][1]; }
	fftw_destroy_plan(pl); fftw_free(b); return s;
}
int main(int argc,char**argv){
	int sc=atoi(argv[1]), mode=atoi(argv[2]); double hang=atof(argv[3])*1e-3; int imp=atoi(argv[4]); int sp=argc>5?atoi(argv[5]):1920;
	double sig=1e-4; double f1=20000, f2=-37000;
	if(sc==1){f1=0; f2=0;}
	for(int n=0;n<NT;n++){
		double t=n/FS, i=0,q=0;
		if(sc==0||sc==1||sc==4){ i=cos(2*PI*f1*t); q=sin(2*PI*f1*t); if(sc==0||sc==4){ i+=0.3*cos(2*PI*f2*t+1.0); q+=0.3*sin(2*PI*f2*t+1.0);} }
		if(sc==3){ double env=1+0.5*sin(2*PI*3.1*t)*sin(2*PI*230*t); i=env*cos(2*PI*f1*t); q=env*sin(2*PI*f1*t);} 
		if(sc==4){ i+=1e-3*cos(2*PI*5000*t); q+=1e-3*sin(2*PI*5000*t);} 
		double ns = (sc==2)?1.0:sig;
		i+=ns*gauss()/sqrt(2); q+=ns*gauss()/sqrt(2);
		clean[2*n]=i; clean[2*n+1]=q; inp[2*n]=i; inp[2*n+1]=q; flag[n]=0;
	}
	if(imp) for(int n=4000;n<NT-100;n+=sp+(int)(urand()*sp/5)){ double ph=urand()*2*PI; for(int k=0;k<3;k++){ inp[2*(n+k)]+=100*cos(ph+k); inp[2*(n+k)+1]+=100*sin(ph+k); flag[n+k]=1; } }
	double *ib=malloc(16*BS),*ob=malloc(16*BS);
	NOB a=create_nob(1,BS,ib,ob,FS,mode,0.0001,0.0001,0.0001,hang,0.025,0.05,8.0);
	int D=a->in_idx-a->out_idx;
	for(int blk=0;blk<NT/BS;blk++){ memcpy(ib,inp+2*blk*BS,16*BS); xnob(a); memcpy(outp+2*blk*BS,ob,16*BS);} 
	/* error vs delayed clean */
	int st=20000+D; double ee=0, ce=0, eg=0, ng=0, og=0, cg=0; int gaps=0;
	for(int n=st;n<NT;n++){ int m=n-D; double ei=outp[2*n]-clean[2*m], eq=outp[2*n+1]-clean[2*m+1];
		ee+=ei*ei+eq*eq; ce+=clean[2*m]*clean[2*m]+clean[2*m+1]*clean[2*m+1];
		/* window of +-60 samples around impulse as gap region (blank ~80 samples at 0.1ms each) */
	}
	/* in-gap metrics: samples where output differs from delayed input by masking: detect blanked region = |out - in_delayed|>1e-12 */
	for(int n=st;n<NT;n++){ int m=n-D; double di=outp[2*n]-inp[2*m], dq=outp[2*n+1]-inp[2*m+1];
		if(di*di+dq*dq>1e-20){ ng++; double ei=outp[2*n]-clean[2*m], eq=outp[2*n+1]-clean[2*m+1]; eg+=ei*ei+eq*eq; cg+=clean[2*m]*clean[2*m]+clean[2*m+1]*clean[2*m+1]; og+=outp[2*n]*outp[2*n]+outp[2*n+1]*outp[2*n+1]; } }
	/* splatter: band 3.5-6.5 kHz (clean has only noise), 65536-pt FFT segments */
	static double err[2*NT]; for(int n=D;n<NT;n++){err[2*n]=outp[2*n]-clean[2*(n-D)];err[2*n+1]=outp[2*n+1]-clean[2*(n-D)+1];}
	int L=65536; double bo=0,bc=0,be=0; for(int s=st; s+L<=NT; s+=L){ bo+=bandpow(outp,s,L,3500,6500); double *cd=clean+2*(s-D); bc+=bandpow(cd-0,0,L,3500,6500); be+=bandpow(err,s,L,3500,6500);} 
	printf("sc=%d mode=%d hang=%.2fms imp=%d D=%d | SER(total err/clean)=%.2f dB | in-gap err/clean=%.2f dB (gap samples=%d) | gap out pwr/clean=%.2f dB | band3.5-6.5k out/clean=%.2f dB err/clean=%.2f dB\n",
		sc,mode,hang*1e3,imp,D,10*log10(ee/ce),10*log10(eg/(cg+1e-300)),(int)ng,10*log10(og/(cg+1e-300)),10*log10(bo/bc),10*log10(be/bc));
	return 0;
}
