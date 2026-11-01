# UTF-8 to UTF-32 with four-byte characters under Zig 0.17, 2026-11-01

On `zig-0.17` (`287d5d0`, Zig 0.17.0), `convert.utf8ToUtf32` and `validUtf8ToUtf32` on emoji text ran 11–16× slower with the AVX2 kernels than on `main` (`185e163`, Zig 0.16.0). The cause is a Zig 0.17 codegen change, not the port's source edits: the port did not touch the decoder, and one line of it compiles differently.

- Machine: Amp orb, KVM guest, Intel Xeon @ 2.60GHz (Ice Lake server), 2 cores × 2 threads; every timed process pinned to CPU 3, nothing built while anything was timed.
- Builds: the harness's `bench-utf`, `-Dcpu=x86_64_v3 -Dutf-cpu=x86_64_v3 -Dutf-dispatch=false`, ReleaseFast: `main` is `185e163` with Zig 0.16.0, `before` is `287d5d0` with Zig 0.17.0, `after` is `before` with this fix. simdutf 9.2.1 forced to `haswell`.
- Inputs: the harness's `utf8/` corpus, and `mix-N`, the UTF-8 of `"🙂 🚀🔥 ok 👍🏽 ✅ 🎉 "` repeated and cut at the last character boundary at or before 16, 64, 256, 4096, and 65536 bytes (16, 64, 254, 4095, 65536 bytes), which Ghostty's emoji stream resembles:

  ```python
  s = "🙂 🚀🔥 ok 👍🏽 ✅ 🎉 ".encode()
  # (s * k)[:n], then drop a trailing partial character
  ```

- Method: [ab.sh](bitcast-array-20261101/ab.sh), the harness's: every arm a `bench-<arm> serve` on CPU 3, each row timed on every arm back to back in an order that rotates by row and round, fresh processes each round, round 0 sizing the loops and discarded, 10 rounds at `BENCHTIME_MS=50`, then benchstat. Raw output in [raw/](bitcast-array-20261101/raw/).

## Takeaways

- **Fixed: back to `main` with Zig 0.16 on every row** (geomean −0.7% in time over 33 rows, no row slower beyond its interval). Emoji corpus, checked: 0.21 → 2.48 GB/s (`main` 2.57, `haswell` 2.13); valid form 0.20 → 3.04 GB/s (`main` 3.05). The 254-byte mix: 991 → 155 ns (`main` 152, `haswell` 336); 4 KiB 19.3 → 1.70 µs; 64 KiB 317 → 26.7 µs.
- **The SSE tier had it too**: `-Dcpu=x86_64_v2`, emoji 344–377 → 31.5–31.9 µs, 254 bytes 1159–1211 → 171 ns (3 sequential runs each, not interleaved). AVX-512 does not use this decoder. On aarch64 the IR of the NEON build had the same loop before the fix and has none after; not timed, for want of hardware.
- **UTF-16 output, and text without four-byte characters, never had it**: the loop is only in the `four and T == u32` branch of `utf8DecodeBlock`. `utf8ToUtf16le` on the same inputs: `before` = `after` = `main`.
- Rows under 64 bytes never reach the block decoder, which is why 16 and 64 bytes were unaffected.
- Unchanged and not this fix's: `haswell` leads on the 64-byte mix (1.15 against 0.81 GB/s checked, 1.52 against 1.15 valid) on `main` as on this branch.
- Memory: unchanged; no allocation, and the stack array is the same 128 bytes.

## The cause

`utf8DecodeBlock` (src/convert.zig) builds bits 16–20 of each code point for a block with four-byte characters as a `@Vector(128, u8)` and stores it into `tops: [64]u16` with `tops = @bitCast(...)`. Zig 0.17's LLVM backend lowers a `@bitCast` from a vector to an array of scalars of a different type by bitcasting the vector to one integer (`i1024`) and running a loop that, for each array element, shifts that integer right by a variable amount and truncates:

```llvm
%4 = load i1024, ptr %0, align 128
...
%8 = lshr i1024 %4, %7
%9 = trunc i1024 %8 to i16
store i16 %9, ptr %10, align 2
```

