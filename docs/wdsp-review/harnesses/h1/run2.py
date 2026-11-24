import subprocess,sys
H=sys.argv[1]
def run(b,*a):
    return subprocess.run([f"{H}/drv_{b}",*map(str,a)],capture_output=True,text=True).stdout.strip()
for sc,snrs in ((0,(0,10,20)),(1,(-5,))):
  for snr in snrs:
    for m in (0,1,2,3):
      cf=[("orig",1,0,0,0),("fixed",1,2,0,0),("fixed",0,2,0,0)]
      if m==3: cf+= [("fixed",1,2,1,0),("fixed",1,2,1,1)]
      else: cf+= [("fixed",1,2,0,1)]
      for b,ae,cep,s3,xm in cf:
        print(f"sc={sc} snr={snr:>3} m={m} {b:5} ae={ae} cep={cep} soft3={s3} ximin={xm} :: {run(b,m,ae,cep,s3,xm,snr,sc)}",flush=True)
