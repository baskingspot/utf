set -e
out=/tmp/ab/res; rm -rf $out; mkdir -p $out
ops="validate-utf8 base64-encode base64-decode base64-decode-mime"
labels=(simdutf simdutf-haswell utf-native utf-v3 utf-baseline std rust go)
cmd() { # version label
  case $2 in
    simdutf) echo "/tmp/ab/$1/bench-simdutf";;
    simdutf-haswell) echo "env SIMDUTF_FORCE_IMPLEMENTATION=haswell /tmp/ab/$1/bench-simdutf";;
    utf-*) echo "/tmp/ab/$1/$2";;
    *) echo "/tmp/ab/$1/bench-$2";;
  esac
}
for round in 0 1 2 3 4 5; do
  for i in "${!labels[@]}"; do
    l=${labels[$(( (round + i) % ${#labels[@]} ))]}
    for v in old new; do
      [ $(( round % 2 )) = 1 ] && v=$([ $v = old ] && echo new || echo old)
      taskset -c 3 $(cmd $v $l) bench $ops | awk '/^Benchmark/ { for (i = 3; i < NF; i += 2) if ($(i + 1) == "MB/s") printf "%s\t%s\t%.4f GB/s\n", $1, $2, $i / 1000 }' >> $out/$v-$l.txt
    done
  done
  echo "round $round done $(date +%T)"
done
