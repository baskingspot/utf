#!/bin/bash
# cb.sh TREE(old|new) NAME CPU [DISPATCH]: build calls into /home/user/ab/out/c-NAME
set -euo pipefail
source ~/.nix-profile/etc/profile.d/nix.sh
cd /home/user/ab/calls-$1
taskset -c 0-1 nix develop /home/user/workspace/repo -c zig build -p /home/user/ab/out/c-$2 -Dutf-cpu=$3 ${4:+-Dutf-dispatch=$4} 2>&1 | grep -v warning | tail -20 || true
