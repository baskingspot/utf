#!/usr/bin/env bash
# rss.sh ARM...: peak RSS (MiB) of `bench-utf check OP` for each conversion op
# and each arm in out/h-<arm>, as `just bench-compare` measures it.
set -euo pipefail
cd /home/user/workspace/repo
printf '%-26s' "peak RSS (MiB)"; printf '%9s' "$@"; echo
for op in $(cat /home/user/ab/ops-convert.txt); do
    printf '%-26s' "$op"
    for a in "$@"; do
        command time -f %M -o /tmp/rss-run.txt /home/user/ab/out/h-$a/bin/bench-utf check "$op" > /dev/null 2>&1
        awk '{ printf "%9.1f", $1 / 1024 }' /tmp/rss-run.txt
    done
    echo
done
