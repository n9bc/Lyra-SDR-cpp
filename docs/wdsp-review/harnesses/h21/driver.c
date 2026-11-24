/* Harness for finding 21: Rosenfell (det_type 1) boundary test in WDSP analyzer.c detector().
   Links against the real analyzer.c (orig or fixed) compiled with a POSIX shim.
   Parameters are computed with the exact SetAnalyzer() formulas (analyzer.c:1268-1285, real FFT, 1 stitch). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>

void detector(int det_type,int m,int num_pixels,double pix_per_bin,double bin_per_pix,double* bins,
              double* pixels,double inv_enb,double fsclipL,double fsclipH,double det_offset);

static uint64_t rs = 0x9E3779B97F4A7C15ULL;
static double urand(void){ rs ^= rs<<13; rs ^= rs>>7; rs ^= rs<<17; return ((rs>>11)+0.5)*(1.0/9007199254740992.0); }
#define max(a,b) (((a) > (b)) ? (a) : (b))

typedef struct { int m, imin, ilim; double ppb, bpp, doff; } Geo;

/* SetAnalyzer geometry for type 0 (real), num_stitch 1, clip */
static Geo geom(int size,int clip,double fsclipL,double fsclipH,int npix){
  Geo g; int out_size=size/2+1; int fscL=(int)fsclipL, fscH=(int)fsclipH;
  int begin=fscL+clip, end=out_size-1-clip-fscH;  /* eliminate() */
  g.m=end-begin;
  g.ppb=(double)npix/((double)(1*(out_size-1-2*clip))-fsclipL-fsclipH-1.0);
  g.doff=-g.ppb*(fsclipL-floor(fsclipL));
  g.bpp=((double)(1*(out_size-1-2*clip))-1.0-fsclipL-fsclipH)/((double)npix-1.0);
  g.imin=(fsclipL==floor(fsclipL))?0:1; g.ilim=(fsclipH==floor(fsclipH))?g.m:g.m-1;
  return g;
}

/* Independent reference: Rosenfell over the bin->pixel assignment used by detectors 0,2,3,4
   (pix = (int)(det_offset + i*ppb), clamped). Also records per-pixel bin counts. */
static void ref_rosenfell(const Geo* g,int npix,const double* bins,double* px,int* nb){
  for(int p=0;p<npix;p++){ nb[p]=0; }
  double prev_maxi=-1e300; int i=g->imin;
  while(i<g->ilim){
    int pc=(int)(g->doff+(double)i*g->ppb); if(pc>=npix)pc=npix-1;
    int j=i; double mn=1e300,mx=-1e300; int rose=0,fell=0;
    while(j<g->ilim){ int q=(int)(g->doff+(double)j*g->ppb); if(q>=npix)q=npix-1; if(q!=pc)break;
      if(bins[j]<mn)mn=bins[j]; if(bins[j]>mx)mx=bins[j];
      if(j>i){ if(bins[j]>bins[j-1])rose=1; if(bins[j]<bins[j-1])fell=1; }
      j++; }
    nb[pc]+=j-i;
    if(rose&&fell) px[pc]=(pc&1)?max(prev_maxi,mx):mn; else px[pc]=mx;
    prev_maxi=mx; i=j;
  }
}

