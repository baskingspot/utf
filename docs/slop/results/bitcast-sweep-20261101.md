# Every `@bitCast` to or from an array, under Zig 0.17, 2026-11-01

[bitcast-array-20261101.md](bitcast-array-20261101.md) found one `@bitCast` that Zig 0.17 compiles to a loop, in the UTF-8 to UTF-32 decoder. This is the search for the rest, first on `zig-0.17` at `37351aa` (on `main` at `9699695`), then again after the branch was rebased to `4a0bb17` (on `main` at `db5728c`, with the NEON validate, convert, and length work and in-place base64 decoding). It found 42 more; one family, in base64 decoding, cost 10× on text with scattered whitespace, and is fixed with two helpers, `simd.split` and `simd.join`, at 10 of `base64.zig`'s 13 casts. Replacing the other casts was measured too and left out.

- Machine: Amp orb, KVM guest, Intel Xeon @ 2.60GHz (Ice Lake server, AVX-512 with VBMI2), 2 cores × 2 threads; every timed process pinned to CPU 3, builds on CPUs 0–1, nothing built while anything was timed.
- Arms: the harness's `bench-utf`, ReleaseFast. Before the rebase: `main` is `9699695` with Zig 0.16.0, `base` is `37351aa` with Zig 0.17.0, `all13` is the change at all 13 of `base64.zig`'s casts, and `join` a variant that also replaced the 29 other casts the scan found with `split` and `join` and gave `lookup16` a vector table (not kept). After it: `base` is `4a0bb17`, `all13` the same change rebased, and `final` this commit, which leaves the three casts in `finish` and `packAll`. Built for `x86_64_v3` (AVX2) and `x86_64_v2` (SSE) with dispatch off, and native (AVX-512).
- Inputs: the harness's corpus, and four more in `base64-mime/`: base64 of random bytes with a space after every 8 or 16 characters (`spaced8-4607`, `spaced8-73727`, `spaced16-4351`, `spaced16-69631`), 3–7 whitespace characters in each 64-byte block where MIME's line breaks put 1–2.
- Method: [ab.sh](bitcast-sweep-20261101/ab.sh), the harness's: every arm a `bench-utf serve` on CPU 3, each row timed on every arm back to back in an order that rotates by row and round, fresh processes each round, round 0 sizing the loops and discarded. [cmp.py](bitcast-sweep-20261101/cmp.py) gives each row's median over the rounds of the per-round time ratio and lists the rows where every round falls on the same side of 1 and the median is beyond 10%. Base64 runs: the decoding operations and `base64-encode` (40 rows after the rebase, 46 before), 10 rounds at `BENCHTIME_MS=30`, per build. `join`: every row (881), 6 rounds at 20 ms, per build. benchstat and the raw output (gzipped) in [rebased/](bitcast-sweep-20261101/rebased/), [prerebase/](bitcast-sweep-20261101/prerebase/), and [join/](bitcast-sweep-20261101/join/).
- Search: [scan.py](bitcast-sweep-20261101/scan.py) reads the Debug LLVM IR of the test build (every public function, every tier the target has) and reports by source line the loops Zig 0.17 emits for a cast through an integer: a variable `lshr` after an `llvm.assume` (to an array), a variable `extractelement` (to an array of the same lane type), and a `shl` by a widened constant (from an array). Debug, because ReleaseFast unrolls most of them. Targets: `x86_64` baseline, `x86_64_v2`, `x86_64_v3`, `icelake_server`, `aarch64` generic, and `apple_m1`.

## Takeaways

