#!/usr/bin/env bash
# ReleaseSmall sizes of the size-* programs, .rodata + .text from `size -A`,
# net of size-none, per target: zig build in this directory (bench/build.zig
# depends on the utf checkout by path).
set -euo pipefail
cd "$(dirname "$0")"
out=${OUT:-out-size}
targets=(
  "native|-Dcpu=native"
  "x86_64_v3|-Dcpu=x86_64_v3"
  "x86_64_v3-nd|-Dcpu=x86_64_v3 -Dutf-dispatch=false"
  "x86_64_v2|-Dcpu=x86_64_v2"
  "x86_64_v2-nd|-Dcpu=x86_64_v2 -Dutf-dispatch=false"
  "baseline|-Dcpu=baseline"
  "baseline-nd|-Dcpu=baseline -Dutf-dispatch=false"
  "aarch64|-Dtarget=aarch64-linux-musl"
)
sec() { size -A "$1" | awk -v s="$2" '$1 == s { print $2 }'; }
printf '%-14s %-10s %8s %8s %8s\n' target program rodata text total
for t in "${targets[@]}"; do
  name=${t%%|*}; flags=${t#*|}
  zig build -Doptimize=ReleaseSmall $flags -p "$out/$name"
  b="$out/$name/bin"
  r0=$(sec "$b/size-none" .rodata); t0=$(sec "$b/size-none" .text)
  for v in utf-both utf-to8 utf-from8 enc-both enc-to8 enc-from8; do
    r=$(( $(sec "$b/size-$v" .rodata) - r0 )); x=$(( $(sec "$b/size-$v" .text) - t0 ))
    printf '%-14s %-10s %8d %8d %8d\n' "$name" "$v" "$r" "$x" $(( r + x ))
  done
done
