#!/usr/bin/env python3
# Median MB/s per row and arm from lay output on stdin; utf / simdutf (and /old if present).
import sys, re, collections, statistics
d = collections.defaultdict(list)
for l in sys.stdin:
    m = re.match(r'Benchmark(\S+)/arm=(\S+) \d+ ([\d.]+) ns/op ([\d.]+) MB/s', l)
    if m: d[(m.group(1), m.group(2))].append(float(m.group(4)))
rows = sorted({k[0] for k in d}, key=lambda s: d and s)
arms = sorted({k[1] for k in d})
print(f"{'row':55s}" + "".join(f"{a:>10s}" for a in arms) + "   utf/simdutf")
for r in dict.fromkeys(k[0] for k in d):
    v = {a: statistics.median(d[(r, a)]) / 1000 for a in arms if (r, a) in d}
    ours = [a for a in arms if a != 'simdutf']
    print(f"{r:55s}" + "".join(f"{v.get(a, 0):10.2f}" for a in arms) + "".join(f"   {a}/simdutf {v[a] / v['simdutf']:.2f}" for a in ours if a in v))