- **Zig 0.17 compiles every `@bitCast` whose operand or result is an array through one integer as wide as the value**, with a loop over the array's elements: shift and truncate for each element of a result, shift and or for each element of an operand. Zig 0.16 stored and loaded the value. Vector to vector casts, and coercions between a vector and an array of its own lane type, are unaffected. LLVM unrolls the short loops, mostly back into register moves; where it does not, the value goes to general registers and back a byte at a time (`vpextrq`, `shr`, `vpinsrb`), or stays a loop.
- **Found 42 beyond the decoder's** at `37351aa`, in kernel code on little-endian targets: 13 in `base64.zig`, 19 in `convert.zig`, and 10 in `simd.zig` (`storeBytes`, `narrow`, NEON's 32- and 64-lane `bitmask`); 19 to an array and 23 from one. Four of those in `convert.zig` are `lookup16`'s `[16]u8` table, which callers fill by casting a `@Vector(4, u32)` or `@Vector(8, u16)`. Two more are in `simd.zig`'s tests.
- **Base64 decoding of text with scattered whitespace: 10× faster with AVX2 and SSE, level with Zig 0.16.** Three or more whitespace characters in a 64-byte block go to `compressMem`, whose `[64]u8 = @bitCast(values)` stayed a 64-iteration loop, on blocks from `classifyBlock`'s `[blocks]V = @bitCast(...)`, which unrolled into byte inserts. After the rebase, `base` ÷ `final`: AVX2 `spaced16-4351` 9.14 → 0.92 µs, `spaced8-73727` 155 → 15.3 µs, every spaced row 10.0–10.2×; SSE 10.4–10.8×, `spaced16-4351` 12.2 → 1.18 µs. Before it, `main` with Zig 0.16 took 0.96 µs (AVX2) and 1.18 µs (SSE) on `spaced16-4351`. AVX-512 with VBMI2 compresses with `vpcompressb` and never took the loop: unchanged (geomean 1.000). Line-wrapped MIME skips `compressMem` but takes `classifyBlock`; its 64- and 256-byte rows are 1.54× and 1.18× faster with AVX2. Geomean over the 40 rows: 1.277 (AVX2), 1.248 (SSE). Slower beyond 10%: SSE URL-safe decoding of 1 MiB (0.81, interval 0.77–0.94), which with the other 1 MiB decodes read 0.80–0.90 of `base` and level with `main` before the rebase, while 64 KiB is level in all arms.
- **The fix**: 10 casts in `base64.zig`, through `simd.split` (a vector to an array of vectors: a vector cast, then each element with `@shuffle`) and `simd.join` (the reverse: pairs concatenated with `@shuffle`, then a vector cast), and one `[2]u64` made a `@Vector(2, u64)`. Both give what `@bitCast` gives on any endianness: a vector's lanes lie in memory in order, and the shuffles move whole lanes of one type. The three casts in `finish` and `packAll`, the last block's, stay: on x86 `final` and `all13` are level (`all13` ÷ `final` in time, geomean: 1.008 AVX2, 0.996 SSE, 1.003 AVX-512, no row beyond 10%), and on aarch64, where nothing here can time it, `all13`'s shuffles merged with `storeBytes`' select into byte-lane moves (`mov v.b[i]`, `umov`) at the last block's partial store: 56 in `decodeStaged` and 72 in `decodeWith`, where `base` has 8 and 16, and `final` 16 and 16. `final`'s IR has no loops left on aarch64.
- **On `main` with Zig 0.16 the change does nothing**, so it stays on `zig-0.17`: `main` at `db5728c` against the same diff applied to it, both built with Zig 0.16.0, the same 40 base64 rows and 10 rounds, geomean in time 0.999 (AVX2), 1.004 (SSE), 1.000 (AVX-512), no row beyond 10% ([main16/](bitcast-sweep-20261101/main16/)). Zig 0.16 already compiled these casts as stores and loads: `spaced16-4351` takes 0.95 µs (AVX2) and 1.16 µs (SSE) on `main` either way.
- **The other 29 stay.** `join` replaced them all, and `lookup16` took a vector table. Against `base`, geomean in time over 881 rows: AVX2 1.013, SSE 1.014, AVX-512 0.983. On AVX2 and SSE the rows beyond 10% outside base64 split both ways (UTF-16BE to UTF-8 0.87 on Chinese and 1.17 on Japanese with AVX2, in two runs, with the same instruction mix in both builds). On AVX-512 it lost: UTF-16 to Latin-1 at 4 KiB 0.57–0.69, UTF-32 to UTF-16 0.72–0.80 on text. With the shuffles LLVM could see the lanes, and rewrote the two-register permutes that `narrow` and the UTF-16 to Latin-1 loop pick over `vpmovdw` and `vpmovwb` (two shuffle-port operations each): UTF-16 to Latin-1's `vpermt2b` became two `vpmovwb` and a `vinserti64x4`, and UTF-32 to UTF-16's permute two `vpmovdw`.
- **aarch64_be** had loops at more sites, in `@bitCast`s between vectors of different lane types, which Zig 0.17 lowers per lane on a big-endian target; it runs only in CI's tests under qemu, so they stay.
- **Not timed on aarch64**, for want of hardware. NEON's `bitmask` compiles to the same 21 instructions with its `@bitCast` or with `split`, so it stays. The NEON code from `db5728c` has 8 casts of this kind (`convert.zig` and `length.zig`), none of which leaves a loop in ReleaseFast; not changed.
- Memory: unchanged; no allocation.

## Rows beyond 10%, `final`

After the rebase, AVX2, `base` ÷ `final`:

```
Base64DecodeMime/random-256             base/final  1.18  [1.05, 1.25]          60.4         50.8 ns
Base64DecodeMime/random-64              base/final  1.54  [1.50, 1.55]          35.0         22.7 ns
Base64DecodeMime/spaced16-4351          base/final  10.02  [9.11, 10.13]        9139.8        916.0 ns
Base64DecodeMime/spaced16-69631         base/final  10.03  [9.58, 10.35]      146476.3      14486.4 ns
Base64DecodeMime/spaced8-4607           base/final  10.11  [8.02, 13.96]        9742.1        962.6 ns
Base64DecodeMime/spaced8-73727          base/final  10.15  [9.49, 10.94]      155330.4      15292.2 ns
```

SSE:

```
Base64DecodeUrl/random-1048576          base/final  0.81  [0.77, 0.94]      157124.8     190305.3 ns
Base64DecodeMime/spaced16-4351          base/final  10.38  [10.05, 11.07]       12198.7       1176.3 ns
Base64DecodeMime/spaced8-4607           base/final  10.50  [10.18, 11.87]       12850.4       1222.6 ns
Base64DecodeMime/spaced8-73727          base/final  10.53  [9.14, 10.76]      202926.5      19273.9 ns
Base64DecodeMime/spaced16-69631         base/final  10.75  [10.45, 14.12]      197103.9      18533.6 ns
```

