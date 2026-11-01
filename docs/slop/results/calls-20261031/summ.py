#!/usr/bin/env python3
"""Summarize an ab.sh run: per row, each arm's median ns/op and the paired
ratio (speed, above 1 faster) of each arm against a base arm, median over
rounds with a 95% interval from order statistics, as bench/summary.awk.

  summ.py DIR BASE [ARM...]      (ARMs default to every other arm)
"""
import math, re, sys, os
from collections import defaultdict

d = sys.argv[1]
base = sys.argv[2]
arms = sys.argv[3:]
names = sorted(f[4:-4] for f in os.listdir(d) if f.startswith("raw-") and f.endswith(".txt"))
if not arms:
    arms = [a for a in names if a != base]
ns = defaultdict(lambda: defaultdict(list))
for a in names:
    for line in open(f"{d}/raw-{a}.txt"):
        m = re.match(r"Benchmark(\S+)\t\d+\t([\d.]+) ns/op", line)
        if m:
            ns[m.group(1)][a].append(float(m.group(2)))

def rank(m):
    p = 0.5 ** m; cum = p; c = 1
    while True:
        p = p * (m - c + 1) / c
        if cum + p > 0.025: return c
        cum += p; c += 1

def interval(xs):
    xs = sorted(xs); m = len(xs); c = rank(m)
    med = xs[(m - 1) // 2] if m % 2 else (xs[m // 2 - 1] + xs[m // 2]) / 2
    return med, xs[c - 1], xs[m - c]

def med(xs):
    return interval(xs)[0]

rows = list(ns.keys())
hdr = f"{'row':38s}" + "".join(f"{a:>9s}" for a in [base] + arms) + "".join(f"  {a + '/' + base:>22s}" for a in arms)
print("ns per call (median), and speed of each arm against " + base + " (paired median [95% interval])")
print(hdr)
geo = defaultdict(list)
opgeo = defaultdict(lambda: defaultdict(list))
for r in rows:
    if base not in ns[r]: continue
    line = f"{r:38s}" + "".join(f"{med(ns[r][a]):9.2f}" if a in ns[r] else f"{'-':>9s}" for a in [base] + arms)
    for a in arms:
        if a not in ns[r]:
            line += f"  {'-':>22s}"; continue
        ratios = [b / x for b, x in zip(ns[r][base], ns[r][a])]
        m, lo, hi = interval(ratios)
        mark = "~" if lo <= 1 <= hi else (">" if lo > 1 else "<")
        line += f"  {m:6.3f} [{lo:5.3f},{hi:5.3f}] {mark}"
        geo[a].append(math.log(m))
        opgeo[r.split('/')[0]][a].append(math.log(m))
    print(line)
print()
print("geomean speed against " + base + ":", " ".join(f"{a} {math.exp(sum(v)/len(v)):.3f} ({len(v)} rows)" for a, v in geo.items()))
if os.environ.get("PEROP"):
    print()
    print("per-operation geomean against " + base)
    for op, d in opgeo.items():
        print(f"{op:28s}" + "".join(f"  {a} {math.exp(sum(v)/len(v)):.3f}" for a, v in d.items()))
