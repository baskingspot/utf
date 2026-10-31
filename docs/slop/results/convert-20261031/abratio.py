#!/usr/bin/env python3
"""Ratios from the interleaved A/B driver's output: median ns/op per row and
arm, then num ÷ den throughput (den's ns over num's ns), geomean over sizes,
as a Markdown table of ops by corpus, plus a geomean per size.

usage: abratio.py raw.txt num den [num_valid den_valid]"""
import re, sys, collections, statistics, math

pat = re.compile(r"^Benchmark(\w+)/corpus=(\w+)/size=(\d+)/arm=([\w-]+) \d+ ([\d.]+) ns/op")
ns = collections.defaultdict(list)
for line in open(sys.argv[1]):
    m = pat.match(line)
    if m:
        op, c, s, a, t = m.groups()
        ns[(op, c, int(s), a)].append(float(t))
med = {k: statistics.median(v) for k, v in ns.items()}
pairs = [(sys.argv[2], sys.argv[3], '')]
if len(sys.argv) > 5:
    pairs.append((sys.argv[4], sys.argv[5], ' (valid)'))
order = ['ascii', 'latin', 'latin1t', 'cyrillic', 'hindi', 'cjk', 'korean', 'emoji']
gm = lambda v: math.exp(sum(map(math.log, v)) / len(v))
ops = []
for (op, c, s, a) in med:
    if op not in ops:
        ops.append(op)
print('| op | ' + ' | '.join(order) + ' |')
print('| --- | ' + ' | '.join('--:' for _ in order) + ' |')
bysize = collections.defaultdict(list)
allr = []
for op in ops:
    for num, den, tag in pairs:
        cells, any_ = [], False
        for c in order:
            rs = []
            for (o, cc, s, a), t in med.items():
                if o == op and cc == c and a == num and (o, cc, s, den) in med:
                    r = med[(o, cc, s, den)] / t
                    rs.append(r)
                    bysize[s].append(r)
                    allr.append(r)
            cells.append(f'{gm(rs):.2f}' if rs else '')
            any_ |= bool(rs)
        if any_:
            print(f'| {op}{tag} | ' + ' | '.join(cells) + ' |')
print()
print('| size | ' + ' | '.join(str(s) for s in sorted(bysize)) + ' | all |')
print('| --- | ' + ' | '.join('--:' for _ in bysize) + ' | --: |')
print('| geomean | ' + ' | '.join(f'{gm(bysize[s]):.2f}' for s in sorted(bysize)) + f' | {gm(allr):.2f} |')
print('| min | ' + ' | '.join(f'{min(bysize[s]):.2f}' for s in sorted(bysize)) + f' | {min(allr):.2f} |')
