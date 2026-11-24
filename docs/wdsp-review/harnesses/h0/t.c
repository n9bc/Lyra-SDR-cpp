#include <stdio.h>
extern float GG[], GGS[];
int main(){ for(int g=24; g<29; g++) printf("%d GG=%g GGS=%g\n",g,GG[g],GGS[g]); int n=0; for(int i=0;i<241*241;i++) if(GG[i]!=GG[i]||GGS[i]!=GGS[i]) n++; printf("nan entries %d\n",n);}
