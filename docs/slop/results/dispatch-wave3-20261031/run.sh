#!/usr/bin/env bash
# Interleaved A/B: run.sh NAME ROUNDS ARM... ; each arm is out/<arm>/bin/ab.
# Rotates the arm order each round, pinned to CPU 3.
set -euo pipefail
name=$1; rounds=$2; shift 2
arms=("$@")
mkdir -p raw/$name
for arm in "${arms[@]}"; do : > raw/$name/$arm.txt; done
for round in $(seq 0 $((rounds - 1))); do
  for i in "${!arms[@]}"; do
    arm=${arms[$(( (round + i) % ${#arms[@]} ))]}
    taskset -c 3 out/$arm/bin/ab --benchtime=${BT:-100ms} ${FILTER:+-f "$FILTER"} >> raw/$name/$arm.txt
  done
done
files=()
for arm in "${arms[@]}"; do
  awk '/^Benchmark/ { for (i = 3; i < NF; i += 2) if ($(i + 1) == "MB/s") printf "%s\t%s\t%.4f GB/s\n", $1, $2, $i / 1000 }' raw/$name/$arm.txt > raw/$name/$arm.gbs
  files+=("$arm=raw/$name/$arm.gbs")
done
nix develop ../repo -c benchstat "${files[@]}" > raw/$name/benchstat.txt
echo done $name