int main(int argc,char** argv){
  int size = argc>1?atoi(argv[1]):16384;   /* FFT size */
  int npix = argc>2?atoi(argv[2]):1500;
  int clip = argc>3?atoi(argv[3]):0;
  const double STALE=-7.0;  /* sentinel: models t_pixels holding last frame's value */
  const double NOISE=1e-10, CARR=1e-4; /* carrier 60 dB above mean noise power */
  double* bins=malloc(sizeof(double)*size); double* px=malloc(sizeof(double)*npix);
  double* rpx=malloc(sizeof(double)*npix); int* nb=malloc(sizeof(int)*npix);
  printf("size=%d npix=%d clip=%d\n",size,npix,clip);
  printf("%6s %7s %7s | %8s %8s %8s %8s | %8s %8s\n","frac","ppb","bins/px","stale","diffRef","1binOnly","rngPix","carrLost","carrTot");
  double fracs[]={0.0,0.1,0.25,0.3,0.5,0.75,0.9,0.99};
  long totLost=0,totCarr=0,totDiff=0,totStale=0;
  for(int fi=0;fi<8;fi++){
    int os=size/2; double fL=floor(0.10*os)+fracs[fi], fH=floor(0.15*os)+0.37*(fracs[fi]>0); /* fractional edges as when zoom/pan */
    Geo g=geom(size,clip,fL,fH,npix);
    long stale=0,diff=0,onebin=0,lost=0,carr=0,multipix=0;
    int FR=50;
    for(int fr=0;fr<FR;fr++){
      for(int k=0;k<g.m;k++) bins[k]=-NOISE*log(urand()); /* exp-distributed noise power */
      /* 20 single-bin carriers at random bins */
      int cb[20]; for(int c=0;c<20;c++){ cb[c]=g.imin+2+(int)(urand()*(g.ilim-g.imin-4)); bins[cb[c]]=CARR; }
      for(int p=0;p<npix;p++) px[p]=STALE;
      detector(1,g.m,npix,g.ppb,g.bpp,bins,px,1.0,fL,fH,g.doff);
      ref_rosenfell(&g,npix,bins,rpx,nb);
      for(int p=0;p<npix;p++){
        if(px[p]==STALE) stale++;
        if(px[p]!=rpx[p] && nb[p]>0) diff++;
        if(nb[p]>1) multipix++;
      }
      for(int c=0;c<20;c++){
        int p=(int)(g.doff+(double)cb[c]*g.ppb); if(p>=npix)p=npix-1;
        /* Rosenfell shows a peak on the even/odd pair; accept any pixel in p-1..p+1 */
        double best=-1e300; for(int q=p-1;q<=p+1;q++) if(q>=0&&q<npix&&px[q]>best) best=px[q];
        double rbest=-1e300; for(int q=p-1;q<=p+1;q++) if(q>=0&&q<npix&&rpx[q]>rbest) rbest=rpx[q];
        carr++; if(best<CARR*0.5) lost++;
        if(rbest<CARR*0.5) fprintf(stderr,"note: reference also misses carrier bin %d\n",cb[c]);
      }
    }
    /* count pixels whose final value equals only the pixel's last bin while reference differs: proxy for 'reduced to one bin' */
    (void)onebin;
    printf("%6.2f %7.4f %7.3f | %8ld %8ld %8s %8ld | %8ld %8ld\n",fracs[fi],g.ppb,1.0/g.ppb,stale,diff,"-",multipix/FR,lost,carr);
    totLost+=lost; totCarr+=carr; totDiff+=diff; totStale+=stale;
  }

  /* PAN / FLICKER test: one carrier fixed in absolute frequency with a window-like main lobe
     (0,-3,-12,-30 dB at 0,+-1,+-2,+-3 bins, true peak 60 dB over noise), span edge panned in
     0.01-bin steps over 4 bins (400 frames). Metric: displayed peak (max px over +-2 pixels of the
     carrier) relative to the reference detector output, in dB. */
  {
    int os=size/2; double base=floor(0.10*os); double cabs=base+0.5*(os-floor(0.25*os)); int ca=(int)cabs;
    double lobe[7]={1e-3,0.063,0.5,1.0,0.5,0.063,1e-3}; /* power, approx -30,-12,-3,0 dB */
    int FR=400, flick=0, gt3=0; double worst=0, sumerr=0;
    for(int fr=0;fr<FR;fr++){
      double fL=base+fr*0.01, fH=floor(0.15*os)-fr*0.01+0.37; if(fH<0)fH=0.37;
      Geo g=geom(size,clip,fL,fH,npix); int fscL=(int)fL;
      for(int k=0;k<g.m;k++) bins[k]=-NOISE*log(urand());
      int cbin=ca-fscL-clip; for(int t=-3;t<=3;t++) bins[cbin+t]+=CARR*lobe[t+3];
      for(int p=0;p<npix;p++) px[p]=STALE;
      detector(1,g.m,npix,g.ppb,g.bpp,bins,px,1.0,fL,fH,g.doff);
      ref_rosenfell(&g,npix,bins,rpx,nb);
      int p=(int)(g.doff+(double)cbin*g.ppb);
      double b=-1e300,rb=-1e300; for(int q=p-2;q<=p+2;q++){ if(px[q]>b)b=px[q]; if(rpx[q]>rb)rb=rpx[q]; }
      double e=10*log10(rb/b); sumerr+=e; if(e>worst)worst=e; if(e>3.0)gt3++; if(b<CARR*1e-3)flick++;
    }
    printf("PAN: frames=%d meanPeakErr=%.2f dB worst=%.2f dB frames>3dB=%d frames peak<-30dB(vanished)=%d\n",FR,sumerr/FR,worst,gt3,flick);
  }
  printf("TOTAL stale=%ld diffRef=%ld carrLost=%ld/%ld\n",totStale,totDiff,totLost,totCarr);
  return 0;
}
