#!/usr/bin/env python3
"""sizes.py ROWS ARM: from an ab.sh rows.txt, the first arm against ARM:
geomean of the paired median ratios by input size and overall, and the rows
faster (>) and slower (<) beyond their 95% interval."""
import math
import re
import sys
from collections import defaultdict

path, arm = sys.argv[1], sys.argv[2]
by = defaultdict(list)
marks = defaultdict(lambda: defaultdict(int))
for line in open(path):
    p = line.split()
    if len(p) < 8 or p[1] != arm:
        continue
    row, ratio, mark = p[0], float(p[4]), p[7]
    m = re.search(r"-(\d+)$", row)
    size = m.group(1) if m else "text"
    for k in (size, "all"):
        by[k].append(math.log(ratio))
        marks[k][mark] += 1
order = sorted((k for k in by if k not in ("text", "all")), key=int) + [k for k in ("text", "all") if k in by]
print(f"{'size':>8s} {'rows':>5s} {'geomean':>8s} {'>':>4s} {'<':>4s} {'~':>4s}")
for k in order:
    v = by[k]
    print(f"{k:>8s} {len(v):5d} {math.exp(sum(v) / len(v)):8.3f} {marks[k]['>']:4d} {marks[k]['<']:4d} {marks[k]['~']:4d}")
