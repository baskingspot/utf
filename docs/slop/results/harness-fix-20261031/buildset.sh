# usage: buildset.sh DIR  — builds every arm into DIR, utf in three configs
set -e
d=$1; mkdir -p $d
just bench-build >/dev/null
for a in simdutf std rust go; do cp zig-out/bin/bench-$a $d/; done
(cd bench && zig build -p ../zig-out) && cp zig-out/bin/bench-utf $d/utf-native
(cd bench && zig build -p ../zig-out -Dutf-cpu=x86_64_v3 -Dutf-dispatch=false) && cp zig-out/bin/bench-utf $d/utf-v3
(cd bench && zig build -p ../zig-out -Dutf-cpu=baseline) && cp zig-out/bin/bench-utf $d/utf-baseline
(cd bench && zig build -p ../zig-out)
