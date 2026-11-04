#!/usr/bin/env python3
"""summary.py for bench-utf rows (Benchmark<Op>/<text>-<size>): geomean of
per-row median ratios, by operation and by operation and size (corpus:
the whole file).
usage: gensummary.py DIR NUM/DEN ..."""
import sys, statistics, math, collections
d = sys.argv[1]
def load(arm):
    rows = collections.defaultdict(list)
    for line in open(f'{d}/{arm}.txt'):
        f = line.split('\t'); rows[f[0]].append(float(f[2].split()[0]))
    return rows
def gm(xs): return math.exp(sum(map(math.log, xs)) / len(xs))
for pair in sys.argv[2:]:
    a, b = pair.split('/')
    A, B = load(a), load(b)
    ratio = {r: statistics.median(y / x for x, y in zip(A[r], B[r])) for r in A if r in B}
    groups = collections.defaultdict(list)
    for r, v in ratio.items():
        op, shape = r[len('Benchmark'):].split('/')
        kind, _, size = shape.rpartition('-')
        size = int(size) if kind and size.isdigit() else -1
        groups[(op, 0)].append(v); groups[(op, size)].append(v); groups[('all', 0)].append(v)
    print(f'== {a} / {b}: ratio of times, {b} over {a} (above 1: {a} faster)')
    for k in sorted(groups):
        v = groups[k]; name = k[0] + {0: '', -1: ' corpus'}.get(k[1], f' size {k[1]}')
        print(f'  {name:<34} {gm(v):6.3f}  min {min(v):6.3f}  max {max(v):6.3f}  rows {len(v)}')
    lo = sorted(ratio.items(), key=lambda kv: kv[1])[:3]
    print('  lowest rows: ' + ', '.join(f'{r[len("Benchmark"):]} {v:.3f}' for r, v in lo))