LLVM does not fold it back into vector stores: each element copies the 128-byte value through the stack and shifts it with `shrx`/`shlx` (in the `x86_64_v3` shim, `mov` count in the function went from 64 to 341). Zig 0.16 emitted four 32-byte loads and stores for the same cast. [repro.zig](bitcast-array-20261101/repro.zig) shows it alone: `f` (`[64]u16 = @bitCast(@Vector(128, u8))`) is 4 loads and 4 stores with Zig 0.16 and a 430-line loop with Zig 0.17; `g`, the cast to `@Vector(64, u16)` then a coercion to the array, is 4 loads and 4 stores with both.

Casts that are fine under Zig 0.17: vector to vector, array of vectors to vector and back, and coercion from a vector to an array of its own lane type (LLVM splits that into vector stores). The fix casts to `@Vector(64, u16)` and lets the assignment coerce.

```zig
tops = @as(@Vector(64, u16), @bitCast(@shuffle(u8, t, zero, interleave)));
```

## Other sites

Grepping the ReleaseFast LLVM IR of the test build (every public function) for a variable `lshr` of an integer of 256 bits or more, on `x86_64_v2`, `x86_64_v3`, and `icelake_server`, finds one more after the fix: `compressMem` in src/base64.zig, `const src: [64]u8 = @bitCast(values)` from `[blocks]V`. Changing it the same way removed the loop from the IR but did not move `base64.decode` on MIME input (5 sequential runs: 553 against 554 ns at 4 KiB, 36 against 37 ns at 64 bytes), so it is left as is. `base64.decode` on MIME input is 10–30% slower on this branch than on `main` with Zig 0.16 in a single-pass scan of every operation; that has some other cause and is not looked at here.

## Correctness

`zig build test` in Debug and ReleaseSafe on native (every tier the CPU has, through `dispatch.forEachLevel`), and ReleaseSafe with `-Dcpu=x86_64_v3` and `-Dcpu=x86_64_v2`, pass with Zig 0.17.0.

## benchstat

`before` against `after`, time per call: [benchstat-before-after.txt](bitcast-array-20261101/benchstat-before-after.txt). `main` (Zig 0.16) against `after`: [benchstat-main-after.txt](bitcast-array-20261101/benchstat-main-after.txt). All four arms in GB/s, `main` as the base: [benchstat-gbs.txt](bitcast-array-20261101/benchstat-gbs.txt). The checked emoji rows:

```
                            │     main      │                before                 │                 after                 │                simdutf                │
                            │     GB/s      │     GB/s       vs base                │     GB/s       vs base                │     GB/s       vs base                │
Utf8ToUtf32/mix-16            1126.6m ±  5%   1142.6m ±  3%        ~ (p=0.172 n=10)   1152.4m ±  7%        ~ (p=0.078 n=10)    659.6m ±  5%  -41.45% (p=0.000 n=10)
Utf8ToUtf32/mix-64             824.4m ±  3%    821.2m ±  2%        ~ (p=0.342 n=10)    814.4m ±  1%        ~ (p=0.280 n=10)   1149.9m ±  9%  +39.48% (p=0.000 n=10)
Utf8ToUtf32/mix-254           1667.7m ± 10%    256.4m ± 14%  -84.62% (p=0.000 n=10)   1643.3m ±  2%        ~ (p=0.190 n=10)    744.9m ±  5%  -55.34% (p=0.000 n=10)
Utf8ToUtf32/mix-4095          2408.3m ±  3%    212.2m ±  3%  -91.19% (p=0.000 n=10)   2410.1m ±  4%        ~ (p=0.739 n=10)   1371.0m ±  3%  -43.07% (p=0.000 n=10)
Utf8ToUtf32/mix-65536         2465.7m ±  3%    206.5m ±  5%  -91.63% (p=0.000 n=10)   2456.2m ± 20%        ~ (p=0.796 n=10)   1410.0m ±  9%  -42.82% (p=0.000 n=10)
Utf8ToUtf32/emoji             2571.4m ± 13%    206.5m ±  5%  -91.97% (p=0.000 n=10)   2480.9m ± 19%        ~ (p=0.353 n=10)   2133.2m ± 16%  -17.04% (p=0.001 n=10)
```
