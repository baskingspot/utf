#!/bin/bash
# build.sh <cpu> [out]: the A/B driver against the repo tree and /tmp/old.
set -e
P=/nix/store/3barrjjyf8n1yacihmf0p6f6767qvr0y-simdutf-9.2.1
c=$1; out=${2:-ab-$c}
cd /tmp/bench
nix develop /home/user/workspace/repo -c zig build-exe -OReleaseFast -mcpu=$c -lc -L$P/lib -lsimdutf -rpath $P/lib \
  --dep utf --dep old -Mroot=ab.zig --dep dispatch_options -Mutf=/home/user/workspace/repo/src/root.zig -Mdispatch_options=/tmp/bench/dispatch_options.zig -Mold=/tmp/old/src/root.zig -femit-bin=$out
