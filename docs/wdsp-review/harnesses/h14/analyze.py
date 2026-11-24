import csv,sys,os,glob
D=sys.argv[1]
def load(p):
    r=list(csv.DictReader(open(p)))
    return [(float(x['t']),float(x['dev']),float(x['var_ppm']),int(x['uf']),int(x['of'])) for x in r]
def s1(p,t0=300):
    d=load(p); ss=[x for x in d if x[0]>=t0]
    devs=[x[1] for x in ss]; vs=[x[2] for x in ss]
    rms=(sum(v*v for v in devs)/len(devs))**.5
    return dict(uf=sum(x[3] for x in d),of=sum(x[4] for x in d),uf_ss=sum(x[3] for x in ss),of_ss=sum(x[4] for x in ss),
        pk=max(abs(v) for v in devs),rms=rms,vmin=min(vs),vmax=max(vs),
        vrms=(sum(v*v for v in vs)/len(vs))**.5)
print("S1: +100ppm clock offset, 2ms jitter, 900s; steady-state window t>=300s. dev in samples (0.1s bins), var error in ppm vs true ratio")
print(f"{'build':6} {'B':>5} {'ring':>6} {'UF':>4} {'OF':>4} {'UFss':>4} {'OFss':>4} {'pk|dev|':>8} {'rmsdev':>8} {'var_err_min':>11} {'var_err_max':>11} {'var_rms':>8}")
for R in (16384,4096):
  for B in (64,128,256,512,1024):
    for v in ('orig','origT','fixed'):
        m=s1(f"{D}/s1_{v}_B{B}_R{R}.csv")
        print(f"{v:6} {B:5} {R:6} {m['uf']:4} {m['of']:4} {m['uf_ss']:4} {m['of_ss']:4} {m['pk']:8.0f} {m['rms']:8.1f} {m['vmin']:11.0f} {m['vmax']:11.0f} {m['vrms']:8.0f}")
print()
print("S2: 100ms input stall at t=400s (4800 samples lost), ring 16384")
print(f"{'build':6} {'B':>5} {'pre_mean':>8} {'min':>8} {'overshoot%':>10} {'settle10%_s':>11} {'UF':>3} {'OF':>3}")
for B in (64,128,256,512,1024):
  for v in ('orig','origT','fixed'):
    d=load(f"{D}/s2_{v}_B{B}.csv")
    pre=[x[1] for x in d if 380<=x[0]<400]; pm=sum(pre)/len(pre)
    post=[x for x in d if x[0]>=400]
    mn=min(x[1] for x in post); drop=pm-mn
    # overshoot: max excursion above pre-mean after the minimum
    imin=[i for i,x in enumerate(post) if x[1]==mn][0]
    ov=max(x[1] for x in post[imin:])-pm
    band=0.1*4800
    last_out=max([x[0] for x in post if abs(x[1]-pm)>band],default=400)
    print(f"{v:6} {B:5} {pm:8.0f} {mn:8.0f} {100*ov/4800:10.1f} {last_out-400:11.1f} {sum(x[3] for x in post):3} {sum(x[4] for x in post):3}")
