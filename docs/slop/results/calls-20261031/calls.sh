#!/usr/bin/env bash
# calls.sh OUT ROUNDS NAME=BIN... : runs each calls binary in turn, ROUNDS
# times, rotating the order, pinned to the last core; then per case the
# minimum over rounds of each run's minimum, in TSC ticks.
set -euo pipefail
out=$1 rounds=$2; shift 2
mkdir -p "$out"
names=() bins=()
for a in "$@"; do names+=("${a%%=*}"); bins+=("${a#*=}"); done
core=$(( $(nproc) - 1 ))
for r in $(seq 1 "$rounds"); do
  for i in "${!names[@]}"; do
    k=$(( (r + i) % ${#names[@]} ))
    taskset -c "$core" "${bins[$k]}" > "$out/${names[$k]}.$r" 2>&1
  done
done
python3 - "$out" "${names[@]}" <<'PY'
import sys, collections
out, names = sys.argv[1], sys.argv[2:]
import glob
best = collections.defaultdict(dict)
order = []
for n in names:
    for f in glob.glob(f"{out}/{n}.*"):
        for line in open(f):
            p = line.split()
            if len(p) < 3: continue
            if p[0] not in order: order.append(p[0])
            v = float(p[1])
            best[p[0]][n] = min(best[p[0]].get(n, 1e9), v)
print(f"{'case':28s}" + "".join(f"{n:>12s}" for n in names))
for c in order:
    print(f"{c:28s}" + "".join(f"{best[c][n]:12.2f}" if n in best[c] else f"{'-':>12s}" for n in names))
PY
