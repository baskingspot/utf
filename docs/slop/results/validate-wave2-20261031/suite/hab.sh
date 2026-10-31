#!/usr/bin/env bash
# hab.sh OUT ROUNDS "OPS" NAME=BIN... : interleaved harness-arm A/B on CPU 3.
set -euo pipefail
out=$1 rounds=$2 ops=$3; shift 3
mkdir -p "$out"; cd /home/user/workspace/repo
for nb in "$@"; do : > "$out/raw-${nb%%=*}.txt"; done
for r in $(seq 1 "$rounds"); do
  for nb in "$@"; do BENCHTIME_MS=${BT:-100} taskset -c 3 "${nb#*=}" bench $ops >> "$out/raw-${nb%%=*}.txt"; done
done
files=()
for nb in "$@"; do n=${nb%%=*}
  awk '/^Benchmark/ { for (i = 3; i < NF; i += 2) if ($(i + 1) == "MB/s") printf "%s\t%s\t%.4f GB/s\n", $1, $2, $i / 1000 }' "$out/raw-$n.txt" > "$out/$n.txt"
  files+=("$n=$out/$n.txt")
done
nix develop /home/user/workspace/repo -c benchstat "${files[@]}" > "$out/benchstat.txt" 2>/dev/null
