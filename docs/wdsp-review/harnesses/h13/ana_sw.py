import struct, math, sys
H=sys.argv[1]
def load(p):
    b=open(p,'rb').read(); v=struct.unpack('<%dd'%(len(b)//8),b)
    return [complex(v[2*i],v[2*i+1]) for i in range(len(v)//2)]
print('== noise (mode 2, gaussian, 262144 samples, size 64, 48k) ==')
for bw in (100,69,35):
    o=load(f'{H}/out/noise_orig_{bw}.bin'); f=load(f'{H}/out/noise_fixed_{bw}.bin')
    E=sum(abs(x)**2 for x in f[20000:]); D=sum(abs(o[i]-f[i])**2 for i in range(20000,len(f)))
    print(f'bw={bw}: (orig-fixed) error / output power = {10*math.log10(D/E):.1f} dB; max|diff|/rms = {max(abs(o[i]-f[i]) for i in range(20000,len(f)))/math.sqrt(E/(len(f)-20000)):.2e}')
print('== bandwidth change at block 200 (sample 12800), steady 600 Hz tone, mode 2 ==')
sw=12800
for tag,lab in (('s1','70->60 (nc 2048->4096, setNc)'),('s2','60->50 (nc unchanged, setImpulse)'),('s3','36->30 (nc 4096->8192, setNc)')):
    o=load(f'{H}/out/sw_orig_{tag}.bin'); f=load(f'{H}/out/sw_fixed_{tag}.bin')
    pre=sum(abs(f[i]) for i in range(sw-2000,sw))/2000
    post=sum(abs(f[i]) for i in range(len(f)-2000,len(f)))/2000
    post_o=sum(abs(o[i]) for i in range(len(o)-2000,len(o)))/2000
    pre_o=sum(abs(o[i]) for i in range(sw-2000,sw))/2000
    minA_o=min(abs(o[i]) for i in range(sw,sw+64)); minA_f=min(abs(f[i]) for i in range(sw,sw+64))
    jo=abs(o[sw]-o[sw-1]); jf=abs(f[sw]-f[sw-1])
    # samples until within 1% of final envelope
    def settle(x):
        for i in range(len(x)-1,sw-1,-1):
            if abs(abs(x[i])-post)/post>0.01: return i+1-sw
        return 0
    # deficit energy: integral of (post - |y|)^2 over transient relative to post^2 per sample
    dev_o=sum((abs(o[i])-post)**2 for i in range(sw,len(o)))/post**2
    dev_f=sum((abs(f[i])-post)**2 for i in range(sw,len(f)))/post**2
    print(f'{lab}: env pre orig={pre_o:.4f} fixed={pre:.4f}, post orig={post_o:.4f} fixed={post:.4f}')
    print(f'   first block after change: min|y| orig={minA_o:.4f} fixed={minA_f:.4f}; |y[sw]-y[sw-1]| orig={jo:.4f} fixed={jf:.4f}')
    print(f'   samples to settle within 1% of final env: orig={settle(o)} fixed={settle(f)}; envelope-deviation energy (sample-units) orig={dev_o:.1f} fixed={dev_f:.1f}')
