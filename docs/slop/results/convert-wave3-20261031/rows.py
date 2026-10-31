#!/usr/bin/env python3
"""rows.py DIR [LIMIT]: rows of a bench-compare run where utf / simdutf (median GB/s) < LIMIT (1.0)."""
import sys, re, collections, statistics
def load(f):
    d = collections.defaultdict(list)
    for l in open(f):
        m = re.match(r'Benchmark(\S+)\s+\d+\s+([\d.]+) GB/s', l)
        if m: d[m.group(1)].append(float(m.group(2)))
    return {k: statistics.median(v) for k, v in d.items()}
d = sys.argv[1]; lim = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
u = load(d + '/utf.txt'); s = load(d + '/simdutf.txt')
rows = sorted((u[k] / s[k], k) for k in u if k in s)
bad = [r for r in rows if r[0] < lim]
for r, k in bad: print(f'{r:5.2f} {k:45s} {u[k]:8.2f} {s[k]:8.2f}')
print(f'{len(bad)} of {len(rows)} rows under {lim}')
