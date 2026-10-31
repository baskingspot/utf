#!/usr/bin/env python3
"""cmp.py NAME OLD NEW [REF]: median GB/s per row for each arm of raw/NAME,
new/old and new/ref, and geomeans per op."""
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
for k in rows:
    vals = [m[k] for m in M]
    r1 = vals[1] / vals[0]
    r2 = vals[1] / vals[2] if len(vals) > 2 else float('nan')
    ops[k.split('/')[0]].append((r1, r2))
    print(f"{k:42s} " + " ".join(f"{x:8.2f}" for x in vals) + f"  new/old {r1:5.2f}  new/ref {r2:5.2f}")
g = lambda xs: math.exp(sum(map(math.log, xs)) / len(xs))
print()
for op, rs in ops.items():
    print(f"{op:28s} new/old {g([r[0] for r in rs]):5.3f}  new/ref {g([r[1] for r in rs]):5.3f}  min new/ref {min(r[1] for r in rs):5.2f}")
allr = [r for rs in ops.values() for r in rs]
print(f"{'all':28s} new/old {g([r[0] for r in allr]):5.3f}  new/ref {g([r[1] for r in allr]):5.3f}")
