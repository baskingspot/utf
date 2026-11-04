#!/usr/bin/env bash
set -u
B=/tmp/arms/bin
cd /tmp/encoding
arms=(); for s in before after; do for v in bd-none bd-avx2 bd-sse v3d nat; do arms+=("$s-$v=$B/bmpb-$s-$v serve utf"); done; done
python3 /tmp/serve-ab.py /tmp/ds/run-bmp 10 /tmp/rows-bmp.txt "${arms[@]}"
echo bmp-finished
cd /home/user/workspace/repo
arms=(); for s in before after; do for v in bd-none bd-avx2 bd-sse v3d nat; do arms+=("$s-$v=$B/utf-$s-$v serve"); done; done
BENCHTIME_MS=50 python3 /tmp/serve-ab.py /tmp/ds/run-gen 10 /tmp/ds/rows-gen.txt "${arms[@]}"
echo gen-finished
