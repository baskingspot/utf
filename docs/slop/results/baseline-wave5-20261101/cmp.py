#!/usr/bin/env python3
"""cmp.py OLD NEW LEVEL...: tables comparing two baselines, each a directory
with one `just bench-compare` output per level (summary.txt, rows.txt,
rss.txt). Prints Markdown: the overall table, utf ÷ simdutf per operation
at every level (old → new), the operations under simdutf, and peak RSS."""
import sys
from pathlib import Path

old_root, new_root, levels = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3:]


def summary(d):
    lines = (d / "summary.txt").read_text().splitlines()
    head = lines[0].split()
    arms = head[head.index("GB/s") + 1: head.index("±")]
    out = {}
    for line in lines[1:]:
        f = line.split()
        if not f:
            continue
        rec = {"rows": int(f[1]), "gbs": float(f[2])}
        for i, a in enumerate(arms):
            rec[a] = None if f[3 + i] == "-" else float(f[3 + i])
        rest = f[3 + len(arms):]
        if f[0] == "all":
            rec["under"], rec["level"] = int(rest[0]), int(rest[1])
        else:
            rec["spread"], rec["under"], rec["level"] = rest[0], int(rest[1]), int(rest[2])
            rec["slowest"] = " ".join(rest[3:])
        out[f[0]] = rec
    return out


def rss(d):
    lines = (d / "rss.txt").read_text().splitlines()
    arms = lines[0].split()[3:]
    out = {}
    for line in lines[1:]:
        f = line.split()
        out[f[0]] = {a: (None if v == "-" else float(v)) for a, v in zip(arms, f[1:])}
    return arms, out


S = {lv: (summary(old_root / lv), summary(new_root / lv)) for lv in levels}
fmt = lambda x: "-" if x is None else f"{x:.2f}"

print("## Overall\n")
print("| level | simdutf | std | Rust | Go | rows under simdutf | cannot call |")
print("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
for lv in levels:
    o, n = S[lv][0]["all"], S[lv][1]["all"]
    cells = [f"{fmt(o[a])} → {fmt(n[a])}" for a in ("simdutf", "std", "rust", "go")]
    print(f"| {lv} | " + " | ".join(cells) + f" | {o['under']} → {n['under']} | {o['level']} → {n['level']} |")
print()

print("## Per operation, utf ÷ simdutf\n")
print("| op | " + " | ".join(levels) + " |")
print("| --- | " + " | ".join("---:" for _ in levels) + " |")
ops = list(S[levels[0]][1].keys())
for op in ops:
    cells = []
    for lv in levels:
        o, n = S[lv][0].get(op), S[lv][1].get(op)
        c = f"{fmt(o and o['simdutf'])} → {fmt(n and n['simdutf'])}"
        if n and op != "all" and n["under"]:
            c += f" ({n['under']}<)"
        cells.append(c)
    print(f"| {op} | " + " | ".join(cells) + " |")
print()

print("## Under simdutf\n")
for lv in levels:
    under = [(op, r) for op, r in S[lv][1].items() if op != "all" and r["simdutf"] is not None and r["simdutf"] < 1.0]
    print(f"### {lv}: {len(under)}\n")
    for op, r in sorted(under, key=lambda x: x[1]["simdutf"]):
        o = S[lv][0].get(op)
        print(f"- {op} {r['simdutf']:.2f} (was {fmt(o and o['simdutf'])}), {r['under']} rows under, slowest {r['slowest']}")
    print()

print("## Peak RSS, arm − utf, MiB\n")
print("| level | simdutf | std | Rust | Go | utf new − old |")
print("| --- | ---: | ---: | ---: | ---: | ---: |")
for lv in levels:
    arms, r = rss(new_root / lv)
    _, ro = rss(old_root / lv)
    cells = []
    for a in ("simdutf", "std", "rust", "go"):
        d = [rec[a] - rec["utf"] for rec in r.values() if rec.get(a) is not None and rec.get("utf") is not None]
        cells.append(f"{min(d):+.1f} to {max(d):+.1f}" if d else "-")
    du = [r[op]["utf"] - ro[op]["utf"] for op in r if op in ro and r[op].get("utf") is not None and ro[op].get("utf") is not None]
    cells.append(f"{min(du):+.1f} to {max(du):+.1f}")
    print(f"| {lv} | " + " | ".join(cells) + " |")
