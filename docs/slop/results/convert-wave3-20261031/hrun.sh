#!/usr/bin/env bash
# hrun.sh NAME ROUNDS "OPS..." ARM... ; each arm is out/h-<arm>/bin/bench-utf,
# or simdutf:<kernel> for the harness's simdutf arm with that kernel. Runs
# from the repository root, rotating the arm order each round, pinned to CPU 3.
set -euo pipefail
source ~/.nix-profile/etc/profile.d/nix.sh
cd /home/user/ab
name=$1; rounds=$2; ops=$3; shift 3
arms=("$@")
here=$(pwd)
mkdir -p raw/$name
for arm in "${arms[@]}"; do : > raw/$name/${arm/:/-}.txt; done
for round in $(seq 0 $((rounds - 1))); do
  for i in "${!arms[@]}"; do
    arm=${arms[$(( (round + i) % ${#arms[@]} ))]}
    if [[ $arm == simdutf:* ]]; then
      (cd /home/user/workspace/repo && SIMDUTF_FORCE_IMPLEMENTATION=${arm#simdutf:} taskset -c 3 /home/user/ab/bench-simdutf bench $ops) >> raw/$name/${arm/:/-}.txt
    else
      (cd /home/user/workspace/repo && taskset -c 3 "$here/out/h-$arm/bin/bench-utf" bench $ops) >> raw/$name/$arm.txt
    fi
  done
done
files=()
for arm in "${arms[@]}"; do
  a=${arm/:/-}
  awk '/^Benchmark/ { for (i = 3; i < NF; i += 2) if ($(i + 1) == "MB/s") printf "%s\t%s\t%.4f GB/s\n", $1, $2, $i / 1000 }' raw/$name/$a.txt > raw/$name/$a.gbs
  files+=("$a=raw/$name/$a.gbs")
done
nix develop /home/user/workspace/repo -c benchstat "${files[@]}" > raw/$name/benchstat.txt 2>/dev/null
echo done $name
