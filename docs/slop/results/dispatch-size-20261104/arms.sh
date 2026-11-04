#!/usr/bin/env bash
# Builds the A/B arms: before (origin/main) and after (this tree), each as is
# and with dispatch pinned to the AVX2 or SSE tier; bmpb and bench-utf.
set -euo pipefail
source /tmp/old.sh
A=/tmp/arms; mkdir -p $A/bin
for side in before after; do
  src=/tmp/utf-before; [ $side = after ] && src=/home/user/workspace/repo
  for pin in none avx2 sse; do
    t=$A/utf-$side-$pin; [ -e $A/bin/utf-$side-bd-$pin ] && continue; rm -rf $t; mkdir -p $t
    (cd $src && tar --exclude=.zig-cache --exclude=zig-out --exclude=zig-pkg --exclude=.git --exclude=docs/slop -cf - .) | (cd $t && tar -xf -)
    if [ $pin != none ]; then sed -i "s/        if (supports(features, t)) return t.isa;/        if (t.isa == .$pin and supports(features, t)) return t.isa;/" $t/src/dispatch.zig; grep -q "t.isa == .$pin" $t/src/dispatch.zig; fi
    b=$A/bmpb-$side-$pin; mkdir -p $b; cp /tmp/bmpb/{build.zig,bench.zig,size.zig,enc_codec.zig} $b/
    sed "s|\"../../home/user/workspace/repo\"|\"../utf-$side-$pin\"|" /tmp/bmpb/build.zig.zon > $b/build.zig.zon
    (cd $b && zig build -Dcpu=baseline -p out-bd >/dev/null && cp out-bd/bin/bmpb $A/bin/bmpb-$side-bd-$pin)
    (cd $t/bench && zig build -Dutf-cpu=baseline -p out-bd >/dev/null && cp out-bd/bin/bench-utf $A/bin/utf-$side-bd-$pin)
    if [ $pin = none ]; then
      (cd $b && zig build -Dcpu=x86_64_v3 -p out-v3 >/dev/null && cp out-v3/bin/bmpb $A/bin/bmpb-$side-v3d)
      (cd $b && zig build -Dcpu=native -p out-nat >/dev/null && cp out-nat/bin/bmpb $A/bin/bmpb-$side-nat)
      (cd $t/bench && zig build -Dutf-cpu=x86_64_v3 -p out-v3 >/dev/null && cp out-v3/bin/bench-utf $A/bin/utf-$side-v3d)
      (cd $t/bench && zig build -p out-nat >/dev/null && cp out-nat/bin/bench-utf $A/bin/utf-$side-nat)
    fi
  done
done
ls $A/bin
echo arms-done
