/* Running-sum cancellation residual: WDSP case-2 recurrence (av_sum += t - old), no resets.
   Double (as WDSP) vs float32 (hypothetical port). Carrier P in one bin for 500 frames, then off;
   floor exp-distributed mean F. Report residual/ideal at the carrier bin after carrier gone. */
#include <stdio.h>
#include <math.h>
#include <stdint.h>
static uint64_t r=0x9E3779B97F4A7C15ull; static double u(void){r^=r<<13;r^=r>>7;r^=r<<17;return((r>>11)+0.5)/9007199254740992.0;}
int main(void){
  double Ps[]={1e3,1e6,1e9}; const double F=1e-7; const int N=10;
  for(int p=0;p<3;p++){ double P=Ps[p];
    double bd[60]={0}, sd=0; float bf[60]={0}, sf=0; int in=0,out=0,av=0; r=0x9E3779B97F4A7C15ull;
    double true_sum_err_d=0, true_sum_err_f=0; int negf=0; double hist[60]={0};
    for(int f=0;f<5000;f++){ double t=-log(u())*F + (f<500?P:0);
      if(av<N){av++; sd+=t; sf+=(float)t;} else {sd+=t-bd[out]; sf+=(float)t-bf[out]; if(++out==60)out=0;}
      bd[in]=t; bf[in]=(float)t; if(++in==60)in=0;
      if(f==4999){ double ex=0; for(int j=0;j<N;j++) ex+=bd[(in-1-j+60)%60];
        printf("P/F=%.0e (%.0f dB above floor): ideal %.3e  double %.3e (err %+.4f dB)  float %.3e (err %+.2f dB%s)\n",P/F,10*log10(P/F),ex,sd,10*log10(sd/ex),(double)sf, sf>0?10*log10(sf/ex):NAN, sf<=0?", NEGATIVE":""); }
    }
  }
}
