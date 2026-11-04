#!/usr/bin/env python3
"""Paired ratios from serve-ab.py output: for each pair NUM/DEN, each row's
median over rounds of DEN's ns/op over NUM's (above 1: NUM is faster), then
the geometric mean by operation, by operation and text, and by operation
and size. usage: summary.py DIR NUM/DEN ..."""
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
        op, enc, shape = r[len('Benchmark'):].split('/')
        kind, size = shape.rsplit('-', 1)
        groups[(op,)].append(v)
        groups[(op, f'{enc}/{kind}')].append(v)
        groups[(op, 'size ' + size)].append(v)
    print(f'== {a} / {b}: ratio of times, {b} over {a} (above 1: {a} faster)')
    for k in sorted(groups, key=lambda k: (k[0], len(k), k[1:] and (k[1].startswith('size'), int(k[1].split()[1]) if k[1].startswith('size') else 0, k[1]))):
        v = groups[k]
        print(f'  {" ".join(k):<34} {gm(v):6.3f}  min {min(v):6.3f}  max {max(v):6.3f}  rows {len(v)}')
