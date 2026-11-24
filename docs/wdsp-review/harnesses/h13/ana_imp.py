import struct, math, sys, cmath
H=sys.argv[1]
def load(p):
    b=open(p,'rb').read(); v=struct.unpack('<%dd'%(len(b)//8),b)
    return [complex(v[2*i],v[2*i+1]) for i in range(len(v)//2)]
for bw,nc in [(100,2048),(69,2048),(60,4096),(35,4096),(20,8192),(16,16384)]:
    o=load(f'{H}/out/imp_orig_{bw}.bin'); f=load(f'{H}/out/imp_fixed_{bw}.bin')
    # lag check: index of first nonzero
    fo=next(i for i,x in enumerate(o) if abs(x)>1e-12); ff=next(i for i,x in enumerate(f) if abs(x)>1e-12)
    pk=max(abs(x) for x in f)
    d_in=max(abs(o[i]-f[i]) for i in range(nc))
    tail_f=max(abs(f[i]) for i in range(nc,len(f)))
    tail_o=max(abs(o[i]) for i in range(nc,len(o)))
    Ef=sum(abs(x)**2 for x in f); Ed=sum(abs(o[i]-f[i])**2 for i in range(len(f)))
    alpha=math.pi*bw/1.7/48000
    # frequency response at fc (600 Hz) and +-bw/2 and 3 kHz
    def H_(h,fr): w=-2j*math.pi*fr/48000; return sum(h[i]*cmath.exp(w*i) for i in range(len(h)))
    rows=[]
    for fr in (600,600+bw/2,600+3*bw,3000):
        ho=H_(o[:nc+2048],fr); hf=H_(f,fr)
        rows.append(f'{fr:.0f}Hz: orig {20*math.log10(abs(ho)):.4f} fixed {20*math.log10(abs(hf)):.4f} dB')
    print(f'bw={bw} nc={nc} firstNZ orig={fo} fixed={ff} peak={pk:.6g} maxdiff(n<nc)/peak={d_in/pk:.2e} '
          f'tail(n>=nc) orig={tail_o:.2e} fixed/peak={20*math.log10(tail_f/pk):.1f}dB theory exp(-a*nc)={20*math.log10(math.exp(-alpha*nc)):.1f}dB '
          f'errEnergy/E={10*math.log10(Ed/Ef):.1f}dB')
    print('   ', '; '.join(rows))
