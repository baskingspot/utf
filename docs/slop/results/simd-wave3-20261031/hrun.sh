#!/usr/bin/env bash
# Harness A/B: hrun.sh NAME ROUNDS "OPS..." ARM... ; each arm is
# out/h-<arm>/bin/bench-utf. Runs from the repository root (ops.tsv and
# the corpus), rotating the arm order each round, pinned to CPU 3.
set -euo pipefail
name=$1; rounds=$2; ops=$3; shift 3
arms=("$@")
here=$(pwd)
mkdir -p raw/$name
for arm in "${arms[@]}"; do : > raw/$name/$arm.txt; done
for round in $(seq 0 $((rounds - 1))); do
  for i in "${!arms[@]}"; do
    arm=${arms[$(( (round + i) % ${#arms[@]} ))]}
    (cd ../repo && taskset -c 3 "$here/out/h-$arm/bin/bench-utf" bench $ops) >> raw/$name/$arm.txt
  done
done
files=()
for arm in "${arms[@]}"; do
  awk '/^Benchmark/ { for (i = 3; i < NF; i += 2) if ($(i + 1) == "MB/s") printf "%s\t%s\t%.4f GB/s\n", $1, $2, $i / 1000 }' raw/$name/$arm.txt > raw/$name/$arm.gbs
  files+=("$arm=raw/$name/$arm.gbs")
done
nix develop ../repo -c benchstat "${files[@]}" > raw/$name/benchstat.txt 2>/dev/null
echo done $name
