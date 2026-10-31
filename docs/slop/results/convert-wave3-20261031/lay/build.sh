#!/bin/bash
# build.sh TREE CPU OUT
P=/nix/store/3barrjjyf8n1yacihmf0p6f6767qvr0y-simdutf-9.2.1
source ~/.nix-profile/etc/profile.d/nix.sh
cd /home/user/ab/lay
taskset -c 0-1 nix develop /home/user/workspace/repo -c zig build-exe -OReleaseFast -mcpu=$2 -lc -L$P/lib -lsimdutf -rpath $P/lib --dep utf -Mroot=lay.zig --dep dispatch_options -Mutf=$1/src/root.zig -Mdispatch_options=dispatch_options.zig -femit-bin=$3 2>&1 | grep -v warning; true
