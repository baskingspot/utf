import re, sys, math, collections
# per-op geomean of each arm vs base from a summ file, all rows and short rows
path=sys.argv[1]; arms=sys.argv[2].split(',')
allr=collections.defaultdict(lambda: collections.defaultdict(list))
short=collections.defaultdict(lambda: collections.defaultdict(list))
for line in open(path):
    ms = re.findall(r'([\d.]+) \[([\d.]+),([\d.]+)\] (\S)', line)
    if not ms or len(ms) < len(arms): continue
    row=line.split()[0]; op=row.split('/')[0]
    for a,m in zip(arms,ms):
        allr[op][a].append(math.log(float(m[0])))
        if re.search(r'-(16|64)$', row): short[op][a].append(math.log(float(m[0])))
g=lambda v: math.exp(sum(v)/len(v)) if v else float('nan')
print(f"{'op':26s}" + "".join(f"{a:>8s}" for a in arms) + "  |" + "".join(f"{a+'@16-64':>12s}" for a in arms))
tot=collections.defaultdict(list); tots=collections.defaultdict(list)
for op in allr:
    print(f"{op:26s}" + "".join(f"{g(allr[op][a]):8.3f}" for a in arms) + "  |" + "".join(f"{g(short[op][a]):12.3f}" for a in arms))
    for a in arms:
        tot[a].append(math.log(g(allr[op][a])))
        if short[op][a]: tots[a].append(math.log(g(short[op][a])))
print("geomean of per-op geomeans:", " ".join(f"{a} {g(tot[a]):.3f}" for a in arms), "| short rows:", " ".join(f"{a} {g(tots[a]):.3f}" for a in arms))
