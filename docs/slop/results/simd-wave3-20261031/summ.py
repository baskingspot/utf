#!/usr/bin/env python3
# summ.py DIR A B: per-module geomean of median GB/s B/A, and benchstat rows
# that moved significantly by more than 5%.
import re, sys, math, statistics, collections
d, a, b = sys.argv[1:4]
def med(arm):
    v = collections.defaultdict(list)
    for line in open(f"{d}/{arm}.gbs"):
        name, _, gbs, _ = line.split()
        v[name.removeprefix("Benchmark")].append(float(gbs))
    return {k: statistics.median(x) for k, x in v.items()}
A, B = med(a), med(b)
def module(row):
    op = row.split("/")[0]
    if op.startswith("Validate"): return "validate"
    if op.startswith("Base64"): return "base64"
    if op.startswith(("Count", "Utf8From", "Utf16From")): return "length"
    return "convert"
g = collections.defaultdict(list)
for k in A:
    if k in B: g[module(k)].append(math.log(B[k] / A[k]))
allr = [x for v in g.values() for x in v]
for m, v in sorted(g.items()):
    print(f"{m:9s} rows={len(v):4d} geomean={100*(math.exp(sum(v)/len(v))-1):+.2f}%")
print(f"{'all':9s} rows={len(allr):4d} geomean={100*(math.exp(sum(allr)/len(allr))-1):+.2f}%")
sig = re.compile(r"^(\S+)\s.*\s([+-]\d+\.\d+)% \(p=(\d\.\d+)")
moved = collections.defaultdict(list)
for line in open(f"{d}/benchstat.txt"):
    m = sig.match(line)
    if m and abs(float(m.group(2))) >= 5:
        moved[module(m.group(1))].append((float(m.group(2)), m.group(1), A.get(m.group(1)), B.get(m.group(1))))
for mod, rows in sorted(moved.items()):
    print(f"-- {mod}: {sum(r[0] > 0 for r in rows)} up, {sum(r[0] < 0 for r in rows)} down (>=5%, p<0.05)")
    for r in sorted(rows):
        print(f"   {r[0]:+7.2f}%  {r[1]:40s} {r[2]:8.3f} -> {r[3]:8.3f} GB/s")
