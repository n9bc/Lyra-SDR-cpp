import subprocess,sys
H=sys.argv[1]
rows=[]
def run(b,m,ae,cep,s3,xm,snr,sc):
    r=subprocess.run([f"{H}/drv_{b}",*map(str,[m,ae,cep,s3,xm,snr,sc])],capture_output=True,text=True)
    return r.stdout.strip()
for sc in (0,1):
  for snr in ((0,10,20) if sc==0 else (-5,)):
    for m in (0,1,2,3):
      cfgs=[("orig",1,0,0,0),("fixed",1,1,0,0),("fixed",0,1,0,0),("fixed",1,0,0,1)]
      if m==3: cfgs.append(("fixed",1,0,1,0))
      cfgs.append(("fixed",1,1,1 if m==3 else 0,1))
      for b,ae,cep,s3,xm in cfgs:
        print(f"sc={sc} snr={snr:>3} m={m} {b:5} ae={ae} cep={cep} soft3={s3} ximin={xm} :: {run(b,m,ae,cep,s3,xm,snr,sc)}",flush=True)
