#!/usr/bin/env python3
"""utf ÷ simdutf per operation and corpus from a bench-compare directory:
median GB/s per row, sized corpora (ascii-N, latin1-N) as a geomean over sizes.
Prints a Markdown table, ops as rows, corpora as columns."""
import sys, re, collections, statistics, math

def load(f):
    d = collections.defaultdict(list)
    for l in open(f):
        m = re.match(r'Benchmark(\S+)\s+\d+\s+([\d.]+) GB/s', l)
        if m:
            d[m.group(1)].append(float(m.group(2)))
    return {k: statistics.median(v) for k, v in d.items()}

dir = sys.argv[1]
u = load(dir + '/utf.txt')
s = load(dir + '/simdutf.txt')
ratios = collections.defaultdict(lambda: collections.defaultdict(list))
ops = []
for k in u:
    if k not in s:
        continue
    op, row = k.split('/', 1)
    corpus = row.split('-')[0]
    if op not in ops:
        ops.append(op)
    ratios[op][corpus].append(u[k] / s[k])
order = ['ascii', 'latin1', 'latin', 'russian', 'hebrew', 'arabic', 'hindi', 'chinese', 'japanese', 'korean', 'emoji']
cols = [c for c in order if any(c in ratios[o] for o in ops)]
cols += sorted({c for o in ops for c in ratios[o]} - set(cols))
print('| op | ' + ' | '.join(cols) + ' |')
print('| --- | ' + ' | '.join('--:' for _ in cols) + ' |')
for o in ops:
    cells = []
    for c in cols:
        v = ratios[o].get(c)
        cells.append(f'{math.exp(sum(map(math.log, v)) / len(v)):.2f}' if v else '')
    print(f'| {o} | ' + ' | '.join(cells) + ' |')
