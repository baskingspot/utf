import sys, collections, statistics, math
# cmp.py DIR A B: per row, the median over rounds of A's time / B's time in
# the same round; prints rows where every round agrees on the side of 1 and
# the median is beyond 10%, and the geomean over all rows.
d, a, b = sys.argv[1:4]
def load(arm):
    t = collections.defaultdict(list)
    for line in open(f'{d}/{arm}.txt'):
        row, _, ns = line.split('\t')
        t[row].append(float(ns.split()[0]))
    return t
A, B = load(a), load(b)
logs = []
out = []
for row in A:
    r = [x / y for x, y in zip(A[row], B[row])]
    m = statistics.median(r)
    logs.append(math.log(m))
    if (min(r) > 1 or max(r) < 1) and (m > 1.10 or m < 1 / 1.10):
        out.append((m, row, min(r), max(r), statistics.median(A[row]), statistics.median(B[row])))
for m, row, lo, hi, ta, tb in sorted(out):
    print(f'{row:48s} {a}/{b} {m:6.2f}  [{lo:.2f}, {hi:.2f}]  {ta:12.1f} {tb:12.1f} ns')
print(f'geomean {a}/{b} over {len(logs)} rows: {math.exp(sum(logs) / len(logs)):.3f}')
