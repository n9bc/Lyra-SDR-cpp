import math,sys
sys.path.insert(0,'')
exec(open('/private/tmp/claude-501/-Users-bcrier-Documents-dev-Lyra/e6b3d9d4-b1eb-4e1d-a483-8447cc1f5f19/scratchpad/verify2/f8.py').read().split('for fs in (384000,192000):')[0])
def sim(fs,f,size=1024,nblk=40,stride_fix=False):
    secs=code_bqs(fs,58000,75000); st=[[0,0,0,0] for _ in secs]
    n=0; acc=0; cnt=0
    for blk in range(nblk):
        disc=[0.0]*(2*size)
        for i in range(size):
            disc[2*i]=math.cos(2*math.pi*f*(n+i)/fs)
        n+=size
        buf=disc[0:2*size:2] if stride_fix else disc[:size]
        for (b,a),s in zip(secs,st):
            out=[]
            for x in buf:
                y=b[0]*x+b[1]*s[0]+b[2]*s[1]-a[1]*s[2]-a[2]*s[3]
                s[1]=s[0];s[0]=x;s[3]=s[2];s[2]=y;out.append(y)
            buf=out
        if blk>=10:
            acc+=sum(y*y for y in buf);cnt+=len(buf)
    return 10*math.log10(acc/cnt/0.5+1e-30)
for fs in (384000,192000):
    print(fs,"actual code path:"," ".join("%dk:%.1f"%(f/1000,sim(fs,f)) for f in (19000,38000,50000,57000,67000,92000,120000,132000,140000) if f<fs/2))
    print(fs,"stride-fixed    :"," ".join("%dk:%.1f"%(f/1000,sim(fs,f,stride_fix=True)) for f in (19000,38000,50000,57000,67000,92000) if f<fs/2))
