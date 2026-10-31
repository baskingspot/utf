#!/usr/bin/env python3
"""cmp.py a.txt b.txt ... [--filter S]: median GB/s per row per file, and
each file's ratio to the first."""
import re, sys, statistics, collections

args = [a for a in sys.argv[1:] if not a.startswith("--")]
filt = next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--filter=")), "")
data = []
order = []
for f in args:
    d = collections.defaultdict(list)
    for line in open(f):
        if not line.startswith("Benchmark"):
            continue
        parts = line.split()
        name = re.sub(r"-\d+$", "", parts[0])
        m = re.search(r"([\d.]+)\s*(MB|GB)/s", line)
        if not m:
            continue
        d[name].append(float(m.group(1)) / (1000 if m.group(2) == "MB" else 1))
        if not data and name not in order:
            order.append(name)
    data.append(d)
w = max(len(n) for n in order)
print(" " * w, *[f"{a.split('/')[-1][:14]:>14}" for a in args])
for n in order:
    if filt and not re.search(filt, n):
        continue
    vals = [statistics.median(d[n]) if d.get(n) else None for d in data]
    cells = []
    for i, v in enumerate(vals):
        if v is None:
            cells.append(f"{'-':>14}")
        elif i == 0 or not vals[0]:
            cells.append(f"{v:14.2f}")
        else:
            cells.append(f"{v:8.2f} {v / vals[0]:4.2f}x")
    print(f"{n:<{w}}", *cells)
