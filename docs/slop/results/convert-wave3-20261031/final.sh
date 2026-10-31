#!/bin/bash
# Wave-3 transcoding baseline: the 49 conversion and length ops on wave3-convert.
set -u
cd "$(git rev-parse --show-toplevel)"
source ~/.nix-profile/etc/profile.d/nix.sh
ops="utf8-to-utf16le valid-utf8-to-utf16le utf8-to-utf16be valid-utf8-to-utf16be utf8-to-utf32 valid-utf8-to-utf32 utf8-to-latin1 valid-utf8-to-latin1 utf16le-to-utf8 valid-utf16le-to-utf8 utf16le-to-utf16be valid-utf16le-to-utf16be utf16le-to-utf32 valid-utf16le-to-utf32 utf16le-to-latin1 valid-utf16le-to-latin1 utf16be-to-utf8 valid-utf16be-to-utf8 utf16be-to-utf16le valid-utf16be-to-utf16le utf16be-to-utf32 valid-utf16be-to-utf32 utf16be-to-latin1 valid-utf16be-to-latin1 utf32-to-utf8 valid-utf32-to-utf8 utf32-to-utf16le valid-utf32-to-utf16le utf32-to-utf16be valid-utf32-to-utf16be utf32-to-latin1 valid-utf32-to-latin1 latin1-to-utf8 valid-latin1-to-utf8 latin1-to-utf16le valid-latin1-to-utf16le latin1-to-utf16be valid-latin1-to-utf16be latin1-to-utf32 valid-latin1-to-utf32 utf16-from-utf8 utf16-from-utf32 utf8-from-utf16le utf8-from-utf16be utf8-from-utf32 utf8-from-latin1 count-utf8 count-utf16le count-utf16be"
out=/home/user/runs/${1:-base}
mkdir -p $out
nix develop -c just bench-compare 3 $ops > $out/native.log 2>&1; rm -rf $out/native; cp -r zig-out/bench-compare $out/native
nix develop -c just cpu=x86_64_v3 dispatch=false kernel=haswell bench-compare 3 $ops > $out/avx2.log 2>&1; rm -rf $out/avx2; cp -r zig-out/bench-compare $out/avx2
nix develop -c just cpu=x86_64_v2 dispatch=false kernel=westmere bench-compare 3 $ops > $out/sse.log 2>&1; rm -rf $out/sse; cp -r zig-out/bench-compare $out/sse
echo done > $out/DONE
