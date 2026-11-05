# Per row: each arm's median GB/s over the rounds, and the median of the
# per-round paired ratios replacing/simdutf and replacing/loop (time of the
# other arm over replacing's, so above 1 means replacing is faster), with
# their min and max. `python3 summary.py run.txt [markdown]`.
import collections
import re
import statistics
import sys

ns = collections.defaultdict(lambda: collections.defaultdict(list))
gbs = collections.defaultdict(lambda: collections.defaultdict(list))
order = []
for line in open(sys.argv[1]):
    m = re.match(r"BenchmarkReplacing/(\S+)/arm=(\S+)\s+\d+\s+([\d.]+) ns/op\s+([\d.]+) MB/s", line)
    if not m:
        continue
    row, arm = m.group(1), m.group(2)
    if row not in ns:
        order.append(row)
    ns[row][arm].append(float(m.group(3)))
    gbs[row][arm].append(float(m.group(4)) / 1000)

md = len(sys.argv) > 2
head = ["row", "simdutf GB/s", "loop GB/s", "replacing GB/s", "vs simdutf", "vs loop"]
if md:
    print("| " + " | ".join(head) + " |")
    print("|" + "---|" * len(head))
else:
    print(f"{head[0]:22s}" + "".join(f"{h:>16s}" for h in head[1:4]) + "".join(f"{h:>20s}" for h in head[4:]))


def ratio(row, other):
    a, b = ns[row][other], ns[row]["replacing"]
    r = [a[i] / b[i] for i in range(min(len(a), len(b)))]
    return statistics.median(r), min(r), max(r)


for row in order:
    g = [statistics.median(gbs[row][a]) for a in ("simdutf", "loop", "replacing")]
    rs = [ratio(row, "simdutf"), ratio(row, "loop")]
    if md:
        cells = [row] + [f"{x:.2f}" for x in g] + [f"{m:.2f} [{lo:.2f}, {hi:.2f}]" for m, lo, hi in rs]
        print("| " + " | ".join(cells) + " |")
    else:
        print(f"{row:22s}" + "".join(f"{x:16.2f}" for x in g) + "".join(f"{m:10.2f} [{lo:.2f},{hi:.2f}]" for m, lo, hi in rs))
