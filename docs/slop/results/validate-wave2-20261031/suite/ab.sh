#!/usr/bin/env bash
# ab.sh OUT ROUNDS FILTER BIN... : interleaved runs of each binary on CPU 3,
# then benchstat on GB/s. A binary named vb-simdutf-KERNEL runs the C++ arm.
set -euo pipefail
out=$1 rounds=$2 filter=$3
shift 3
mkdir -p "$out"
for b in "$@"; do : > "$out/raw-$b.txt"; done
for r in $(seq 1 "$rounds"); do
  for b in "$@"; do
    case $b in
      vb-simdutf-*) BENCHTIME_MS=${BT:-50} taskset -c 3 ./out/bin/vb-simdutf "${b#vb-simdutf-}" "${CFILTER:-}" >> "$out/raw-$b.txt" ;;
      *) taskset -c 3 ./out/bin/$b --benchtime=${BT:-50}ms --filter="$filter" 2>&1 | grep '^Benchmark' >> "$out/raw-$b.txt" ;;
    esac
  done
done
files=()
for b in "$@"; do
  awk '/^Benchmark/ { for (i = 3; i < NF; i += 1) if ($(i + 1) == "MB/s") printf "%s\t1\t%.4f GB/s\n", $1, $i / 1000 }' "$out/raw-$b.txt" > "$out/$b.txt"
  files+=("$b=$out/$b.txt")
done
nix develop /home/user/workspace/repo -c benchstat "${files[@]}" > "$out/benchstat.txt" 2>/dev/null
cat "$out/benchstat.txt"
