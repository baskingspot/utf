import re, sys, math, collections
files=[('native','r/f-native.vs-simdutf.summ'),('baseline','r/f-baseline.vs-simdutf.summ'),('avx2','r/f-avx2.vs-simdutf.summ')]
g=lambda v: math.exp(sum(v)/len(v)) if v else float('nan')
data={}
ops=[]
for lvl,path in files:
    try: lines=open(path).read().splitlines()
    except FileNotFoundError: continue
    allr=collections.defaultdict(lambda: collections.defaultdict(list))
    sh=collections.defaultdict(lambda: collections.defaultdict(list))
    for line in lines:
        ms = re.findall(r'([\d.]+) \[([\d.]+),([\d.]+)\] (\S)', line)
        if len(ms) < 2: continue
        row=line.split()[0]; op=row.split('/')[0]
        if op not in ops: ops.append(op)
        for a,m in zip(['old','new'],ms):
            allr[op][a].append(math.log(float(m[0])))
            if re.search(r'-(16|64)$', row): sh[op][a].append(math.log(float(m[0])))
    data[lvl]=(allr,sh)
lv=[l for l,_ in files if l in data]
print(f"{'operation':24s}" + "".join(f"{l+' all':>14s}{l+' 16-64':>14s}" for l in lv))
tot=collections.defaultdict(list)
for op in ops:
    out=f"{op:24s}"
    for l in lv:
        allr,sh=data[l]
        for d,k in ((allr,'all'),(sh,'s')):
            o,n=g(d[op]['old']),g(d[op]['new'])
            out+=f"{o:7.2f}{n:7.2f}" if d[op]['old'] else f"{'-':>7s}{'-':>7s}"
            if d[op]['old']:
                tot[(l,k,'old')].append(math.log(o)); tot[(l,k,'new')].append(math.log(n))
    print(out)
out=f"{'geomean of operations':24s}"
for l in lv:
    for k in ('all','s'):
        out+=f"{g(tot[(l,k,'old')]):7.2f}{g(tot[(l,k,'new')]):7.2f}"
print(out)
