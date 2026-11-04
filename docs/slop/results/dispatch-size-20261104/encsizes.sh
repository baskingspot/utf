#!/usr/bin/env bash
# encoding's bench/comptime link-size programs, ReleaseSmall, .rodata+.text
# net of size-none, against utf v0.2.0 (before) and this branch (after, via
# zig build --fork).
set -euo pipefail
source /tmp/old.sh
cd /tmp/encoding/bench/comptime
progs="ct_1252 ct_enc_1252 ct_utf8_1252 rt_label rt_enc_label"
sec() { size -A "$1" | awk -v s="$2" '$1 == s { print $2 }'; }
printf '%-8s %-22s %-14s %9s %9s %9s\n' side target program rodata text total
for side in before after; do
  fork=""; [ $side = after ] && fork="--fork=/home/user/workspace/repo"
  for t in "native|" "x86_64_v3|-Dcpu=x86_64_v3" "x86_64_v3-off|-Dcpu=x86_64_v3 -Ddispatch=false" "x86_64_v2|-Dcpu=x86_64_v2" "x86_64_v2-off|-Dcpu=x86_64_v2 -Ddispatch=false" "baseline|-Dcpu=baseline" "baseline-off|-Dcpu=baseline -Ddispatch=false"; do
    name=${t%%|*}; flags=${t#*|}
    out=/tmp/ds/enc-$side-$name
    zig build sizes -Doptimize=ReleaseSmall $flags $fork -p $out >/dev/null 2>&1
    r0=$(sec $out/bin/size-none .rodata); t0=$(sec $out/bin/size-none .text)
    for p in $progs; do
      r=$(( $(sec $out/bin/size-$p .rodata) - r0 )); x=$(( $(sec $out/bin/size-$p .text) - t0 ))
      printf '%-8s %-22s %-14s %9d %9d %9d\n' $side $name $p $r $x $((r + x))
    done
  done
done