AVX-512: none beyond 10%; geomean 1.000.

Before the rebase, against `main` (Zig 0.16), no base64 row of `all13` was slower beyond 10% in any build; geomean 1.035 (AVX2), 1.025 (SSE), 1.045 (AVX-512).

## Rows beyond 10%, `join` on AVX-512

`base` ÷ `join`, 881 rows, the first 30 of 69:

```
ValidUtf16beToLatin1/ascii-4096         base/join   0.57  [0.50, 0.60]          62.7        108.7 ns
ValidUtf16beToLatin1/latin1-4096        base/join   0.58  [0.53, 0.61]          63.3        109.5 ns
ValidUtf16leToLatin1/ascii-4096         base/join   0.59  [0.58, 0.76]          62.8        106.4 ns
ValidUtf16leToLatin1/latin1-4096        base/join   0.60  [0.59, 0.85]          62.6        104.6 ns
ValidUtf32ToUtf16be/ascii-4096          base/join   0.65  [0.63, 0.66]         186.3        287.7 ns
Utf16beToLatin1/ascii-4096              base/join   0.67  [0.65, 0.71]         111.1        162.1 ns
Utf16leToLatin1/ascii-4096              base/join   0.67  [0.65, 0.68]          84.8        127.6 ns
Utf16beToLatin1/latin1-4096             base/join   0.68  [0.63, 0.79]         111.9        163.0 ns
Utf16leToLatin1/latin1-4096             base/join   0.69  [0.67, 0.72]          86.0        124.0 ns
Utf32ToUtf16be/ascii-4096               base/join   0.71  [0.64, 0.72]         279.8        401.9 ns
Utf32ToUtf16be/hindi                    base/join   0.72  [0.70, 0.74]        2441.7       3390.2 ns
Utf32ToUtf16be/chinese                  base/join   0.73  [0.71, 0.77]        1815.8       2495.0 ns
Utf32ToUtf16be/russian                  base/join   0.73  [0.69, 0.85]        4352.6       6126.5 ns
Utf32ToUtf16be/latin                    base/join   0.74  [0.71, 0.76]        6558.8       8946.3 ns
Utf32ToUtf16be/ascii-65536              base/join   0.74  [0.66, 0.85]        5181.5       7025.6 ns
Utf32ToUtf16be/hebrew                   base/join   0.74  [0.71, 0.77]        2812.6       3874.1 ns
ValidUtf16beToLatin1/latin1-256         base/join   0.74  [0.68, 0.76]           6.9          9.3 ns
Utf32ToUtf16be/korean                   base/join   0.74  [0.70, 0.79]        2078.4       2755.9 ns
Utf32ToUtf16le/ascii-4096               base/join   0.75  [0.72, 0.78]         272.9        363.8 ns
Utf32ToUtf16be/arabic                   base/join   0.75  [0.72, 0.78]        3554.9       4747.5 ns
Utf32ToUtf16be/japanese                 base/join   0.75  [0.73, 0.79]        1788.8       2401.3 ns
Utf32ToUtf16le/ascii-65536              base/join   0.77  [0.74, 0.78]        4874.9       6350.6 ns
Utf32ToUtf16le/latin                    base/join   0.78  [0.77, 0.91]        6518.9       8477.7 ns
Utf32ToUtf16le/hebrew                   base/join   0.78  [0.74, 0.95]        2778.5       3590.7 ns
Utf32ToUtf16le/arabic                   base/join   0.79  [0.77, 0.87]        3478.0       4301.9 ns
Utf32ToUtf16le/hindi                    base/join   0.79  [0.76, 0.87]        2394.3       3051.3 ns
Utf32ToUtf16le/russian                  base/join   0.79  [0.78, 0.83]        4300.8       5476.8 ns
Utf32ToUtf16le/korean                   base/join   0.79  [0.78, 0.81]        2046.3       2575.2 ns
ValidUtf32ToUtf16le/ascii-4096          base/join   0.79  [0.76, 0.86]         206.5        254.7 ns
Utf32ToUtf16le/japanese                 base/join   0.80  [0.77, 0.82]        1785.8       2243.6 ns
```

## Correctness

`zig build test` with Zig 0.17.0 passes in Debug and ReleaseSafe native (every tier the CPU has), ReleaseSafe with `-Dcpu=x86_64_v3`, `x86_64_v2`, and `baseline`, Debug with `-Dcpu=x86_64_v3`, and under qemu-user 11.1.2 in Debug and ReleaseSafe on aarch64. On aarch64_be (ReleaseSafe, qemu) four `simd.zig` tests fail, `bitmask puts lane i in bit i`, `loadPartial copies every short length and zero-pads`, and both `storePartial` tests, the same four on `base` without this change, while `main` with Zig 0.16 passes all: a Zig 0.17 regression of its own, not looked at here.
