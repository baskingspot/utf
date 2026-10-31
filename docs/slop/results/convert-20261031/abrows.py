import re,collections,statistics,sys
pat=re.compile(r"^Benchmark(\w+)/corpus=(\w+)/size=(\d+)/arm=([\w-]+) \d+ ([\d.]+) ns/op")
ns=collections.defaultdict(list)
for l in open(sys.argv[1]):
    m=pat.match(l)
    if m: ns[m.groups()[:4]].append(float(m.group(5)))
med={k:statistics.median(v) for k,v in ns.items()}
filt=sys.argv[2] if len(sys.argv)>2 else ''
lo=float(sys.argv[3]) if len(sys.argv)>3 else 0; hi=float(sys.argv[4]) if len(sys.argv)>4 else 99
for (op,c,s,a),t in sorted(med.items()):
    for num,den in (('new','old'),('new-valid','old-valid'),('new','simdutf'),('new-valid','simdutf-valid')):
        if a==num and (op,c,s,den) in med and filt in f"{op}/{c}/{s}":
            r=med[(op,c,s,den)]/t
            if lo<=r<=hi: print(f"{op:16s} {c:9s} {s:6s} {num:9s}/{den:13s}: {r:.2f}  ({t:.1f} vs {med[(op,c,s,den)]:.1f} ns)")
