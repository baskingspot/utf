#!/usr/bin/env bash
# gates.sh OUT: every gate on the working tree, pinned to CPUs 0-1, into OUT.
set -uo pipefail
source ~/.nix-profile/etc/profile.d/nix.sh
cd /home/user/workspace/repo
export PATH=/nix/store/1wjkglafi3l64ry9nf206l0ayykisrdr-qemu-user-11.1.2/bin:$PATH
out=$1
: > "$out"
run() {
    echo "== $*" >> "$out"
    taskset -c 0-1 nix develop -c "$@" > /tmp/gate.log 2>&1
    rc=$?
    grep -E "testingx:|mismatch|error:|FAIL" /tmp/gate.log | tail -5 >> "$out"
    echo "exit $rc" >> "$out"
}
for args in "-Dcpu=native" "-Dcpu=x86_64_v3 -Ddispatch=false" "-Dcpu=x86_64_v2 -Ddispatch=false" \
    "-Dcpu=x86_64_v3" "-Dcpu=baseline" "-Dcpu=baseline -Ddispatch=false"; do
    run zig build test -Doptimize=ReleaseSafe $args --summary all
done
run zig build test -Doptimize=Debug -Dcpu=baseline --summary all
run zig build test -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl -fqemu --summary all
run zig build test -Doptimize=Debug -Dtarget=aarch64-linux-musl -fqemu --summary all
run zig build test -Doptimize=ReleaseSafe -Dtarget=aarch64_be-linux-musl -fqemu --summary all
run just oracle
cp /tmp/gate.log "$out.oracle.log"
run just ci
cp /tmp/gate.log "$out.ci.log"
