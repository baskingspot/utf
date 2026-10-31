import re,sys,statistics,collections,math
def load(f):
    d=collections.defaultdict(list)
    for l in open(f):
        if not l.startswith("Benchmark"): continue
        p=l.split(); n=re.sub(r"-\d+$","",p[0]).replace("BenchmarkValidate","")
        m=re.search(r"([\d.]+)\s*(MB|GB)/s",l)
        if m: d[n].append(float(m.group(1))/(1000 if m.group(2)=="MB" else 1))
    return {k:statistics.median(v) for k,v in d.items()}
o,n,s=[load(f) for f in sys.argv[1:4]]
maxsz=int(sys.argv[4]) if len(sys.argv)>4 else 1<<30
ops=collections.defaultdict(lambda:[[],[],[]])
for k in o:
    sz=int(k.rsplit("=",1)[1]); op=k.split("/")[0]
    ops[op][0].append(n[k]/o[k]); ops[op][1].append(o[k]/s[k]); ops[op][2].append(n[k]/s[k])
    if sz<=maxsz and (n[k]/o[k]<0.97 or n[k]/s[k]<1.0 or n[k]/o[k]>1.05):
        print(f"{k:45s} old {o[k]:7.2f} new {n[k]:7.2f} simd {s[k]:7.2f}  new/old {n[k]/o[k]:.2f}  old/simd {o[k]/s[k]:.2f} new/simd {n[k]/s[k]:.2f}")
g=lambda v: math.exp(sum(map(math.log,v))/len(v))
for op,(a,b,c) in ops.items(): print(f"{op:24s} new/old {g(a):.3f}  old/simd {g(b):.3f}  new/simd {g(c):.3f}")
