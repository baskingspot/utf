#!/bin/bash
# asm.sh TREE CPU OUT: objdump of every exported function, one file.
source ~/.nix-profile/etc/profile.d/nix.sh
cd /home/user/ab/asm
taskset -c 0-1 nix develop /home/user/workspace/repo -c zig build-obj -OReleaseFast -mcpu=$2 --dep utf -Mroot=asm.zig --dep dispatch_options -Mutf=$1/src/root.zig -Mdispatch_options=dispatch_options.zig -femit-bin=$3.o 2>&1 | grep -v warning
objdump -d --no-show-raw-insn -M intel $3.o > $3.s
