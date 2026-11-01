#!/usr/bin/env python3
# table.py DIR...: per op, utf ÷ simdutf before (old) and after (new), new ÷ old,
# and the rows under simdutf outside the noise, from each level's ab.sh run.
# Each DIR holds summary.txt (new against old and simdutf), before-summary.txt
# (old against simdutf), and after-summary.txt (new against simdutf), all from
# bench/summary.awk.
import sys


def read(path):
    ops = {}
    for line in open(path):
        f = line.split()
        if not f or f[0].startswith("utf/arm"):
            continue
        ops[f[0]] = f
    return ops


levels = []
for d in sys.argv[1:]:
    vsold = read(f"{d}/summary.txt")
    before = read(f"{d}/before-summary.txt")
    after = read(f"{d}/after-summary.txt")
    levels.append((d.rstrip("/").split("/")[-1], before, after, vsold))

hdr = "| op | " + " | ".join(f"{n} before | after | ×old | <1 before→after" for n, _, _, _ in levels) + " |"
print(hdr)
print("|" + "---|" * (1 + 4 * len(levels)))
for op in levels[0][2]:
    cells = [op]
    for _, b, a, o in levels:
        # each: op, rows, GB/s, ×simdutf, ±, <1, ~ (all: no ±)
        i = 4 if op == "all" else 5
        cells += [b[op][3], a[op][3], o[op][3], f"{b[op][i]}→{a[op][i]}"]
    print("| " + " | ".join(cells) + " |")
