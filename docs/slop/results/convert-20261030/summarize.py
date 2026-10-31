#!/usr/bin/env python3
"""Median GB/s per op, corpus, size, and arm from the bench's Go-format lines,
as Markdown tables: one per op, rows corpus/size, columns arms."""
import re, sys, statistics, collections

pat = re.compile(r"^Benchmark(\w+)/corpus=(\w+)/size=(\d+)/arm=([\w+-]+) \d+ ([\d.]+) ns/op ([\d.]+) MB/s")
data = collections.defaultdict(list)
arms_by_op = collections.OrderedDict()
for line in open(sys.argv[1]):
    m = pat.match(line)
    if not m:
        continue
    op, corpus, size, arm, ns, mbs = m.groups()
    data[(op, corpus, int(size), arm)].append(float(mbs) / 1000)
    arms_by_op.setdefault(op, [])
    if arm not in arms_by_op[op]:
        arms_by_op[op].append(arm)

def fmt_size(n):
    return f"{n >> 20} MiB" if n >= 1 << 20 else f"{n >> 10} KiB" if n >= 1024 else f"{n} B"

for op, arms in arms_by_op.items():
    print(f"#### {op}\n")
    print("| corpus | size | " + " | ".join(arms) + " |")
    print("| --- | --: | " + " | ".join("--:" for _ in arms) + " |")
    keys = sorted({(c, s) for (o, c, s, a) in data if o == op}, key=lambda k: (["ascii", "latin", "cyrillic", "cjk", "emoji"].index(k[0]), k[1]))
    for c, s in keys:
        row = []
        for a in arms:
            v = data.get((op, c, s, a))
            row.append(f"{statistics.median(v):.2f}" if v else "")
        print(f"| {c} | {fmt_size(s)} | " + " | ".join(row) + " |")
    print()
