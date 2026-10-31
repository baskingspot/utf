#!/bin/bash
# The interleaved A/B: wave 2 (new) against wave 1 (old, 7d7cb56) and simdutf, one process per ISA, pinned to CPU 3.
cd /tmp/bench
for spec in native:icelake x86_64_v3:haswell x86_64_v2:westmere baseline:westmere; do
  cpu=${spec%%:*}; k=${spec##*:}
  [ -x ab-final-$cpu ] || ./build.sh $cpu ab-final-$cpu
  arms=new,new-valid,old,old-valid,simdutf,simdutf-valid
  [ $cpu = baseline ] && arms=$arms,scalar,scalar-valid
  SIMDUTF_FORCE_IMPLEMENTATION=$k BENCH_ARMS=$arms BENCH_SIZES=16,64,256,4096,65536 BENCH_SAMPLES=6 taskset -c 3 ./ab-final-$cpu > /tmp/ab-final/raw-$cpu.txt 2>&1
done
echo done > /tmp/ab-final/done
