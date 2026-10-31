import sys, collections, statistics, math
name, arms = sys.argv[1], sys.argv[2:]
def med(arm):
    v = collections.defaultdict(list)
    for line in open(f"/home/user/ab/raw/{name}/{arm.replace(':','-')}.gbs"):
        n, _, g, _ = line.split()
        v[n.removeprefix("Benchmark")].append(float(g))
    return {k: statistics.median(x) for k, x in v.items()}
M = [med(a) for a in arms]
rows = [k for k in M[0] if all(k in m for m in M)]
ops = collections.defaultdict(list)
g = lambda xs: math.exp(sum(map(math.log, xs)) / len(xs))
filt = sys.argv[0]
for k in rows:
    vals = [m[k] for m in M]
    r = [v / vals[0] for v in vals[1:-1]] + [v / vals[-1] for v in vals[:-1]]
    ops[k.split('/')[0]].append(r)
    print(f"{k:40s} " + " ".join(f"{x:7.2f}" for x in vals) + "  /old " + " ".join(f"{x:5.2f}" for x in r[:len(arms)-2]) + "  /ref " + " ".join(f"{x:5.2f}" for x in r[len(arms)-2:]))
print()
for op, rs in list(ops.items()) + [("all", [r for rs in ops.values() for r in rs])]:
    n = len(rs[0])
    gm = [g([r[i] for r in rs]) for i in range(n)]
    mn = [min(r[i] for r in rs) for i in range(len(arms)-2, n)]
    print(f"{op:24s} /old " + " ".join(f"{x:5.3f}" for x in gm[:len(arms)-2]) + "  /ref " + " ".join(f"{x:5.3f}" for x in gm[len(arms)-2:]) + "  min/ref " + " ".join(f"{x:4.2f}" for x in mn))
