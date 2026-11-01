#!/bin/bash
# obj.sh TREE OUT [CPU]: a.zig's exports against TREE's package, ReleaseFast.
source ~/.nix-profile/etc/profile.d/nix.sh
cd /home/user/ab/asm
taskset -c 0-1 nix develop /home/user/workspace/repo -c zig build-obj -OReleaseFast -mcpu=${3:-native} --dep utf -Mroot=a.zig --dep dispatch_options -Mutf=$1/src/root.zig -Mdispatch_options=opts.zig -femit-bin=$2.o 2>&1 | tail -5
nix develop /home/user/workspace/repo -c objdump -d --no-show-raw-insn -M intel $2.o > $2.s
