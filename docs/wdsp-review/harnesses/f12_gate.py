import math, cmath
fs=48000; N=4096; f0=1000.0; n0=2048
def run(L):
    x=[]
    for n in range(N):
        if L=="ref": g=1.0
        elif n<n0: g=1.0
        elif n>=n0+L: g=0.0
        else: g=0.5*(1+math.cos(math.pi*(n-n0)/L))
        w=0.35875-0.48829*math.cos(2*math.pi*n/N)+0.14128*math.cos(4*math.pi*n/N)-0.01168*math.cos(6*math.pi*n/N)
        x.append(w*g*math.cos(2*math.pi*f0*n/fs))
    tw=[cmath.exp(-2j*math.pi*n/N) for n in range(N)]
    P=[]
    for k in range(0,N//2):
        s=0j
        for n in range(N): s+=x[n]*tw[(k*n)%N]
        P.append((k*fs/N,abs(s)**2))
    tot=sum(p for f,p in P)
    return {o:round(10*math.log10(sum(p for f,p in P if abs(f-f0)>o)/tot),1) for o in (300,1000,2000,4000)}
for L in ("ref",0,64,256,1024):
    print("ramp",L,"samples:",run(L))
