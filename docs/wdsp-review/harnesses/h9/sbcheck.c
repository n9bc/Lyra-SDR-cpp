#include "comm.h"
#include <stdio.h>
// Which sideband does sbmode 1/2 pass? Feed a tone at +f or -f with phs fixed at 0.
int main(void){ double in[2], out[2];
 for (int sb = 1; sb <= 2; sb++) for (int s = -1; s <= 1; s += 2){
  AMD a = create_amd(1,1,in,out,1,0,sb,48000,-2000,2000,1,250,0.02,1.4); double p=0;
  for (int n=0;n<48000;n++){ a->phs=0; double w=s*TWOPI*1000.0*n/48000; in[0]=cos(w); in[1]=sin(w); xamd(a); if(n>4800) p+=out[0]*out[0]; }
  printf("sbmode=%d tone=%+d Hz power=%.4g\n", sb, s*1000, p/(48000-4801)); destroy_amd(a);} }
