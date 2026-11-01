import collections, sys
rows=collections.defaultdict(dict)
for l in open(sys.argv[1]):
    f=l.split()
    rows[f[0]][f[1]]=(f[4],f[-1])
pat=sys.argv[2:] 
for r,d in rows.items():
    if not pat or any(p in r for p in pat):
        print(f"{r:40s}", '  '.join(f"{k}:{v[0]}{v[1]}" for k,v in d.items()))
