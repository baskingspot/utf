#!/bin/bash
# callsab.sh OUT FILTER LENS NAME... : each calls binary out/c-NAME, 3 rounds rotating, min per case; LATIN=1 passes through.
out=$1 filter=$2 lens=$3; shift 3
mkdir -p $out
for r in 1 2 3; do
  for i in $(seq 0 $(($#-1))); do
    args=("$@"); k=$(( (r + i) % $# )); n=${args[$k]}
    taskset -c 3 out/c-$n/bin/calls "$filter" "$lens" > $out/$n.$r 2>&1
  done
done
python3 - $out "$@" <<'PY'
import sys, collections, glob
out, names = sys.argv[1], sys.argv[2:]
best = collections.defaultdict(dict); order = []
for n in names:
    for f in sorted(glob.glob(f"{out}/{n}.*")):
        for line in open(f):
            p = line.split()
            if len(p) < 2: continue
            if p[0] not in order: order.append(p[0])
            best[p[0]][n] = min(best[p[0]].get(n, 1e9), float(p[1]))
print(f"{'case':40s}" + "".join(f"{n:>9s}" for n in names))
for c in order:
    print(f"{c:40s}" + "".join(f"{best[c].get(n, float('nan')):9.2f}" for n in names))
PY
