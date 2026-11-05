# Paired ratios: for each row and round, arm time / reference time (the
# same round), then the median over rounds with min and max.
import sys, re, collections, statistics
ref = sys.argv[2] if len(sys.argv) > 2 else 'simdutf'
rows = collections.defaultdict(lambda: collections.defaultdict(list))
for line in open(sys.argv[1]):
    m = re.match(r'Benchmark(\S+)/arm=(\S+)\s+\d+\s+([\d.]+) ns/op', line)
    if m: rows[m.group(1)][m.group(2)].append(float(m.group(3)))
arms = None
for row, d in rows.items():
    if arms is None: arms = [a for a in d if a != ref]; print(f"{'row':28s}" + ''.join(f'{a+"/"+ref:>22s}' for a in arms) + f"{ref+' ns':>12s}")
    out = f'{row:28s}'
    for a in arms:
        r = [d[ref][i] / d[a][i] for i in range(min(len(d[a]), len(d[ref])))]
        out += f'{statistics.median(r):10.3f} [{min(r):.2f},{max(r):.2f}]'
    out += f'{statistics.median(d[ref]):12.1f}'
    print(out)
