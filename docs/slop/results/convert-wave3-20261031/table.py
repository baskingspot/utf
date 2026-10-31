#!/usr/bin/env python3
"""table.py BEFORE AFTER: per-op geomean utf/simdutf at each ISA, before and after, one markdown table."""
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
g = lambda xs: math.exp(sum(map(math.log, xs)) / len(xs))
isas = ['native', 'avx2', 'sse']
R = {i: (ratios(f'{sys.argv[1]}/{i}'), ratios(f'{sys.argv[2]}/{i}')) for i in isas}
ops = list(dict.fromkeys(k.split('/')[0] for k in R['native'][1]))
print('| op | icelake before | after | haswell before | after | westmere before | after |')
print('| --- | ---: | ---: | ---: | ---: | ---: | ---: |')
for op in ops + ['all']:
    cells = []
    for i in isas:
        b, a = R[i]
        ks = [k for k in a if k in b and (op == 'all' or k.split('/')[0] == op)]
        cells += [f'{g([b[k] for k in ks]):.2f}', f'{g([a[k] for k in ks]):.2f}']
    print(f'| {op} | ' + ' | '.join(cells) + ' |')
