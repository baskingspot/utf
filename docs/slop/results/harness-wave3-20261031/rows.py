#!/usr/bin/env python3
# Per-row median ns per call, old against new, from ab.sh's GB/s files
# (old-LABEL.txt, new-LABEL.txt). ns per call is the input size over the
# throughput, since testingx rounds its ns/op column to whole nanoseconds.
# Run from the repository root, with the corpus generated:
#   rows.py docs/slop/results/harness-wave3-20261031 utf-native > rows-native.txt
import os, statistics, sys
from collections import defaultdict

res, label = sys.argv[1], sys.argv[2]
dirs = {}
for line in open("bench/ops.tsv"):
    if not line.startswith("#"):
        f = line.rstrip("\n").split("\t")
        dirs[f[1]] = f[2]

def load(v):
    rows, order = defaultdict(list), []
    for line in open(os.path.join(res, f"{v}-{label}.txt")):
        name, _, gbs, _ = line.split()
        name = name[len("Benchmark"):]
        row, inp = name.split("/", 1)
        size = os.path.getsize(f"bench/corpus-gen/{dirs[row]}/{inp}")
        if name not in rows:
            order.append((name, size))
        rows[name].append(size / float(gbs))
    return rows, order

old, order = load("old")
new, _ = load("new")
print(f"{'row':44} {'bytes':>7} {'old ns':>8} {'new ns':>8} {'delta':>7} {'new/old':>7}  n")
for name, size in order:
    o, n = statistics.median(old[name]), statistics.median(new[name])
    print(f"{name:44} {size:7d} {o:8.2f} {n:8.2f} {n - o:+7.2f} {n / o:7.2f}  {len(old[name])}+{len(new[name])}")
