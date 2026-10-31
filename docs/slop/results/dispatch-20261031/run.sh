#!/usr/bin/env bash
set -euo pipefail
arms=(tier dispatch native generic)
rm -rf raw && mkdir raw
for round in $(seq 0 7); do
  for i in "${!arms[@]}"; do
    arm=${arms[$(( (round + i) % ${#arms[@]} ))]}
    taskset -c 3 out/$arm/bin/ab --benchtime=200ms >> raw/$arm.txt
  done
done
echo done
