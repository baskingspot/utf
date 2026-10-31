#!/usr/bin/env bash
# Interleaved A/B of bench/zig/arm.zig's Out: old (origin/main 6f0a81a) against new,
# native and x86_64_v3 dispatch=false, pinned to CPU 3, six rounds, alternating order.
set -e
cd /home/user/workspace/repo
out=/tmp/ab/res
# The service manager restarts a command that exits: keep finished results.
[ -e $out/ALLDONE ] && exec sleep infinity
rm -rf $out; mkdir -p $out
ops=$(grep -v '^#' bench/ops.tsv | cut -f1 | grep -E -- '-err$|^(utf8|utf16le|utf16be|utf32|latin1)-to-|^base64-decode') 
ops="$ops validate-utf8 valid-latin1-to-utf16le valid-utf8-to-utf16le"
echo "$ops" | tr '\n' ' ' > $out/ops.txt
labels=(utf-native utf-v3)
for round in 0 1 2 3 4 5; do
  for i in "${!labels[@]}"; do
    l=${labels[$(( (round + i) % ${#labels[@]} ))]}
    for v in old new; do
      [ $(( round % 2 )) = 1 ] && v=$([ $v = old ] && echo new || echo old)
      taskset -c 3 /tmp/ab/$v/$l bench $ops > $out/raw-$v-$l-$round.txt
      awk '/^Benchmark/ { for (i = 3; i < NF; i += 2) if ($(i + 1) == "MB/s") printf "%s\t%s\t%.4f GB/s\n", $1, $2, $i / 1000 }' $out/raw-$v-$l-$round.txt >> $out/$v-$l.txt
      awk '/^Benchmark/ { print $1 "\t" $2 "\t" $3 " ns/op" }' $out/raw-$v-$l-$round.txt >> $out/ns-$v-$l.txt
    done
  done
  echo "round $round done $(date +%T)"
done
echo ALLDONE; touch $out/ALLDONE; exec sleep infinity
