import math,cmath
def code_bqs(fs,fl,fh):
    wl=2*fs*math.tan(math.pi*fl/fs); wh=2*fs*math.tan(math.pi*fh/fs)
    BW=wh-wl; W0=math.sqrt(wl*wh)
    pr=[-math.sin(math.pi/4),-math.sin(3*math.pi/4)]; pi_=[math.cos(math.pi/4),math.cos(3*math.pi/4)]
    K=2*fs; secs=[]
    for k in range(2):
        a1=-BW*pr[k]; a2=W0*W0+BW*BW*(pi_[k]**2-pr[k]**2)
        d0=K*K+a1*K+a2; secs.append(([BW*K/d0,0,-BW*K/d0],[1,(-2*K*K+2*a2)/d0,(K*K-a1*K+a2)/d0]))
    return secs
def true_bp(fs,fl,fh):
    wl=2*fs*math.tan(math.pi*fl/fs); wh=2*fs*math.tan(math.pi*fh/fs)
    BW=wh-wl; W0=math.sqrt(wl*wh); K=2*fs
    p=cmath.exp(1j*3*math.pi/4)  # upper LP pole
    # roots of s^2 - p BW s + W0^2
    b=-p*BW; c=W0*W0; d=cmath.sqrt(b*b-4*c)
    roots=[(-b+d)/2,(-b-d)/2]
    secs=[]
    for r in roots:
        a1=-2*r.real; a2=abs(r)**2   # s^2 + a1 s + a2 with conj pair
        d0=K*K+a1*K+a2
        secs.append(([BW*K/d0,0,-BW*K/d0],[1,(-2*K*K+2*a2)/d0,(K*K-a1*K+a2)/d0]))
    return secs
def H(secs,f,fs):
    z=cmath.exp(-1j*2*math.pi*f/fs); h=1
    for b,a in secs: h*=(b[0]+b[1]*z+b[2]*z*z)/(a[0]+a[1]*z+a[2]*z*z)
    return h
def db(x): return 20*math.log10(abs(x)+1e-300)
for fs in (384000,192000):
  for name,fn in (("code",code_bqs),("true",true_bp)):
    s=fn(fs,58000,75000)
    fr=[i*10 for i in range(1,int(fs/2/10))]
    r=[(f,db(H(s,f,fs))) for f in fr]
    pk=max(r,key=lambda t:t[1]); band=[f for f,d in r if d>=pk[1]-3 and d>=-3+0 or False]
    b3=[f for f,d in r if d>=-3.0]
    # noise-equivalent bw (power integral), white input, and f^2-weighted
    df=10; nbw=sum(abs(H(s,f,fs))**2 for f in fr)*df
    f2=sum(abs(H(s,f,fs))**2*f*f for f in fr)*df
    print(fs,name,"peak %.2f dB @ %d"%(pk[1],pk[0]),"-3dB(abs) %s-%s"%(b3[0] if b3 else None,b3[-1] if b3 else None),
      "57k %.1f 59.5k %.1f 67k %.2f 92k %.1f"%(db(H(s,57000,fs)),db(H(s,59500,fs)),db(H(s,67000,fs)),db(H(s,92000,fs)) if fs/2>92000 else float('nan')),
      "NBW %.0f Hz f2-weighted %.3e"%(nbw,f2))
# deemphasis
for fs in (192000,384000):
  for f in (10000,15000):
    def g(tau):
        c=1/math.tan(1/(2*fs*tau)); d=1+c; b0=b1=1/d; a1=(1-c)/d
        z=cmath.exp(-1j*2*math.pi*f/fs); return abs((b0+b1*z)/(1+a1*z))
    print("dmph fs",fs,"f",f,"75us %.2f 50us %.2f diff %.2f"%(db(g(75e-6)),db(g(50e-6)),db(g(50e-6))-db(g(75e-6))))
for f in (10000,15000):
    a=lambda t:-10*math.log10(1+(2*math.pi*f*t)**2)
    print("analog",f,a(75e-6),a(50e-6),a(50e-6)-a(75e-6))
print("relative -3dB bands")
for fs in (384000,192000):
  for name,fn in (("code",code_bqs),("true",true_bp)):
    s=fn(fs,58000,75000); fr=range(40000,int(min(fs/2,100000)),10)
    r=[(f,db(H(s,f,fs))) for f in fr]; pk=max(d for f,d in r)
    b=[f for f,d in r if d>=pk-3]
    print(fs,name,b[0],b[-1],b[-1]-b[0],"57k rel %.1f, 67k rel %.2f"%(db(H(s,57000,fs))-pk,db(H(s,67000,fs))-pk))
for fs in (384000,192000):
  for name,fn in (("code",code_bqs),("true",true_bp)):
    s=fn(fs,58000,75000)
    print(fs,name," ".join("%dk:%.1f"%(f/1000,db(H(s,f,fs))) for f in (38000,45000,50000,53000,55000,57000,60000,67000,74500,76000)))
