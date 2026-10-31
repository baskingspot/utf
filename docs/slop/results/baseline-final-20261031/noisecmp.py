#!/usr/bin/env python3
"""Run-to-run spread of the old and new harness on the same operations.

Each harness ran N separate invocations (old-1..N, new-1..N), each its own
set of processes. For every row, each invocation gives utf's ratio to every
other arm the way that harness's summary computes it: the old one as the
ratio of the medians over the rounds, the new one as the median of the
per-round ratios. The spread of a row is (max - min) / median of its ratio
over the invocations; the same for each arm's own median GB/s, and for each
operation's geomean ratio.

    noisecmp.py DIR   (DIR holds old-*/ and new-*/ with <arm>.txt files)
"""
import math
import statistics as st
import sys
from collections import defaultdict
from pathlib import Path

ARMS = ["simdutf", "std", "rust", "go"]


def read(path):
    rows = defaultdict(list)
    if path.exists():
        for line in path.read_text().splitlines():
            if line.startswith("Benchmark"):
                f = line.split("\t")
                rows[f[0][len("Benchmark"):]].append(float(f[2].split()[0]))
    return rows


def ratios(d, paired):
    utf = read(d / "utf.txt")
    out = {}
    for arm in ARMS:
        other = read(d / f"{arm}.txt")
        for row, u in utf.items():
            if row not in other:
                continue
            o = other[row]
            if paired:
                m = min(len(u), len(o))
                out[arm, row] = st.median(u[i] / o[i] for i in range(m))
            else:
                out[arm, row] = st.median(u) / st.median(o)
    return out


def gbs(d):
    out = {}
    for arm in ["utf"] + ARMS:
        for row, v in read(d / f"{arm}.txt").items():
            out[arm, row] = st.median(v)
    return out


def spread(xs):
    return (max(xs) - min(xs)) / st.median(xs)


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(p * len(xs)))]


def summarize(name, runs, paired):
    rs = [ratios(d, paired) for d in runs]
    gs = [gbs(d) for d in runs]
    print(f"== {name}: {len(runs)} invocations ({', '.join(d.name for d in runs)})")
    for arm in ARMS:
        keys = [k for k in rs[0] if k[0] == arm and all(k in r for r in rs)]
        if not keys:
            continue
        s = [spread([r[k] for r in rs]) for k in keys]
        print(f"  utf/{arm:8s} row ratio spread over {len(keys):3d} rows: median {100*st.median(s):5.1f}%  p90 {100*pct(s,.9):5.1f}%  max {100*max(s):5.1f}%")
        # per-op geomean
        ops = defaultdict(list)
        for k in keys:
            ops[k[1].split("/")[0]].append(k)
        os_ = []
        for op, ks in ops.items():
            gm = [math.exp(sum(math.log(r[k]) for k in ks) / len(ks)) for r in rs]
            os_.append((spread(gm), op, gm))
        if arm == "simdutf":
            for sp, op, gm in sorted(os_, key=lambda x: x[1]):
                print(f"      {op:24s} geomean {' '.join(f'{g:.3f}' for g in gm)}  spread {100*sp:4.1f}%")
        print(f"      op geomean spread: median {100*st.median([x[0] for x in os_]):4.1f}%  max {100*max(x[0] for x in os_):4.1f}%")
    for arm in ["utf"] + ARMS:
        keys = [k for k in gs[0] if k[0] == arm and all(k in g for g in gs)]
        s = [spread([g[k] for g in gs]) for k in keys]
        print(f"  {arm:8s} GB/s spread over {len(keys):3d} rows: median {100*st.median(s):5.1f}%  p90 {100*pct(s,.9):5.1f}%  max {100*max(s):5.1f}%")


def main():
    root = Path(sys.argv[1])
    old = sorted(root.glob("old-*[0-9]"))
    new = sorted(root.glob("new-*[0-9]"))
    if old:
        summarize("old harness", old, paired=False)
    if new:
        summarize("new harness", new, paired=True)
        summarize("new harness, unpaired estimator", new, paired=False)


main()
