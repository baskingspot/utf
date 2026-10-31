#!/usr/bin/env python3
"""opgeo.py BEFORE_DIR AFTER_DIR: per-op geomean of utf/simdutf (median GB/s per row) before and after, and rows under 1.0 after."""
import sys, re, collections, statistics, math
def load(f):
    d = collections.defaultdict(list)
    for l in open(f):
        m = re.match(r'Benchmark(\S+)\s+\d+\s+([\d.]+) GB/s', l)
        if m: d[m.group(1)].append(float(m.group(2)))
    return {k: statistics.median(v) for k, v in d.items()}
def ratios(d):
    u = load(d + '/utf.txt'); s = load(d + '/simdutf.txt')
    return {k: u[k] / s[k] for k in u if k in s}
b, a = ratios(sys.argv[1]), ratios(sys.argv[2])
g = lambda xs: math.exp(sum(map(math.log, xs)) / len(xs))
ops = list(dict.fromkeys(k.split('/')[0] for k in a))
print(f"| op | before | after | min after |\n| --- | ---: | ---: | ---: |")
for op in ops:
    ks = [k for k in a if k.split('/')[0] == op and k in b]
    print(f"| {op} | {g([b[k] for k in ks]):.2f} | {g([a[k] for k in ks]):.2f} | {min(a[k] for k in ks):.2f} |")
ks = [k for k in a if k in b]
print(f"| all ({len(ks)} rows) | {g([b[k] for k in ks]):.2f} | {g([a[k] for k in ks]):.2f} | {min(a[k] for k in ks):.2f} |")
lim = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
print(f"\nrows under {lim}: before {sum(b[k] < lim for k in ks)}, after {sum(a[k] < lim for k in ks)} of {len(ks)}")
