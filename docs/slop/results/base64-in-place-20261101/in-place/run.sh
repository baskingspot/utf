#!/usr/bin/env bash
cd /tmp/inplace
for r in $(seq 1 10); do
  for cpu in native x86_64_v3 x86_64_v2; do
    if [ $((r % 2)) = 0 ]; then order="fixed base"; else order="base fixed"; fi
    for v in $order; do taskset -c 3 ./bench-$v-$cpu >> out/$v-$cpu.txt 2>&1; done
  done
  echo "round $r"
done
