#!/usr/bin/env bash
# sizes.sh NAME=UTF_CHECKOUT... : builds this consumer against each checkout
# of utf, for -Dcpu=baseline (dispatching) in every optimize mode, and for
# -Dcpu=baseline -Dutf-dispatch=false and -Dcpu=native in ReleaseFast, and
# prints the stripped size in bytes of the executable and the shared library.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
export ZIG_LOCAL_CACHE_DIR="${TMPDIR:-/tmp}/utf-sizes-zig-cache"
printf '%-8s %-12s %-26s %10s %10s\n' arm optimize build exe lib
for a in "$@"; do
  name=${a%%=*} utf=$(realpath "${a#*=}")
  work=$(mktemp -d)
  cp -r "$here/build.zig" "$here/src" "$work/"
  sed "s#@UTF@#$(realpath --relative-to="$work" "$utf")#" "$here/build.zig.zon.in" > "$work/build.zig.zon"
  run() {
    local opt=$1 label=$2; shift 2
    (cd "$work" && zig build -Doptimize="$opt" -p "out" "$@")
    printf '%-8s %-12s %-26s %10d %10d\n' "$name" "$opt" "$label" \
      "$(stat -c %s "$work/out/bin/consumer")" "$(stat -c %s "$work/out/lib/libconsumer.so")"
    rm -rf "$work/out"
  }
  for opt in ReleaseFast ReleaseSmall ReleaseSafe Debug; do run "$opt" baseline -Dcpu=baseline; done
  run ReleaseFast "baseline, no dispatch" -Dcpu=baseline -Dutf-dispatch=false
  run ReleaseFast native -Dcpu=native
  rm -rf "$work"
done
