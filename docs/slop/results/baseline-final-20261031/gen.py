#!/usr/bin/env python3
"""Tables for the baseline write-up, from `just bench-compare` output dirs.

    gen.py LEVEL=DIR ...

Each DIR holds summary.txt, rows.txt, and rss.txt as `just bench-compare`
writes them. Prints Markdown: the per-op geomean against simdutf at every
level, one table per level against every arm, the rows under 1.0 outside
the noise per level, and peak RSS.
"""
import sys
from collections import defaultdict
from pathlib import Path


def summary(d):
    """op -> dict of columns, in file order."""
    lines = (d / "summary.txt").read_text().splitlines()
    head = lines[0].split()
    # "utf/arm, geomean rows utf GB/s simdutf std rust go ± <1 ~ slowest vs simdutf"
    arms = head[head.index("GB/s") + 1: head.index("±")]
    out = {}
    for line in lines[1:]:
        f = line.split()
        if not f:
            continue
        op = f[0]
        rec = {"rows": int(f[1]), "gbs": float(f[2])}
        for i, a in enumerate(arms):
            rec[a] = f[3 + i]
        rest = f[3 + len(arms):]
        if op != "all":
            rec["spread"], rec["under"], rec["level"] = rest[0], int(rest[1]), int(rest[2])
            rec["slowest"] = " ".join(rest[3:])
        else:
            rec["under"], rec["level"] = int(rest[0]), int(rest[1])
        out[op] = rec
    return arms, out


def rows(d):
    out = []
    for line in (d / "rows.txt").read_text().splitlines():
        f = line.split()
        out.append(dict(row=f[0], arm=f[1], utf=float(f[2]), other=float(f[3]), mid=float(f[4]), lo=float(f[5]), hi=float(f[6]), v=f[7]))
    return out


def rss(d):
    lines = (d / "rss.txt").read_text().splitlines()
    arms = lines[0].split()[3:]
    out = {}
    for line in lines[1:]:
        f = line.split()
        out[f[0]] = dict(zip(arms, f[1:]))
    return arms, out


def main():
    levels = [a.split("=", 1) for a in sys.argv[1:]]
    data = {name: (summary(Path(d)), rows(Path(d)), rss(Path(d))) for name, d in levels}
    names = [n for n, _ in levels]
    ops = list(data[names[0]][0][1].keys())

    print("## Per operation against simdutf\n")
    print("| op | " + " | ".join(names) + " |")
    print("| --- | " + " | ".join("---:" for _ in names) + " |")
    for op in ops:
        cells = []
        for n in names:
            rec = data[n][0][1].get(op)
            if rec is None:
                cells.append("-")
                continue
            c = rec["simdutf"]
            if op != "all" and rec["under"]:
                c += f" ({rec['under']}<)"
            cells.append(c)
        print(f"| {op} | " + " | ".join(cells) + " |")
    print()

    print("## Per level\n")
    for n in names:
        arms, s = data[n][0]
        print(f"### {n}\n")
        print("| op | rows | utf GB/s | " + " | ".join(arms) + " | ± | <1 | ~ | slowest vs simdutf |")
        print("| --- | ---: | ---: | " + " | ".join("---:" for _ in arms) + " | ---: | ---: | ---: | --- |")
        for op, rec in s.items():
            if op == "all":
                print(f"| **all** | {rec['rows']} | {rec['gbs']:.2f} | " + " | ".join(f"**{rec[a]}**" for a in arms) + f" | | {rec['under']} | {rec['level']} | |")
            else:
                print(f"| {op} | {rec['rows']} | {rec['gbs']:.2f} | " + " | ".join(rec[a] for a in arms) + f" | {rec['spread']} | {rec['under']} | {rec['level']} | {rec['slowest']} |")
        print()

    print("## Rows under 1.0 outside the noise\n")
    for n in names:
        rs = [r for r in data[n][1] if r["v"] == "<"]
        by = defaultdict(list)
        for r in rs:
            op, inp = r["row"].split("/", 1)
            by[r["arm"], op].append(f"{inp} {r['mid']:.2f}")
        counts = defaultdict(int)
        for r in rs:
            counts[r["arm"]] += 1
        print(f"#### {n}: " + ", ".join(f"{c} vs {a}" for a, c in counts.items()) + "\n")
        print("```")
        for (a, op), v in by.items():
            print(f"{a:8s} {op:22s} " + ", ".join(v))
        print("```\n")

    print("## Peak RSS\n")
    for n in names:
        arms, r = data[n][2]
        print(f"### {n}\n")
        print("| op | " + " | ".join(arms) + " |")
        print("| --- | " + " | ".join("---:" for _ in arms) + " |")
        for op, rec in r.items():
            print(f"| {op} | " + " | ".join(rec.get(a, "-") for a in arms) + " |")
        print()


main()
