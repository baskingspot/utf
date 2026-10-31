# Final baseline, 2026-10-31

Every operation (66) and every arm at every configuration, on `d2d515e` (wave 3 complete) with the harness rebuilt so its numbers hold from run to run. This is the table to quote. Two parts: what was wrong with the harness and how much noise is left, then the baseline.

- Machine: Amp orb, KVM guest, Intel Xeon @ 2.60GHz (Ice Lake server, family 6 model 106, AVX-512 with VBMI2), 2 cores × 2 threads; every timed process pinned to CPU 3, the driver to CPU 0, nothing else running.
- Package: `d2d515e` (`src/` unchanged on this branch). simdutf 9.2.1 (nixpkgs), Zig 0.16.0, Rust 1.99.0 (`simdutf8` 0.1.5, `encoding_rs` 0.8.44, `base64-simd` 0.8.0), Go 1.26.10.
- Levels, each `just bench-compare 10` over all 66 operations (877 rows for utf and simdutf, 156 for std, 248 for Rust, 141 for Go), 10 rounds of 50 ms samples after a sizing round:

| level       | `just` variables                               | utf                                            | simdutf                  | std, Rust, Go                                           |
| ----------- | ---------------------------------------------- | ---------------------------------------------- | ------------------------ | ------------------------------------------------------- |
| icelake     | (defaults)                                     | native, AVX-512                                | `icelake`                | native; Rust `target-cpu=native`; Go `GOAMD64=v4`       |
| haswell     | `cpu=x86_64_v3 dispatch=false kernel=haswell`  | AVX2                                           | `haswell`                | `x86_64_v3`; `x86-64-v3`; `v3`                          |
| westmere    | `cpu=x86_64_v2 dispatch=false kernel=westmere` | SSE4.2                                         | `westmere`               | `x86_64_v2`; `x86-64-v2`, no run-time detection; `v2`   |
| baseline    | `cpu=baseline`                                 | baseline x86-64, dispatching (to AVX-512 here) | runtime pick (`icelake`) | baseline; `x86-64` with run-time detection (AVX2); `v1` |
| ReleaseSafe | `optimize=ReleaseSafe`                         | native, ReleaseSafe                            | `icelake`                | as icelake                                              |

The baseline level is what a distribution ships: a generic build of each library, each picking its kernels at run time.

## Takeaways

utf ÷ each arm, geomean over every row both have, the rows under simdutf beyond their 95% interval, and the rows whose interval holds 1 (too noisy to call):

| level       | simdutf |   std | Rust |    Go | rows under simdutf | cannot call |
| ----------- | ------: | ----: | ---: | ----: | -----------------: | ----------: |
| icelake     |    1.18 | 13.38 | 3.12 | 12.34 |                105 |         279 |
| haswell     |    1.55 | 10.62 | 2.54 |  9.50 |                 41 |         165 |
| westmere    |    1.39 |  7.65 | 2.25 |  7.02 |                 82 |         124 |
| baseline    |    1.13 | 13.74 | 3.08 | 11.87 |                167 |         254 |
| ReleaseSafe |    0.97 |  9.83 | 2.61 | 10.20 |                403 |         183 |

- **Ahead of simdutf at every SIMD level**: 1.18× `icelake`, 1.55× `haswell`, 1.39× `westmere`, and 1.13× in the build distributions ship (baseline x86-64, dispatching to AVX-512, against simdutf's own dispatch). Operations whose geomean is under simdutf: 12 of 66 native (lowest `ValidUtf8ToLatin1` 0.87), 2 on AVX2 (the valid byte swap, 0.99), 2 on SSE (Latin-1 to UTF-16LE, 0.88–0.92), 18 dispatching (lowest 0.83): conversions to and from Latin-1, the valid byte swap, and base64 encode, and when dispatching also ASCII and UTF-32 validation with an error.
- **ReleaseSafe is 18% slower overall** than the ReleaseFast build (0.97 of `icelake` against 1.18), almost all of it in the length and count functions (0.46–0.82, from 1.04–1.55) and ASCII and UTF-32 validation (0.71–0.89); the transcoders and UTF-8 validation stay ahead.
- **std** 7.65–13.74×, **Rust** 2.25–3.12×, **Go** 7.02–12.34× at every level, each built for the same ISA. The rows any of them wins are short (16–64 B, against std's inline scalar loops), Rust's base64 decode at 16–64 B (0.78–0.94), and, in ReleaseSafe only, `simdutf8` on 64 KiB and up.
- **Noise**: each operation's geomean holds to ±2% (median, half its 95% interval over the 10 rounds; at most ±10%); two SSE runs in separate processes 30 minutes apart agree within 2.6% on every operation and read 1.39 overall both times. Rows whose interval holds 1 (124–279 of 877 per level) are within 0.8–1.5% of simdutf at the median and 5–7% at the 90th percentile; they are counted neither under nor ahead.
- **Peak RSS**: utf uses less memory than every arm but std: simdutf +2.8 to +3.4 MiB (libstdc++ and libsimdutf), Rust −0.2 to +1.5, Go +0.2 to +1.5, std −0.6 to −0.1. Nothing allocates in any arm's timed path.

## The harness

Wave 3's orbs found the harness's numbers moving more than the gaps they measured. What was wrong, and what changed (`bench/`, the justfile, [harness.md](../harness.md)):

1. **The host steps, not the process.** In one long-lived process, `bench-utf`'s `Base64Encode/random-4096` read 44 GB/s for a few seconds, then 59, then 44 again, and simdutf's arm did the same at the same times; `setarch -R` (no ASLR) changed nothing. Every arm's throughput steps by up to half for seconds at a time on this shared KVM host, whatever runs. The old recipe ran each arm over every operation in turn, a minute or more apart, so each arm saw a different machine, and 3–6 rounds of that could not average it out. Now each arm is a server (`bench-<arm> serve`, one row per request line), all five pinned to the last core, and the recipe times each row on every arm that has it back to back, in an order that rotates from row to row and round to round: an arm's samples of a row are a fraction of a second from the others'. A row's ratio is the median over the rounds of the ratio within each round (the arms' samples paired), with a 95% interval from the order statistics. Round 0 sizes each loop to `BENCHTIME_MS` (50 ms) and is discarded; every later round runs that many iterations and starts the servers afresh, so each round is a separate process per arm.
2. **Buffer placement.** The Zig arms' inputs came from an arena at whatever offset the files packed to, and their outputs from `page_allocator` at offset 0; simdutf's, Rust's, and Go's from `malloc` and Go's heap. Every arm now reads each input into an anonymous mapping of its own at offset 0 of a page and puts each output in another at offset 2048, so every arm reads the same alignment and no store lands a multiple of 4 KiB from a load just after it (`BENCH_IN_OFFSET` and `BENCH_OUT_OFFSET` move both in every arm alike). UTF-16 and UTF-32 code units are views of those bytes in every arm, not copies. Every page of every mapping is written before timing, the input's outside the input: in a first version, a 4 KiB input ending at a page boundary with a never-touched page after it ran simdutf's `validate_utf16le_with_errors` at 45–48 GB/s where the old harness's heap buffers gave 125–130, and ours at 132–143 against 164–168. A masked load whose masked-off lanes reach an untouched page takes a microcode assist on every call ([simd-wave3-20261031.md](simd-wave3-20261031.md)); callers whose buffers end at a fresh page pay it with either library.
3. **Per-ISA builds.** `cpu` now builds `bench-std` (the standard `-Dcpu`), Rust (`-C target-cpu`: `x86-64-v3`, `x86-64-v2`, `x86-64` for baseline, `native`), and Go (`GOAMD64` v3, v2, v1, and v4 for native on this host) as well as `bench-utf`. Before, the AVX2 and SSE columns compared against AVX-512 Rust and std.
4. **The summary says what it cannot call.** `bench/summary.awk` reports, per operation against simdutf, the spread of the operation's geomean over the rounds (`±`), the rows slower beyond their interval (`<1`), and the rows whose interval holds 1 (`~`); `rows.txt` has every row against every arm with its interval.

The loops cost the same in every arm. Each arm's timed loop around an out-of-line call to a function that returns at once ([loop/](baseline-final-20261031/loop/), 50 million calls, 5 runs, median): C++ calling into a shared library, as the simdutf arm calls libsimdutf, 1.41 ns; Zig with testingx's `b.loop()` and `@call(.never_inline, ...)` 1.25 ns; Rust through a `black_box`ed function pointer 1.24 ns; Go's `testing.B.Loop` and a function value 1.33 ns. So the 16- and 64-byte rows are not skewed against any arm by its loop.

What it cannot fix: code layout. Identical `utf8FromUtf16le` code at two addresses read 1.05× and 1.19× in wave 3 ([convert-wave3-20261031.md](convert-wave3-20261031.md)). Zig has no function-alignment flag, and the package's code is not the harness's to pad. A run measures one build's layout, and its intervals do not include layout: a row whose gap is under about 15% may move across 1.0 in another build of the same code.

### How much the noise dropped

Measured before the page fix above, which changes the level of the page-multiple rows but not how much a row moves between runs. Eleven operations (UTF-8 and UTF-16 validation, UTF-8 to UTF-16, UTF-16 to UTF-8, the valid byte swap, UTF-32 to Latin-1, Latin-1 to UTF-8, `utf8FromUtf16le`, `countUtf8`, base64 encode and decode; 143 rows), native against `icelake`, with the old harness (`d2d515e`, 3 rounds of 100 ms) and the new one (6 rounds of 50 ms), four separate invocations of each, alternating old and new, 217–254 s each ([noise/](baseline-final-20261031/noise/), [noisecmp.py](baseline-final-20261031/noisecmp.py)). Spread is (max − min) ÷ median over the four invocations.

| over four invocations                         | old harness | new harness |
| --------------------------------------------- | ----------: | ----------: |
| utf ÷ simdutf per row, median spread          |       31.7% |        3.9% |
| utf ÷ simdutf per row, 90th percentile        |       50.6% |       11.9% |
| utf ÷ simdutf per row, worst                  |       68.0% |       19.1% |
| utf ÷ simdutf per operation (geomean), median |       25.0% |        1.5% |
| utf ÷ simdutf per operation (geomean), worst  |       47.1% |        3.2% |
| utf ÷ std, Rust, Go per operation, worst      |      31–41% |    4.9–5.3% |
| each arm's own GB/s per row, median spread    |      19–24% |      17–20% |

The arms' own throughput moves as much as before: that is the host, and no harness changes it. The ratios stopped moving because the arms now see the same host. The pairing is most of it: the new data with the old estimator (ratio of medians) spreads 12.8% per row and up to 10% per operation.

Per operation, utf ÷ simdutf in each invocation (the new harness's levels here are before the page fix; `ValidateUtf16leErr` and the other operations with 4 KiB–1 MiB inputs read differently in the baseline below):

```
                         old (4 invocations)          new (4 invocations)
Base64Decode             0.91 1.20 1.20 1.47          1.15 1.17 1.18 1.18
Base64Encode             0.85 1.05 1.22 1.26          1.11 1.11 1.13 1.11
CountUtf8                1.32 1.50 1.72 1.69          1.57 1.52 1.54 1.56
Latin1ToUtf8             0.87 0.94 0.82 0.99          0.90 0.91 0.89 0.90
Utf16leToUtf8            1.25 1.06 1.28 1.19          1.36 1.37 1.37 1.34
Utf32ToLatin1            1.10 0.85 0.97 1.27          1.03 1.02 1.04 1.03
Utf8FromUtf16le          1.17 1.11 1.30 1.43          1.07 1.10 1.08 1.09
Utf8ToUtf16le            1.21 1.20 1.17 1.05          1.23 1.23 1.22 1.22
ValidUtf16leToUtf16be    1.27 0.92 1.09 1.18          0.96 0.97 0.96 0.95
ValidateUtf16leErr       1.05 1.05 0.97 1.02          1.21 1.22 1.22 1.20
ValidateUtf8             1.43 1.42 1.30 1.19          1.36 1.36 1.35 1.35
```

## Per operation against simdutf

utf ÷ simdutf, geomean of the operation's rows, at each level; `(n<)` is how many of its rows are under 1.0 beyond their interval.

| op                    |   icelake |   haswell |   westmere |  baseline | ReleaseSafe |
| --------------------- | --------: | --------: | ---------: | --------: | ----------: |
| ValidateAscii         |      1.14 |      1.60 |  1.47 (1<) | 1.02 (1<) |   0.80 (4<) |
| ValidateAsciiErr      | 1.01 (2<) |      2.21 |       2.10 | 0.87 (4<) |   0.71 (6<) |
| ValidateUtf8          |      1.34 |      1.31 |       1.26 | 1.32 (2<) |   1.17 (1<) |
| ValidateUtf8Err       |      2.89 |      2.36 |       1.25 |      2.78 |        2.41 |
| ValidateUtf16le       | 1.08 (2<) |      4.04 |       1.66 | 1.04 (3<) |  0.95 (11<) |
| ValidateUtf16leErr    | 1.16 (1<) |      4.01 |       1.54 | 1.10 (2<) |   1.00 (5<) |
| ValidateUtf16be       | 1.25 (1<) |      3.83 |  1.35 (1<) | 1.21 (3<) |   1.10 (2<) |
| ValidateUtf16beErr    | 1.28 (1<) |      3.74 |  1.27 (1<) | 1.24 (2<) |   1.12 (1<) |
| ValidateUtf32         |      1.18 |      1.23 |       1.37 | 1.13 (1<) |  0.89 (10<) |
| ValidateUtf32Err      |      1.00 |      3.59 |       4.07 | 0.95 (5<) |  0.80 (12<) |
| Utf8ToUtf16le         | 1.23 (1<) |      1.76 |       1.48 |      1.20 |   1.15 (3<) |
| ValidUtf8ToUtf16le    | 1.32 (2<) | 1.47 (1<) |       1.38 | 1.28 (2<) |   1.24 (4<) |
| Utf8ToUtf16be         |      1.26 |      1.79 |       1.54 |      1.24 |   1.18 (2<) |
| ValidUtf8ToUtf16be    | 1.35 (2<) | 1.48 (1<) |       1.43 | 1.32 (2<) |   1.29 (3<) |
| Utf8ToUtf32           |      1.51 |      1.62 |       1.37 | 1.45 (1<) |   1.40 (3<) |
| ValidUtf8ToUtf32      | 1.14 (1<) | 1.41 (1<) |       1.26 | 1.13 (3<) |   1.09 (5<) |
| Utf8ToLatin1          | 0.98 (4<) |      2.38 |       1.73 | 0.92 (6<) |  0.82 (10<) |
| ValidUtf8ToLatin1     | 0.87 (7<) | 1.52 (1<) |  1.62 (1<) | 0.83 (8<) |  0.71 (11<) |
| Utf16leToUtf8         | 1.31 (1<) |      1.47 |       1.47 | 1.26 (2<) |   1.18 (4<) |
| ValidUtf16leToUtf8    | 1.29 (2<) |      1.45 |  1.42 (1<) | 1.28 (1<) |   1.16 (3<) |
| Utf16leToUtf16be      |      1.41 |      2.74 |       1.65 |      1.38 |   1.01 (3<) |
| ValidUtf16leToUtf16be | 0.94 (4<) | 0.99 (1<) |  1.01 (2<) | 0.93 (4<) |   0.83 (9<) |
| Utf16leToUtf32        | 1.07 (2<) | 1.19 (4<) |       1.34 | 1.06 (2<) |   1.00 (8<) |
| ValidUtf16leToUtf32   |      1.08 | 1.20 (1<) |       1.32 | 1.07 (2<) |   0.99 (7<) |
| Utf16leToLatin1       | 0.94 (4<) | 1.69 (1<) |       1.71 | 0.87 (5<) |  0.78 (11<) |
| ValidUtf16leToLatin1  | 1.13 (2<) |      1.27 |       2.11 | 1.05 (2<) |   0.90 (7<) |
| Utf16beToUtf8         | 1.27 (1<) | 1.47 (1<) |       1.45 | 1.26 (1<) |   1.15 (3<) |
| ValidUtf16beToUtf8    |      1.30 |      1.44 |       1.42 | 1.27 (1<) |   1.18 (3<) |
| Utf16beToUtf16le      |      1.37 |      2.89 |       1.72 |      1.42 |   1.06 (1<) |
| ValidUtf16beToUtf16le | 0.93 (4<) | 0.99 (2<) |  1.01 (2<) | 0.94 (3<) |   0.84 (6<) |
| Utf16beToUtf32        | 1.10 (1<) | 1.07 (3<) |       1.23 | 1.08 (2<) |   1.03 (9<) |
| ValidUtf16beToUtf32   | 1.10 (1<) |      1.11 |       1.36 | 1.09 (2<) |   1.03 (8<) |
| Utf16beToLatin1       | 0.96 (3<) |      1.68 |  1.50 (2<) | 0.90 (8<) |  0.80 (10<) |
| ValidUtf16beToLatin1  | 1.18 (2<) |      1.38 |       2.13 | 1.09 (2<) |   0.94 (6<) |
| Utf32ToUtf8           |      1.81 |      1.30 |       1.50 |      1.76 |        1.59 |
| ValidUtf32ToUtf8      |      1.94 |      1.38 |       1.53 |      1.88 |        1.71 |
| Utf32ToUtf16le        | 1.11 (1<) |      1.33 |  1.09 (9<) | 1.11 (2<) |   0.96 (4<) |
| ValidUtf32ToUtf16le   | 1.27 (1<) |      1.98 |       1.88 | 1.22 (1<) |   1.07 (2<) |
| Utf32ToUtf16be        | 1.23 (1<) |      1.44 |  1.00 (9<) | 1.19 (2<) |   1.05 (3<) |
| ValidUtf32ToUtf16be   | 1.46 (1<) |      1.95 |       1.75 | 1.43 (1<) |   1.26 (2<) |
| Utf32ToLatin1         | 1.01 (4<) |      1.29 |       1.16 | 0.95 (6<) |   0.93 (6<) |
| ValidUtf32ToLatin1    | 1.12 (2<) |      1.41 |       1.42 | 1.06 (2<) |   1.02 (2<) |
| Latin1ToUtf8          | 0.90 (6<) |      1.70 |       1.45 | 0.85 (9<) |  0.79 (10<) |
| ValidLatin1ToUtf8     | 0.90 (7<) |      1.69 |       1.44 | 0.87 (8<) |  0.80 (11<) |
| Latin1ToUtf16le       | 0.97 (4<) | 1.01 (4<) | 0.88 (11<) | 0.88 (4<) |   0.89 (8<) |
| ValidLatin1ToUtf16le  | 0.99 (3<) | 1.06 (4<) | 0.92 (10<) | 0.91 (4<) |   0.90 (6<) |
| Latin1ToUtf16be       | 0.97 (3<) | 1.00 (4<) |  1.05 (3<) | 0.88 (6<) |   0.88 (8<) |
| ValidLatin1ToUtf16be  | 1.00 (2<) | 1.05 (2<) |  1.09 (4<) | 0.91 (6<) |   0.91 (8<) |
| Latin1ToUtf32         | 1.08 (2<) | 1.06 (2<) |  1.04 (4<) | 0.96 (3<) |   1.02 (4<) |
| ValidLatin1ToUtf32    | 1.10 (1<) | 1.12 (2<) |  1.07 (3<) | 1.00 (4<) |   1.02 (3<) |
| Utf16FromUtf8         | 1.17 (1<) |      1.30 |       1.34 | 1.13 (1<) |  0.61 (13<) |
| Utf16FromUtf32        |      1.06 | 1.66 (1<) |  1.76 (1<) | 1.01 (2<) |  0.46 (14<) |
| Utf8FromUtf16le       | 1.07 (3<) |      1.01 |  1.02 (3<) | 1.05 (1<) |  0.65 (13<) |
| Utf8FromUtf16be       | 1.06 (5<) |      1.14 |       1.17 | 1.03 (8<) |  0.82 (14<) |
| Utf8FromUtf32         |      1.30 |      1.09 |  1.07 (1<) |      1.26 |  0.80 (13<) |
| Utf8FromLatin1        | 1.22 (2<) | 1.04 (2<) |  1.00 (4<) | 1.11 (4<) |  0.67 (11<) |
| CountUtf8             |      1.55 |      1.21 |  1.23 (1<) |      1.49 |  0.67 (12<) |
| CountUtf16le          | 1.04 (1<) | 1.94 (1<) |       2.28 | 1.00 (2<) |  0.64 (15<) |
| CountUtf16be          |      1.23 |      2.03 |       2.29 | 1.20 (2<) |  0.77 (14<) |
| Base64Encode          | 1.00 (1<) |      1.23 |  1.05 (1<) | 0.90 (2<) |   0.82 (4<) |
| Base64EncodeUrl       | 0.97 (2<) |      1.23 |  1.05 (1<) | 0.91 (2<) |   0.83 (4<) |
| Base64Decode          |      1.17 | 1.30 (1<) |  1.16 (1<) | 1.11 (1<) |   1.07 (1<) |
| Base64DecodeUrl       | 1.16 (1<) | 1.26 (1<) |  1.09 (3<) |      1.11 |   1.08 (1<) |
| Base64DecodeStrict    |      1.17 |      1.28 |  1.12 (1<) | 1.10 (1<) |   1.06 (1<) |
| Base64DecodePartial   |      1.20 |      1.32 |  1.17 (1<) |      1.14 |   1.11 (1<) |
| Base64DecodeMime      |      1.12 |      1.34 |       1.31 | 1.04 (1<) |   0.92 (4<) |
| all                   |      1.18 |      1.55 |       1.39 |      1.13 |        0.97 |

## Per level, against every arm

The summary `just bench-compare` printed, as a table: utf's geomean GB/s, utf ÷ each arm, the spread of the geomean against simdutf over the rounds (`±`), the rows under simdutf beyond their interval (`<1`), the rows whose interval holds 1 (`~`), and the slowest row against simdutf with its interval.

### icelake

| op                    | rows | utf GB/s |  simdutf |       std |     rust |        go |   ± |  <1 |   ~ | slowest vs simdutf              |
| --------------------- | ---: | -------: | -------: | --------: | -------: | --------: | --: | --: | --: | ------------------------------- |
| ValidateAscii         |    7 |    68.97 |     1.14 |         - |     2.07 |         - |  3% |   0 |   2 | 1.05 [0.90, 1.11] latin         |
| ValidateAsciiErr      |    7 |    63.22 |     1.01 |         - |     1.90 |         - |  8% |   2 |   3 | 0.91 [0.83, 0.93] ascii-4096    |
| ValidateUtf8          |   15 |    35.44 |     1.34 |      6.85 |     1.52 |      8.66 |  2% |   0 |   3 | 1.00 [1.00, 1.02] ascii-16      |
| ValidateUtf8Err       |   15 |    30.51 |     2.89 |      7.20 |     1.60 |      7.58 |  3% |   0 |   0 | 1.29 [1.28, 1.44] emoji         |
| ValidateUtf16le       |   15 |    84.97 |     1.08 |         - |     8.26 |         - |  2% |   2 |   8 | 0.85 [0.77, 0.86] ascii-256     |
| ValidateUtf16leErr    |   15 |    82.92 |     1.16 |         - |     8.24 |         - |  5% |   1 |   2 | 0.80 [0.65, 0.83] ascii-256     |
| ValidateUtf16be       |   15 |    79.14 |     1.25 |         - |        - |         - |  3% |   1 |   1 | 0.89 [0.86, 0.96] ascii-256     |
| ValidateUtf16beErr    |   15 |    74.63 |     1.28 |         - |        - |         - |  2% |   1 |   0 | 0.96 [0.92, 0.99] ascii-256     |
| ValidateUtf32         |   15 |    79.19 |     1.18 |         - |        - |         - |  4% |   0 |   5 | 1.00 [0.97, 1.07] ascii-1048576 |
| ValidateUtf32Err      |   15 |    79.16 |     1.00 |         - |        - |         - |  3% |   0 |  14 | 0.99 [0.91, 1.03] latin         |
| Utf8ToUtf16le         |   15 |     8.62 |     1.23 |      6.09 |     3.29 |     14.71 |  4% |   1 |   4 | 0.96 [0.82, 1.05] hebrew        |
| ValidUtf8ToUtf16le    |   15 |     9.56 |     1.32 |         - |     2.89 |         - |  2% |   2 |   4 | 0.79 [0.61, 0.82] ascii-256     |
| Utf8ToUtf16be         |   15 |     9.18 |     1.26 |         - |        - |         - |  2% |   0 |   4 | 1.00 [0.96, 1.01] arabic        |
| ValidUtf8ToUtf16be    |   15 |     8.81 |     1.35 |         - |        - |         - |  1% |   2 |   4 | 0.80 [0.80, 0.81] ascii-256     |
| Utf8ToUtf32           |   15 |     6.91 |     1.51 |         - |        - |      9.15 |  2% |   0 |   3 | 0.99 [0.92, 1.01] ascii-1048576 |
| ValidUtf8ToUtf32      |   15 |     8.15 |     1.14 |         - |        - |         - |  1% |   1 |   5 | 0.78 [0.74, 1.02] ascii-256     |
| Utf8ToLatin1          |   13 |    15.58 |     0.98 |         - |        - |         - |  2% |   4 |   4 | 0.62 [0.60, 0.64] latin1-64     |
| ValidUtf8ToLatin1     |   13 |    18.42 |     0.87 |         - |     5.30 |         - |  3% |   7 |   5 | 0.60 [0.57, 0.62] latin1-16     |
| Utf16leToUtf8         |   15 |    19.60 |     1.31 |      5.71 |     5.53 |     16.75 |  1% |   1 |   1 | 0.97 [0.94, 0.99] latin         |
| ValidUtf16leToUtf8    |   15 |    18.22 |     1.29 |         - |        - |         - |  3% |   2 |   2 | 0.95 [0.91, 0.98] ascii-64      |
| Utf16leToUtf16be      |   15 |    31.66 |     1.41 |         - |        - |         - |  3% |   0 |   0 | 1.07 [1.05, 1.10] ascii-4096    |
| ValidUtf16leToUtf16be |   15 |    38.84 |     0.94 |         - |        - |         - |  1% |   4 |  11 | 0.60 [0.59, 0.62] ascii-16      |
| Utf16leToUtf32        |   15 |    20.86 |     1.07 |         - |        - |         - |  2% |   2 |  10 | 0.86 [0.85, 0.90] ascii-64      |
| ValidUtf16leToUtf32   |   15 |    20.94 |     1.08 |         - |        - |         - |  1% |   0 |  12 | 0.90 [0.83, 1.00] ascii-64      |
| Utf16leToLatin1       |   13 |    32.19 |     0.94 |         - |        - |         - |  2% |   4 |   8 | 0.67 [0.65, 0.68] latin1-16     |
| ValidUtf16leToLatin1  |   13 |    36.51 |     1.13 |         - |     2.00 |         - |  2% |   2 |   2 | 0.67 [0.66, 0.68] ascii-16      |
| Utf16beToUtf8         |   15 |    18.05 |     1.27 |         - |        - |         - |  2% |   1 |   3 | 0.93 [0.92, 0.96] ascii-64      |
| ValidUtf16beToUtf8    |   15 |    18.44 |     1.30 |         - |        - |         - |  4% |   0 |   3 | 1.01 [0.94, 1.06] ascii-1048576 |
| Utf16beToUtf16le      |   15 |    31.79 |     1.37 |         - |        - |         - |  2% |   0 |   0 | 1.14 [1.13, 1.18] ascii-4096    |
| ValidUtf16beToUtf16le |   15 |    39.10 |     0.93 |         - |        - |         - |  2% |   4 |  10 | 0.59 [0.59, 0.67] ascii-16      |
| Utf16beToUtf32        |   15 |    21.03 |     1.10 |         - |        - |         - |  2% |   1 |  11 | 0.92 [0.87, 0.96] ascii-64      |
| ValidUtf16beToUtf32   |   15 |    21.32 |     1.10 |         - |        - |         - |  1% |   1 |   9 | 0.92 [0.89, 0.93] ascii-64      |
| Utf16beToLatin1       |   13 |    33.20 |     0.96 |         - |        - |         - |  2% |   3 |   8 | 0.74 [0.72, 0.77] latin1-16     |
| ValidUtf16beToLatin1  |   13 |    37.25 |     1.18 |         - |        - |         - |  1% |   2 |   4 | 0.69 [0.68, 0.76] latin1-16     |
| Utf32ToUtf8           |   15 |    27.96 |     1.81 |         - |        - |     11.61 |  3% |   0 |   0 | 1.26 [1.24, 1.30] ascii-1048576 |
| ValidUtf32ToUtf8      |   15 |    28.34 |     1.94 |         - |        - |         - |  3% |   0 |   0 | 1.13 [1.02, 1.16] ascii-1048576 |
| Utf32ToUtf16le        |   15 |    40.60 |     1.11 |         - |        - |         - |  2% |   1 |   2 | 0.82 [0.75, 0.88] ascii-16      |
| ValidUtf32ToUtf16le   |   15 |    46.48 |     1.27 |         - |        - |         - |  1% |   1 |   1 | 0.87 [0.85, 0.92] ascii-16      |
| Utf32ToUtf16be        |   15 |    42.09 |     1.23 |         - |        - |         - |  2% |   1 |   2 | 0.81 [0.81, 0.89] ascii-16      |
| ValidUtf32ToUtf16be   |   15 |    47.35 |     1.46 |         - |        - |         - |  1% |   1 |   1 | 0.80 [0.70, 0.99] ascii-16      |
| Utf32ToLatin1         |   13 |    45.84 |     1.01 |         - |        - |         - |  3% |   4 |   4 | 0.88 [0.86, 0.89] latin1-16     |
| ValidUtf32ToLatin1    |   13 |    56.83 |     1.12 |         - |        - |         - |  3% |   2 |   2 | 0.85 [0.82, 0.93] latin1-16     |
| Latin1ToUtf8          |   13 |    15.50 |     0.90 |         - |     4.70 |         - |  2% |   6 |   6 | 0.74 [0.72, 0.76] latin1-64     |
| ValidLatin1ToUtf8     |   13 |    15.32 |     0.90 |         - |     4.67 |         - |  4% |   7 |   5 | 0.72 [0.69, 0.74] latin1-64     |
| Latin1ToUtf16le       |   13 |    19.11 |     0.97 |         - |     2.02 |         - |  2% |   4 |   5 | 0.77 [0.71, 0.82] ascii-16      |
| ValidLatin1ToUtf16le  |   13 |    18.34 |     0.99 |         - |     2.03 |         - |  2% |   3 |   6 | 0.84 [0.81, 0.86] latin1-16     |
| Latin1ToUtf16be       |   13 |    16.73 |     0.97 |         - |        - |         - |  1% |   3 |   7 | 0.80 [0.79, 0.83] ascii-16      |
| ValidLatin1ToUtf16be  |   13 |    17.91 |     1.00 |         - |        - |         - |  2% |   2 |   8 | 0.84 [0.83, 0.86] ascii-16      |
| Latin1ToUtf32         |   13 |    12.22 |     1.08 |         - |        - |         - |  3% |   2 |   5 | 0.89 [0.84, 0.90] ascii-16      |
| ValidLatin1ToUtf32    |   13 |    12.56 |     1.10 |         - |        - |         - |  1% |   1 |   3 | 0.98 [0.89, 1.00] ascii-16      |
| Utf16FromUtf8         |   15 |    53.86 |     1.17 |    307.12 |        - |         - |  2% |   1 |   4 | 0.96 [0.91, 1.00] ascii-4096    |
| Utf16FromUtf32        |   15 |    80.24 |     1.06 |         - |        - |         - |  2% |   0 |   4 | 1.01 [0.98, 1.02] ascii-1048576 |
| Utf8FromUtf16le       |   15 |    43.05 |     1.07 |     27.41 |        - |         - |  3% |   3 |   9 | 0.93 [0.89, 1.14] ascii-1048576 |
| Utf8FromUtf16be       |   15 |    36.83 |     1.06 |         - |        - |         - |  2% |   5 |   8 | 0.90 [0.79, 0.92] ascii-65536   |
| Utf8FromUtf32         |   15 |    50.04 |     1.30 |         - |        - |         - |  2% |   0 |   1 | 0.95 [0.89, 1.00] ascii-1048576 |
| Utf8FromLatin1        |   13 |    42.47 |     1.22 |         - |        - |         - |  2% |   2 |   3 | 0.81 [0.78, 0.82] ascii-4096    |
| CountUtf8             |   15 |    74.39 |     1.55 |     39.18 |     2.63 |     51.04 |  3% |   0 |   0 | 1.39 [1.36, 1.43] ascii-64      |
| CountUtf16le          |   15 |    66.20 |     1.04 |     14.90 |        - |         - |  3% |   1 |   8 | 0.89 [0.83, 0.90] ascii-16      |
| CountUtf16be          |   15 |    62.62 |     1.23 |         - |        - |         - |  3% |   0 |   3 | 0.91 [0.88, 1.13] ascii-16      |
| Base64Encode          |    6 |    14.72 |     1.00 |      5.56 |     2.31 |     11.26 |  5% |   1 |   4 | 0.82 [0.81, 0.86] random-16     |
| Base64EncodeUrl       |    6 |    14.38 |     0.97 |      5.25 |     2.22 |     10.98 |  2% |   2 |   2 | 0.75 [0.61, 0.78] random-16     |
| Base64Decode          |    6 |    13.79 |     1.17 |      3.74 |     2.02 |      9.50 |  4% |   0 |   2 | 0.99 [0.93, 1.02] random-4096   |
| Base64DecodeUrl       |    6 |    13.19 |     1.16 |      3.70 |     2.03 |      8.24 |  2% |   1 |   2 | 0.96 [0.94, 0.98] random-4096   |
| Base64DecodeStrict    |    6 |    12.85 |     1.17 |      3.74 |     1.97 |      9.13 |  7% |   0 |   2 | 1.00 [0.98, 1.08] random-4096   |
| Base64DecodePartial   |    6 |    13.96 |     1.20 |         - |        - |         - |  2% |   0 |   2 | 1.00 [0.98, 1.02] random-4096   |
| Base64DecodeMime      |    6 |     9.73 |     1.12 |     19.54 |     6.17 |      7.02 |  3% |   0 |   3 | 0.95 [0.94, 1.02] random-256    |
| **all**               |  877 |    28.49 | **1.18** | **13.38** | **3.12** | **12.34** |     | 105 | 279 |                                 |

### haswell

| op                    | rows | utf GB/s |  simdutf |       std |     rust |       go |   ± |  <1 |   ~ | slowest vs simdutf               |
| --------------------- | ---: | -------: | -------: | --------: | -------: | -------: | --: | --: | --: | -------------------------------- |
| ValidateAscii         |    7 |    56.00 |     1.60 |         - |     1.74 |        - |  4% |   0 |   1 | 1.08 [0.97, 1.40] ascii-1048576  |
| ValidateAsciiErr      |    7 |    56.64 |     2.21 |         - |     1.68 |        - |  2% |   0 |   0 | 1.09 [1.08, 1.22] ascii-1048576  |
| ValidateUtf8          |   15 |    28.39 |     1.31 |      5.39 |     1.26 |     6.89 |  3% |   0 |   2 | 1.05 [0.87, 1.10] japanese       |
| ValidateUtf8Err       |   15 |    22.68 |     2.36 |      5.34 |     1.27 |     5.66 |  3% |   0 |   1 | 1.09 [1.04, 1.10] emoji          |
| ValidateUtf16le       |   15 |    61.94 |     4.04 |         - |     6.34 |        - |  2% |   0 |   0 | 2.33 [2.30, 2.77] ascii-16       |
| ValidateUtf16leErr    |   15 |    61.10 |     4.01 |         - |     6.37 |        - |  3% |   0 |   0 | 2.36 [2.29, 2.39] emoji          |
| ValidateUtf16be       |   15 |    57.69 |     3.83 |         - |        - |        - |  2% |   0 |   0 | 2.01 [1.97, 2.69] emoji          |
| ValidateUtf16beErr    |   15 |    57.82 |     3.74 |         - |        - |        - |  3% |   0 |   0 | 2.00 [1.96, 2.06] emoji          |
| ValidateUtf32         |   15 |    68.18 |     1.23 |         - |        - |        - |  2% |   0 |   1 | 1.02 [1.01, 1.04] ascii-1048576  |
| ValidateUtf32Err      |   15 |    59.89 |     3.59 |         - |        - |        - |  2% |   0 |   0 | 1.51 [1.48, 1.55] ascii-64       |
| Utf8ToUtf16le         |   15 |     7.25 |     1.76 |      4.92 |     2.59 |    11.50 |  3% |   0 |   1 | 0.99 [0.97, 1.03] ascii-1048576  |
| ValidUtf8ToUtf16le    |   15 |     8.10 |     1.47 |         - |     2.50 |        - |  2% |   1 |   3 | 0.88 [0.87, 0.88] ascii-4096     |
| Utf8ToUtf16be         |   15 |     7.13 |     1.79 |         - |        - |        - |  2% |   0 |   1 | 1.01 [1.00, 1.06] ascii-1048576  |
| ValidUtf8ToUtf16be    |   15 |     7.77 |     1.48 |         - |        - |        - |  1% |   1 |   2 | 0.89 [0.89, 0.94] ascii-4096     |
| Utf8ToUtf32           |   15 |     5.99 |     1.62 |         - |        - |     7.46 |  3% |   0 |   3 | 0.99 [0.98, 1.00] ascii-1048576  |
| ValidUtf8ToUtf32      |   15 |     7.16 |     1.41 |         - |        - |        - |  1% |   1 |   0 | 0.91 [0.91, 0.93] ascii-4096     |
| Utf8ToLatin1          |   13 |     8.16 |     2.38 |         - |        - |        - |  1% |   0 |   2 | 0.97 [0.93, 1.03] ascii-1048576  |
| ValidUtf8ToLatin1     |   13 |     8.49 |     1.52 |         - |     2.54 |        - |  2% |   1 |   3 | 0.84 [0.83, 0.87] ascii-4096     |
| Utf16leToUtf8         |   15 |    16.13 |     1.47 |      5.22 |     4.29 |    13.91 |  2% |   0 |   3 | 1.00 [0.82, 1.03] ascii-1048576  |
| ValidUtf16leToUtf8    |   15 |    15.70 |     1.45 |         - |        - |        - |  2% |   0 |   3 | 1.02 [0.95, 1.07] hindi          |
| Utf16leToUtf16be      |   15 |    29.00 |     2.74 |         - |        - |        - |  2% |   0 |   0 | 1.78 [1.54, 1.82] ascii-1048576  |
| ValidUtf16leToUtf16be |   15 |    39.33 |     0.99 |         - |        - |        - |  1% |   1 |  12 | 0.82 [0.81, 1.02] ascii-64       |
| Utf16leToUtf32        |   15 |    20.71 |     1.19 |         - |        - |        - |  1% |   4 |  10 | 0.88 [0.72, 0.89] ascii-4096     |
| ValidUtf16leToUtf32   |   15 |    19.99 |     1.20 |         - |        - |        - |  1% |   1 |  11 | 0.86 [0.84, 0.86] ascii-4096     |
| Utf16leToLatin1       |   13 |    32.08 |     1.69 |         - |        - |        - |  3% |   1 |   2 | 0.92 [0.88, 1.05] ascii-16       |
| ValidUtf16leToLatin1  |   13 |    35.04 |     1.27 |         - |     1.85 |        - |  2% |   0 |   2 | 1.00 [0.92, 1.04] ascii-1048576  |
| Utf16beToUtf8         |   15 |    14.74 |     1.47 |         - |        - |        - |  2% |   1 |   3 | 0.95 [0.93, 0.97] japanese       |
| ValidUtf16beToUtf8    |   15 |    15.57 |     1.44 |         - |        - |        - |  1% |   0 |   2 | 0.99 [0.94, 1.07] hindi          |
| Utf16beToUtf16le      |   15 |    33.74 |     2.89 |         - |        - |        - |  2% |   0 |   0 | 1.79 [1.63, 1.95] ascii-1048576  |
| ValidUtf16beToUtf16le |   15 |    39.12 |     0.99 |         - |        - |        - |  1% |   2 |  12 | 0.82 [0.79, 0.83] ascii-64       |
| Utf16beToUtf32        |   15 |    19.11 |     1.07 |         - |        - |        - |  3% |   3 |   9 | 0.87 [0.86, 0.89] ascii-4096     |
| ValidUtf16beToUtf32   |   15 |    20.51 |     1.11 |         - |        - |        - |  1% |   0 |   9 | 0.91 [0.86, 1.04] ascii-4096     |
| Utf16beToLatin1       |   13 |    31.45 |     1.68 |         - |        - |        - |  4% |   0 |   0 | 1.15 [1.11, 1.17] ascii-1048576  |
| ValidUtf16beToLatin1  |   13 |    37.07 |     1.38 |         - |        - |        - |  2% |   0 |   2 | 1.00 [0.96, 1.02] ascii-1048576  |
| Utf32ToUtf8           |   15 |    20.83 |     1.30 |         - |        - |     8.19 |  2% |   0 |   3 | 1.05 [0.94, 1.16] ascii-1048576  |
| ValidUtf32ToUtf8      |   15 |    21.13 |     1.38 |         - |        - |        - |  3% |   0 |   0 | 1.05 [1.01, 1.06] ascii-1048576  |
| Utf32ToUtf16le        |   15 |    33.81 |     1.33 |         - |        - |        - |  2% |   0 |   1 | 1.03 [1.00, 1.05] ascii-1048576  |
| ValidUtf32ToUtf16le   |   15 |    50.48 |     1.98 |         - |        - |        - |  1% |   0 |   0 | 1.10 [1.03, 1.16] ascii-1048576  |
| Utf32ToUtf16be        |   15 |    32.09 |     1.44 |         - |        - |        - |  2% |   0 |   1 | 1.03 [0.99, 1.04] ascii-1048576  |
| ValidUtf32ToUtf16be   |   15 |    43.71 |     1.95 |         - |        - |        - |  2% |   0 |   0 | 1.15 [1.05, 1.19] ascii-1048576  |
| Utf32ToLatin1         |   13 |    54.12 |     1.29 |         - |        - |        - |  2% |   0 |   2 | 1.02 [1.00, 1.05] ascii-1048576  |
| ValidUtf32ToLatin1    |   13 |    53.68 |     1.41 |         - |        - |        - |  3% |   0 |   0 | 1.03 [1.00, 1.06] latin1-1048576 |
| Latin1ToUtf8          |   13 |    12.17 |     1.70 |         - |     3.79 |        - |  2% |   0 |   0 | 1.20 [1.03, 1.28] ascii-1048576  |
| ValidLatin1ToUtf8     |   13 |    12.55 |     1.69 |         - |     3.77 |        - |  2% |   0 |   0 | 1.16 [1.09, 1.27] ascii-1048576  |
| Latin1ToUtf16le       |   13 |    17.28 |     1.01 |         - |     1.73 |        - |  3% |   4 |   5 | 0.77 [0.76, 0.88] ascii-16       |
| ValidLatin1ToUtf16le  |   13 |    17.03 |     1.06 |         - |     1.82 |        - |  3% |   4 |   6 | 0.87 [0.80, 0.89] ascii-16       |
| Latin1ToUtf16be       |   13 |    15.95 |     1.00 |         - |        - |        - |  2% |   4 |   4 | 0.82 [0.81, 0.82] latin1-16      |
| ValidLatin1ToUtf16be  |   13 |    16.46 |     1.05 |         - |        - |        - |  1% |   2 |   6 | 0.93 [0.91, 0.94] ascii-16       |
| Latin1ToUtf32         |   13 |    10.46 |     1.06 |         - |        - |        - |  2% |   2 |   4 | 0.82 [0.80, 0.84] latin1-16      |
| ValidLatin1ToUtf32    |   13 |    11.15 |     1.12 |         - |        - |        - |  1% |   2 |   5 | 0.93 [0.89, 0.94] ascii-16       |
| Utf16FromUtf8         |   15 |    45.00 |     1.30 |    236.06 |        - |        - |  1% |   0 |   0 | 1.06 [1.01, 1.08] ascii-64       |
| Utf16FromUtf32        |   15 |    71.44 |     1.66 |         - |        - |        - |  2% |   1 |   0 | 0.82 [0.80, 0.83] ascii-16       |
| Utf8FromUtf16le       |   15 |    32.25 |     1.01 |     19.50 |        - |        - |  2% |   0 |  13 | 0.99 [0.93, 1.03] ascii-64       |
| Utf8FromUtf16be       |   15 |    32.77 |     1.14 |         - |        - |        - |  2% |   0 |   1 | 1.03 [0.83, 1.09] ascii-64       |
| Utf8FromUtf32         |   15 |    35.17 |     1.09 |         - |        - |        - |  1% |   0 |   1 | 1.02 [1.00, 1.06] ascii-1048576  |
| Utf8FromLatin1        |   13 |    37.88 |     1.04 |         - |        - |        - |  2% |   2 |   0 | 0.74 [0.73, 0.75] latin1-64      |
| CountUtf8             |   15 |    70.56 |     1.21 |     37.08 |     3.86 |    48.53 |  2% |   0 |   1 | 1.03 [1.02, 1.27] ascii-256      |
| CountUtf16le          |   15 |    63.48 |     1.94 |     14.75 |        - |        - |  3% |   1 |   0 | 0.86 [0.81, 0.87] ascii-64       |
| CountUtf16be          |   15 |    69.15 |     2.03 |         - |        - |        - |  1% |   0 |   0 | 1.04 [1.03, 1.05] ascii-64       |
| Base64Encode          |    6 |    10.37 |     1.23 |      3.68 |     1.53 |     7.40 |  3% |   0 |   3 | 1.01 [0.98, 1.10] random-1048576 |
| Base64EncodeUrl       |    6 |     9.65 |     1.23 |      3.54 |     1.50 |     7.37 |  3% |   0 |   2 | 1.00 [0.90, 1.03] random-4096    |
| Base64Decode          |    6 |     9.89 |     1.30 |      2.64 |     1.51 |     6.47 |  2% |   1 |   1 | 0.97 [0.81, 0.98] random-65536   |
| Base64DecodeUrl       |    6 |     9.02 |     1.26 |      2.49 |     1.47 |     5.55 |  4% |   1 |   2 | 0.91 [0.82, 0.92] random-65536   |
| Base64DecodeStrict    |    6 |     9.82 |     1.28 |      2.57 |     1.46 |     6.37 |  3% |   0 |   2 | 0.98 [0.85, 1.01] random-65536   |
| Base64DecodePartial   |    6 |     9.76 |     1.32 |         - |        - |        - |  2% |   0 |   2 | 0.98 [0.97, 1.02] random-65536   |
| Base64DecodeMime      |    6 |     6.77 |     1.34 |     14.59 |     4.72 |     5.20 |  3% |   0 |   0 | 1.17 [1.15, 1.26] random-1048576 |
| **all**               |  877 |    24.23 | **1.55** | **10.62** | **2.54** | **9.50** |     |  41 | 165 |                                  |

### westmere

| op                    | rows | utf GB/s |  simdutf |      std |     rust |       go |   ± |  <1 |   ~ | slowest vs simdutf               |
| --------------------- | ---: | -------: | -------: | -------: | -------: | -------: | --: | --: | --: | -------------------------------- |
| ValidateAscii         |    7 |    47.70 |     1.47 |        - |     1.45 |        - |  2% |   1 |   2 | 0.98 [0.91, 0.99] ascii-1048576  |
| ValidateAsciiErr      |    7 |    46.12 |     2.10 |        - |     1.32 |        - |  2% |   0 |   3 | 0.99 [0.89, 1.05] ascii-1048576  |
| ValidateUtf8          |   15 |    19.89 |     1.26 |     4.16 |     1.27 |     4.64 |  2% |   0 |   5 | 0.99 [0.89, 1.01] ascii-1048576  |
| ValidateUtf8Err       |   15 |    14.49 |     1.25 |     3.94 |     1.21 |     3.62 |  2% |   0 |   1 | 1.11 [1.04, 1.12] emoji          |
| ValidateUtf16le       |   15 |    49.75 |     1.66 |        - |     5.03 |        - |  2% |   0 |   0 | 1.13 [1.10, 1.15] emoji          |
| ValidateUtf16leErr    |   15 |    49.18 |     1.54 |        - |     4.79 |        - |  4% |   0 |   0 | 1.11 [1.06, 1.12] emoji          |
| ValidateUtf16be       |   15 |    38.09 |     1.35 |        - |        - |        - |  2% |   1 |   1 | 0.82 [0.81, 0.84] emoji          |
| ValidateUtf16beErr    |   15 |    38.39 |     1.27 |        - |        - |        - |  2% |   1 |   1 | 0.82 [0.80, 0.82] emoji          |
| ValidateUtf32         |   15 |    43.22 |     1.37 |        - |        - |        - |  1% |   0 |   0 | 1.06 [1.04, 1.09] ascii-1048576  |
| ValidateUtf32Err      |   15 |    41.58 |     4.07 |        - |        - |        - |  1% |   0 |   0 | 1.81 [1.78, 1.84] ascii-64       |
| Utf8ToUtf16le         |   15 |     6.29 |     1.48 |     4.98 |     2.17 |    10.00 |  1% |   0 |   2 | 1.03 [0.97, 1.04] latin          |
| ValidUtf8ToUtf16le    |   15 |     7.75 |     1.38 |        - |     2.30 |        - |  2% |   0 |   0 | 1.04 [1.04, 1.13] latin          |
| Utf8ToUtf16be         |   15 |     6.04 |     1.54 |        - |        - |        - |  2% |   0 |   1 | 1.00 [0.96, 1.02] ascii-1048576  |
| ValidUtf8ToUtf16be    |   15 |     7.38 |     1.43 |        - |        - |        - |  2% |   0 |   2 | 1.00 [0.97, 1.21] ascii-1048576  |
| Utf8ToUtf32           |   15 |     5.17 |     1.37 |        - |        - |     6.04 |  1% |   0 |   4 | 0.99 [0.97, 1.04] ascii-4096     |
| ValidUtf8ToUtf32      |   15 |     6.10 |     1.26 |        - |        - |        - |  1% |   0 |   2 | 0.97 [0.89, 1.00] ascii-4096     |
| Utf8ToLatin1          |   13 |     8.84 |     1.73 |        - |        - |        - |  2% |   0 |   2 | 1.04 [0.95, 1.07] ascii-65536    |
| ValidUtf8ToLatin1     |   13 |     9.08 |     1.62 |        - |     2.72 |        - |  2% |   1 |   2 | 0.98 [0.95, 1.01] ascii-65536    |
| Utf16leToUtf8         |   15 |    13.24 |     1.47 |     4.40 |     3.17 |    10.83 |  1% |   0 |   2 | 0.97 [0.90, 1.01] korean         |
| ValidUtf16leToUtf8    |   15 |    12.71 |     1.42 |        - |        - |        - |  2% |   1 |   1 | 0.97 [0.93, 0.99] korean         |
| Utf16leToUtf16be      |   15 |    26.17 |     1.65 |        - |        - |        - |  2% |   0 |   0 | 1.20 [1.14, 1.30] emoji          |
| ValidUtf16leToUtf16be |   15 |    38.20 |     1.01 |        - |        - |        - |  2% |   2 |  10 | 0.89 [0.85, 0.91] ascii-64       |
| Utf16leToUtf32        |   15 |    18.50 |     1.34 |        - |        - |        - |  1% |   0 |   2 | 0.99 [0.99, 1.00] ascii-1048576  |
| ValidUtf16leToUtf32   |   15 |    17.90 |     1.32 |        - |        - |        - |  2% |   0 |   3 | 0.99 [0.95, 1.02] ascii-1048576  |
| Utf16leToLatin1       |   13 |    31.00 |     1.71 |        - |        - |        - |  2% |   0 |   2 | 0.99 [0.94, 1.03] ascii-16       |
| ValidUtf16leToLatin1  |   13 |    35.57 |     2.11 |        - |     1.86 |        - |  2% |   0 |   0 | 1.18 [1.03, 1.21] ascii-1048576  |
| Utf16beToUtf8         |   15 |    12.03 |     1.45 |        - |        - |        - |  2% |   0 |   3 | 0.97 [0.88, 1.01] korean         |
| ValidUtf16beToUtf8    |   15 |    11.90 |     1.42 |        - |        - |        - |  2% |   0 |   3 | 0.97 [0.96, 1.00] korean         |
| Utf16beToUtf16le      |   15 |    26.41 |     1.72 |        - |        - |        - |  1% |   0 |   0 | 1.16 [1.15, 1.18] emoji          |
| ValidUtf16beToUtf16le |   15 |    38.79 |     1.01 |        - |        - |        - |  2% |   2 |  11 | 0.89 [0.88, 0.90] ascii-64       |
| Utf16beToUtf32        |   15 |    18.97 |     1.23 |        - |        - |        - |  2% |   0 |   2 | 1.00 [0.99, 1.12] ascii-1048576  |
| ValidUtf16beToUtf32   |   15 |    18.69 |     1.36 |        - |        - |        - |  1% |   0 |   2 | 0.99 [0.96, 1.01] ascii-1048576  |
| Utf16beToLatin1       |   13 |    25.16 |     1.50 |        - |        - |        - |  2% |   2 |   0 | 0.94 [0.94, 0.98] latin1-16      |
| ValidUtf16beToLatin1  |   13 |    38.33 |     2.13 |        - |        - |        - |  3% |   0 |   0 | 1.24 [1.08, 1.38] latin1-1048576 |
| Utf32ToUtf8           |   15 |    16.08 |     1.50 |        - |        - |     6.66 |  2% |   0 |   1 | 1.06 [0.97, 1.10] japanese       |
| ValidUtf32ToUtf8      |   15 |    17.25 |     1.53 |        - |        - |        - |  2% |   0 |   0 | 1.11 [1.02, 1.16] ascii-1048576  |
| Utf32ToUtf16le        |   15 |    27.12 |     1.09 |        - |        - |        - |  2% |   9 |   3 | 0.93 [0.89, 0.97] japanese       |
| ValidUtf32ToUtf16le   |   15 |    48.28 |     1.88 |        - |        - |        - |  2% |   0 |   0 | 1.11 [1.02, 1.12] ascii-1048576  |
| Utf32ToUtf16be        |   15 |    26.02 |     1.00 |        - |        - |        - |  3% |   9 |   2 | 0.88 [0.78, 0.89] ascii-4096     |
| ValidUtf32ToUtf16be   |   15 |    45.86 |     1.75 |        - |        - |        - |  2% |   0 |   0 | 1.10 [1.04, 1.14] ascii-1048576  |
| Utf32ToLatin1         |   13 |    37.17 |     1.16 |        - |        - |        - |  1% |   0 |   0 | 1.07 [1.05, 1.08] ascii-65536    |
| ValidUtf32ToLatin1    |   13 |    45.81 |     1.42 |        - |        - |        - |  2% |   0 |   0 | 1.16 [1.00, 1.21] ascii-1048576  |
| Latin1ToUtf8          |   13 |    11.92 |     1.45 |        - |     3.54 |        - |  2% |   0 |   2 | 0.98 [0.86, 1.02] ascii-16       |
| ValidLatin1ToUtf8     |   13 |    11.18 |     1.44 |        - |     3.55 |        - |  2% |   0 |   1 | 0.98 [0.93, 1.04] ascii-16       |
| Latin1ToUtf16le       |   13 |    14.76 |     0.88 |        - |     1.48 |        - |  1% |  11 |   2 | 0.80 [0.79, 0.80] latin1-16      |
| ValidLatin1ToUtf16le  |   13 |    15.03 |     0.92 |        - |     1.55 |        - |  3% |  10 |   3 | 0.80 [0.78, 0.81] latin1-4096    |
| Latin1ToUtf16be       |   13 |    14.48 |     1.05 |        - |        - |        - |  2% |   3 |   4 | 0.87 [0.67, 0.94] ascii-16       |
| ValidLatin1ToUtf16be  |   13 |    16.14 |     1.09 |        - |        - |        - |  2% |   4 |   3 | 0.95 [0.95, 0.97] ascii-16       |
| Latin1ToUtf32         |   13 |     9.10 |     1.04 |        - |        - |        - |  2% |   4 |   6 | 0.94 [0.87, 0.97] ascii-16       |
| ValidLatin1ToUtf32    |   13 |     9.32 |     1.07 |        - |        - |        - |  1% |   3 |   5 | 0.95 [0.84, 0.98] ascii-65536    |
| Utf16FromUtf8         |   15 |    26.11 |     1.34 |   139.86 |        - |        - |  2% |   0 |   1 | 1.00 [0.96, 1.02] ascii-16       |
| Utf16FromUtf32        |   15 |    41.75 |     1.76 |        - |        - |        - |  1% |   1 |   0 | 0.95 [0.93, 0.96] ascii-16       |
| Utf8FromUtf16le       |   15 |    17.74 |     1.02 |    11.59 |        - |        - |  2% |   3 |  10 | 0.96 [0.93, 1.04] ascii-1048576  |
| Utf8FromUtf16be       |   15 |    19.52 |     1.17 |        - |        - |        - |  2% |   0 |   1 | 1.07 [1.03, 1.09] ascii-1048576  |
| Utf8FromUtf32         |   15 |    19.04 |     1.07 |        - |        - |        - |  2% |   1 |   1 | 0.98 [0.97, 0.99] ascii-64       |
| Utf8FromLatin1        |   13 |    32.37 |     1.00 |        - |        - |        - |  2% |   4 |   0 | 0.71 [0.70, 0.79] ascii-16       |
| CountUtf8             |   15 |    54.32 |     1.23 |    27.82 |     2.92 |    36.70 |  2% |   1 |   0 | 0.85 [0.83, 0.87] ascii-64       |
| CountUtf16le          |   15 |    43.75 |     2.28 |     9.48 |        - |        - |  2% |   0 |   1 | 1.10 [0.85, 1.12] ascii-64       |
| CountUtf16be          |   15 |    45.35 |     2.29 |        - |        - |        - |  1% |   0 |   0 | 1.17 [1.16, 1.22] ascii-64       |
| Base64Encode          |    6 |     7.29 |     1.05 |     2.56 |     1.74 |     5.07 |  2% |   1 |   3 | 0.95 [0.91, 0.99] random-1048576 |
| Base64EncodeUrl       |    6 |     7.21 |     1.05 |     2.51 |     1.73 |     5.12 |  3% |   1 |   2 | 0.93 [0.89, 0.97] random-1048576 |
| Base64Decode          |    6 |     6.50 |     1.16 |     1.70 |     1.37 |     4.21 |  4% |   1 |   1 | 0.92 [0.91, 0.95] random-1048576 |
| Base64DecodeUrl       |    6 |     6.25 |     1.09 |     1.57 |     1.30 |     3.49 |  4% |   3 |   0 | 0.79 [0.76, 0.89] random-1048576 |
| Base64DecodeStrict    |    6 |     6.35 |     1.12 |     1.66 |     1.33 |     4.12 |  5% |   1 |   2 | 0.92 [0.89, 0.95] random-1048576 |
| Base64DecodePartial   |    6 |     6.11 |     1.17 |        - |        - |        - |  2% |   1 |   1 | 0.91 [0.87, 0.96] random-1048576 |
| Base64DecodeMime      |    6 |     5.66 |     1.31 |    11.48 |     3.95 |     4.19 |  5% |   0 |   0 | 1.14 [1.03, 1.18] random-256     |
| **all**               |  877 |    19.56 | **1.39** | **7.65** | **2.25** | **7.02** |     |  82 | 124 |                                  |

### baseline

| op                    | rows | utf GB/s |  simdutf |       std |     rust |        go |   ± |  <1 |   ~ | slowest vs simdutf              |
| --------------------- | ---: | -------: | -------: | --------: | -------: | --------: | --: | --: | --: | ------------------------------- |
| ValidateAscii         |    7 |    61.61 |     1.02 |         - |     1.87 |         - |  6% |   1 |   5 | 0.93 [0.91, 0.96] ascii-16      |
| ValidateAsciiErr      |    7 |    53.46 |     0.87 |         - |     1.63 |         - |  5% |   4 |   3 | 0.64 [0.63, 0.64] ascii-64      |
| ValidateUtf8          |   15 |    35.25 |     1.32 |      8.08 |     1.56 |      8.73 |  3% |   2 |   1 | 0.87 [0.86, 0.93] ascii-16      |
| ValidateUtf8Err       |   15 |    29.43 |     2.78 |      8.18 |     1.63 |      7.33 |  3% |   0 |   0 | 1.27 [1.22, 1.30] emoji         |
| ValidateUtf16le       |   15 |    87.93 |     1.04 |         - |     8.31 |         - |  3% |   3 |   7 | 0.73 [0.66, 0.74] ascii-256     |
| ValidateUtf16leErr    |   15 |    74.24 |     1.10 |         - |     8.07 |         - |  2% |   2 |   3 | 0.78 [0.61, 0.79] ascii-256     |
| ValidateUtf16be       |   15 |    75.93 |     1.21 |         - |        - |         - |  2% |   3 |   0 | 0.81 [0.79, 0.89] ascii-16      |
| ValidateUtf16beErr    |   15 |    70.79 |     1.24 |         - |        - |         - |  3% |   2 |   0 | 0.88 [0.86, 0.89] ascii-256     |
| ValidateUtf32         |   15 |    74.38 |     1.13 |         - |        - |         - |  1% |   1 |   2 | 0.93 [0.93, 0.95] ascii-256     |
| ValidateUtf32Err      |   15 |    77.20 |     0.95 |         - |        - |         - |  2% |   5 |  10 | 0.75 [0.70, 0.80] ascii-64      |
| Utf8ToUtf16le         |   15 |     8.71 |     1.20 |      7.04 |     3.14 |     14.18 |  3% |   0 |   5 | 1.00 [0.97, 1.03] arabic        |
| ValidUtf8ToUtf16le    |   15 |     9.66 |     1.28 |         - |     2.85 |         - |  2% |   2 |   4 | 0.75 [0.73, 0.76] ascii-256     |
| Utf8ToUtf16be         |   15 |     8.31 |     1.24 |         - |        - |         - |  2% |   0 |   3 | 1.01 [0.97, 1.03] ascii-1048576 |
| ValidUtf8ToUtf16be    |   15 |     9.44 |     1.32 |         - |        - |         - |  3% |   2 |   3 | 0.76 [0.74, 0.77] ascii-256     |
| Utf8ToUtf32           |   15 |     6.94 |     1.45 |         - |        - |      8.85 |  2% |   1 |   3 | 0.92 [0.88, 1.02] ascii-64      |
| ValidUtf8ToUtf32      |   15 |     7.53 |     1.13 |         - |        - |         - |  2% |   3 |   3 | 0.74 [0.72, 0.75] ascii-256     |
| Utf8ToLatin1          |   13 |    14.22 |     0.92 |         - |        - |         - |  3% |   6 |   4 | 0.57 [0.49, 0.58] latin1-64     |
| ValidUtf8ToLatin1     |   13 |    16.76 |     0.83 |         - |     4.84 |         - |  2% |   8 |   4 | 0.51 [0.50, 0.54] latin1-64     |
| Utf16leToUtf8         |   15 |    17.74 |     1.26 |      6.76 |     4.73 |     15.87 |  2% |   2 |   4 | 0.86 [0.85, 0.88] ascii-64      |
| ValidUtf16leToUtf8    |   15 |    18.75 |     1.28 |         - |        - |         - |  1% |   1 |   3 | 0.92 [0.90, 0.93] ascii-64      |
| Utf16leToUtf16be      |   15 |    32.65 |     1.38 |         - |        - |         - |  3% |   0 |   0 | 1.10 [1.07, 1.17] ascii-4096    |
| ValidUtf16leToUtf16be |   15 |    38.26 |     0.93 |         - |        - |         - |  3% |   4 |  11 | 0.55 [0.52, 0.55] ascii-16      |
| Utf16leToUtf32        |   15 |    21.70 |     1.06 |         - |        - |         - |  2% |   2 |  10 | 0.77 [0.61, 0.78] ascii-64      |
| ValidUtf16leToUtf32   |   15 |    20.66 |     1.07 |         - |        - |         - |  2% |   2 |  10 | 0.81 [0.80, 1.00] ascii-64      |
| Utf16leToLatin1       |   13 |    31.35 |     0.87 |         - |        - |         - |  2% |   5 |   6 | 0.57 [0.56, 0.57] ascii-16      |
| ValidUtf16leToLatin1  |   13 |    34.89 |     1.05 |         - |     1.94 |         - |  3% |   2 |   3 | 0.57 [0.56, 0.60] latin1-16     |
| Utf16beToUtf8         |   15 |    16.95 |     1.26 |         - |        - |         - |  2% |   1 |   1 | 0.89 [0.76, 0.89] ascii-64      |
| ValidUtf16beToUtf8    |   15 |    19.04 |     1.27 |         - |        - |         - |  2% |   1 |   1 | 0.91 [0.90, 0.96] ascii-64      |
| Utf16beToUtf16le      |   15 |    31.01 |     1.42 |         - |        - |         - |  3% |   0 |   0 | 1.16 [1.10, 1.20] ascii-256     |
| ValidUtf16beToUtf16le |   15 |    37.69 |     0.94 |         - |        - |         - |  1% |   3 |  11 | 0.57 [0.57, 0.60] ascii-16      |
| Utf16beToUtf32        |   15 |    20.73 |     1.08 |         - |        - |         - |  2% |   2 |   9 | 0.77 [0.75, 0.78] ascii-64      |
| ValidUtf16beToUtf32   |   15 |    20.40 |     1.09 |         - |        - |         - |  2% |   2 |   9 | 0.84 [0.77, 0.87] ascii-64      |
| Utf16beToLatin1       |   13 |    30.08 |     0.90 |         - |        - |         - |  3% |   8 |   4 | 0.62 [0.54, 0.64] ascii-16      |
| ValidUtf16beToLatin1  |   13 |    34.67 |     1.09 |         - |        - |         - |  2% |   2 |   2 | 0.55 [0.54, 0.57] ascii-16      |
| Utf32ToUtf8           |   15 |    25.97 |     1.76 |         - |        - |     11.17 |  2% |   0 |   0 | 1.23 [1.07, 1.26] ascii-1048576 |
| ValidUtf32ToUtf8      |   15 |    25.85 |     1.88 |         - |        - |         - |  3% |   0 |   0 | 1.14 [1.13, 1.14] ascii-1048576 |
| Utf32ToUtf16le        |   15 |    43.71 |     1.11 |         - |        - |         - |  1% |   2 |   2 | 0.73 [0.69, 0.73] ascii-16      |
| ValidUtf32ToUtf16le   |   15 |    44.06 |     1.22 |         - |        - |         - |  3% |   1 |   1 | 0.82 [0.79, 0.85] ascii-16      |
| Utf32ToUtf16be        |   15 |    38.05 |     1.19 |         - |        - |         - |  2% |   2 |   2 | 0.75 [0.72, 0.76] ascii-16      |
| ValidUtf32ToUtf16be   |   15 |    44.04 |     1.43 |         - |        - |         - |  2% |   1 |   2 | 0.71 [0.70, 0.72] ascii-16      |
| Utf32ToLatin1         |   13 |    44.18 |     0.95 |         - |        - |         - |  2% |   6 |   4 | 0.68 [0.54, 0.69] ascii-16      |
| ValidUtf32ToLatin1    |   13 |    47.58 |     1.06 |         - |        - |         - |  2% |   2 |   2 | 0.74 [0.71, 0.76] ascii-16      |
| Latin1ToUtf8          |   13 |    13.69 |     0.85 |         - |     4.47 |         - |  3% |   9 |   3 | 0.64 [0.50, 0.67] latin1-64     |
| ValidLatin1ToUtf8     |   13 |    14.30 |     0.87 |         - |     4.57 |         - |  2% |   8 |   5 | 0.67 [0.53, 0.73] latin1-64     |
| Latin1ToUtf16le       |   13 |    17.33 |     0.88 |         - |     1.86 |         - |  3% |   4 |   8 | 0.63 [0.51, 0.65] latin1-64     |
| ValidLatin1ToUtf16le  |   13 |    18.16 |     0.91 |         - |     1.92 |         - |  3% |   4 |   5 | 0.69 [0.66, 0.71] ascii-16      |
| Latin1ToUtf16be       |   13 |    15.63 |     0.88 |         - |        - |         - |  1% |   6 |   5 | 0.65 [0.64, 0.65] ascii-16      |
| ValidLatin1ToUtf16be  |   13 |    15.46 |     0.91 |         - |        - |         - |  2% |   6 |   5 | 0.68 [0.60, 0.69] latin1-16     |
| Latin1ToUtf32         |   13 |    10.71 |     0.96 |         - |        - |         - |  2% |   3 |   5 | 0.64 [0.62, 0.68] latin1-16     |
| ValidLatin1ToUtf32    |   13 |    11.16 |     1.00 |         - |        - |         - |  3% |   4 |   4 | 0.81 [0.78, 0.82] ascii-16      |
| Utf16FromUtf8         |   15 |    50.28 |     1.13 |    289.54 |        - |         - |  2% |   1 |   3 | 0.96 [0.91, 0.99] ascii-4096    |
| Utf16FromUtf32        |   15 |    76.53 |     1.01 |         - |        - |         - |  1% |   2 |   8 | 0.88 [0.81, 1.09] ascii-16      |
| Utf8FromUtf16le       |   15 |    41.76 |     1.05 |     26.07 |        - |         - |  4% |   1 |  13 | 0.95 [0.92, 0.97] hebrew        |
| Utf8FromUtf16be       |   15 |    35.57 |     1.03 |         - |        - |         - |  1% |   8 |   6 | 0.92 [0.91, 0.95] ascii-65536   |
| Utf8FromUtf32         |   15 |    52.64 |     1.26 |         - |        - |         - |  3% |   0 |   1 | 0.94 [0.91, 1.07] ascii-1048576 |
| Utf8FromLatin1        |   13 |    38.70 |     1.11 |         - |        - |         - |  4% |   4 |   4 | 0.81 [0.76, 0.82] latin1-64     |
| CountUtf8             |   15 |    72.59 |     1.49 |     37.79 |     3.98 |     49.72 |  2% |   0 |   0 | 1.13 [1.11, 1.16] ascii-64      |
| CountUtf16le          |   15 |    61.17 |     1.00 |     14.53 |        - |         - |  6% |   2 |   5 | 0.71 [0.69, 0.89] ascii-16      |
| CountUtf16be          |   15 |    64.47 |     1.20 |         - |        - |         - |  3% |   2 |   0 | 0.75 [0.71, 0.75] ascii-16      |
| Base64Encode          |    6 |    12.62 |     0.90 |      5.04 |     2.10 |     10.06 |  4% |   2 |   3 | 0.68 [0.66, 0.84] random-16     |
| Base64EncodeUrl       |    6 |    12.84 |     0.91 |      4.90 |     2.07 |     10.09 | 10% |   2 |   2 | 0.68 [0.67, 0.71] random-16     |
| Base64Decode          |    6 |    13.31 |     1.11 |      3.61 |     2.10 |      9.00 |  5% |   1 |   2 | 0.96 [0.92, 0.97] random-4096   |
| Base64DecodeUrl       |    6 |    13.55 |     1.11 |      3.58 |     2.14 |      8.12 |  2% |   0 |   3 | 0.99 [0.98, 1.15] random-4096   |
| Base64DecodeStrict    |    6 |    12.87 |     1.10 |      3.52 |     2.00 |      8.70 |  3% |   1 |   1 | 0.96 [0.86, 1.00] random-4096   |
| Base64DecodePartial   |    6 |    14.31 |     1.14 |         - |        - |         - |  4% |   0 |   2 | 0.98 [0.95, 1.18] random-4096   |
| Base64DecodeMime      |    6 |     8.78 |     1.04 |     17.74 |     5.87 |      6.56 |  6% |   1 |   4 | 0.89 [0.88, 0.92] random-256    |
| **all**               |  877 |    27.22 | **1.13** | **13.74** | **3.08** | **11.87** |     | 167 | 254 |                                 |

### ReleaseSafe

| op                    | rows | utf GB/s |  simdutf |      std |     rust |        go |   ± |  <1 |   ~ | slowest vs simdutf              |
| --------------------- | ---: | -------: | -------: | -------: | -------: | --------: | --: | --: | --: | ------------------------------- |
| ValidateAscii         |    7 |    48.04 |     0.80 |        - |     1.47 |         - |  3% |   4 |   1 | 0.53 [0.51, 0.57] ascii-4096    |
| ValidateAsciiErr      |    7 |    41.34 |     0.71 |        - |     1.32 |         - |  3% |   6 |   0 | 0.44 [0.42, 0.46] ascii-4096    |
| ValidateUtf8          |   15 |    31.85 |     1.17 |     6.04 |     1.33 |      7.67 |  1% |   1 |   1 | 0.94 [0.92, 0.95] ascii-16      |
| ValidateUtf8Err       |   15 |    26.76 |     2.41 |     6.03 |     1.34 |      6.35 |  2% |   0 |   0 | 1.28 [1.27, 1.47] emoji         |
| ValidateUtf16le       |   15 |    71.90 |     0.95 |        - |     7.35 |         - |  2% |  11 |   1 | 0.73 [0.69, 0.75] ascii-256     |
| ValidateUtf16leErr    |   15 |    71.89 |     1.00 |        - |     7.18 |         - |  2% |   5 |   7 | 0.77 [0.73, 0.78] ascii-256     |
| ValidateUtf16be       |   15 |    72.33 |     1.10 |        - |        - |         - |  2% |   2 |   3 | 0.80 [0.77, 0.82] ascii-256     |
| ValidateUtf16beErr    |   15 |    66.88 |     1.12 |        - |        - |         - |  3% |   1 |   2 | 0.89 [0.87, 0.93] ascii-256     |
| ValidateUtf32         |   15 |    64.07 |     0.89 |        - |        - |         - |  3% |  10 |   3 | 0.77 [0.77, 0.78] ascii-256     |
| ValidateUtf32Err      |   15 |    64.86 |     0.80 |        - |        - |         - |  1% |  12 |   3 | 0.70 [0.60, 0.73] ascii-64      |
| Utf8ToUtf16le         |   15 |     8.65 |     1.15 |     5.72 |     3.08 |     13.68 |  2% |   3 |   1 | 0.96 [0.90, 0.96] russian       |
| ValidUtf8ToUtf16le    |   15 |     8.97 |     1.24 |        - |     2.71 |         - |  3% |   4 |   2 | 0.54 [0.53, 0.54] ascii-4096    |
| Utf8ToUtf16be         |   15 |     8.78 |     1.18 |        - |        - |         - |  1% |   2 |   3 | 0.98 [0.97, 0.99] russian       |
| ValidUtf8ToUtf16be    |   15 |     9.18 |     1.29 |        - |        - |         - |  2% |   3 |   2 | 0.71 [0.69, 0.87] ascii-4096    |
| Utf8ToUtf32           |   15 |     7.20 |     1.40 |        - |        - |      8.61 |  2% |   3 |   3 | 0.80 [0.76, 0.81] ascii-256     |
| ValidUtf8ToUtf32      |   15 |     7.53 |     1.09 |        - |        - |         - |  2% |   5 |   1 | 0.63 [0.63, 0.65] ascii-256     |
| Utf8ToLatin1          |   13 |    13.72 |     0.82 |        - |        - |         - |  2% |  10 |   2 | 0.59 [0.56, 0.60] latin1-64     |
| ValidUtf8ToLatin1     |   13 |    15.15 |     0.71 |        - |     4.32 |         - |  2% |  11 |   2 | 0.50 [0.49, 0.61] ascii-4096    |
| Utf16leToUtf8         |   15 |    18.10 |     1.18 |     5.19 |     5.05 |     15.14 |  2% |   4 |   2 | 0.80 [0.78, 0.84] ascii-4096    |
| ValidUtf16leToUtf8    |   15 |    18.01 |     1.16 |        - |        - |         - |  2% |   3 |   3 | 0.84 [0.78, 0.84] ascii-4096    |
| Utf16leToUtf16be      |   15 |    25.26 |     1.01 |        - |        - |         - |  4% |   3 |   9 | 0.52 [0.49, 0.58] ascii-4096    |
| ValidUtf16leToUtf16be |   15 |    34.65 |     0.83 |        - |        - |         - |  1% |   9 |   5 | 0.38 [0.36, 0.41] ascii-4096    |
| Utf16leToUtf32        |   15 |    19.24 |     1.00 |        - |        - |         - |  1% |   8 |   5 | 0.64 [0.62, 0.66] ascii-4096    |
| ValidUtf16leToUtf32   |   15 |    19.59 |     0.99 |        - |        - |         - |  2% |   7 |   6 | 0.63 [0.62, 0.67] ascii-4096    |
| Utf16leToLatin1       |   13 |    27.40 |     0.78 |        - |        - |         - |  2% |  11 |   2 | 0.61 [0.60, 0.61] ascii-16      |
| ValidUtf16leToLatin1  |   13 |    31.80 |     0.90 |        - |     1.61 |         - |  2% |   7 |   5 | 0.59 [0.58, 0.61] latin1-16     |
| Utf16beToUtf8         |   15 |    17.29 |     1.15 |        - |        - |         - |  1% |   3 |   3 | 0.83 [0.79, 0.85] ascii-4096    |
| ValidUtf16beToUtf8    |   15 |    17.01 |     1.18 |        - |        - |         - |  3% |   3 |   3 | 0.85 [0.84, 0.86] ascii-4096    |
| Utf16beToUtf16le      |   15 |    24.27 |     1.06 |        - |        - |         - |  2% |   1 |   5 | 0.57 [0.54, 0.58] ascii-4096    |
| ValidUtf16beToUtf16le |   15 |    34.35 |     0.84 |        - |        - |         - |  3% |   6 |   9 | 0.39 [0.36, 0.40] ascii-4096    |
| Utf16beToUtf32        |   15 |    19.44 |     1.03 |        - |        - |         - |  2% |   9 |   4 | 0.76 [0.73, 0.82] ascii-256     |
| ValidUtf16beToUtf32   |   15 |    19.74 |     1.03 |        - |        - |         - |  2% |   8 |   5 | 0.78 [0.74, 0.81] ascii-256     |
| Utf16beToLatin1       |   13 |    28.91 |     0.80 |        - |        - |         - |  2% |  10 |   3 | 0.65 [0.58, 0.66] ascii-16      |
| ValidUtf16beToLatin1  |   13 |    32.87 |     0.94 |        - |        - |         - |  2% |   6 |   5 | 0.63 [0.54, 0.64] ascii-16      |
| Utf32ToUtf8           |   15 |    25.35 |     1.59 |        - |        - |     10.17 |  3% |   0 |   0 | 1.13 [1.03, 1.21] ascii-1048576 |
| ValidUtf32ToUtf8      |   15 |    26.10 |     1.71 |        - |        - |         - |  3% |   0 |   0 | 1.11 [1.02, 1.13] ascii-1048576 |
| Utf32ToUtf16le        |   15 |    36.85 |     0.96 |        - |        - |         - |  2% |   4 |  11 | 0.78 [0.74, 0.82] ascii-16      |
| ValidUtf32ToUtf16le   |   15 |    43.86 |     1.07 |        - |        - |         - |  2% |   2 |   0 | 0.84 [0.83, 0.85] ascii-16      |
| Utf32ToUtf16be        |   15 |    35.79 |     1.05 |        - |        - |         - |  3% |   3 |   3 | 0.79 [0.75, 0.82] ascii-16      |
| ValidUtf32ToUtf16be   |   15 |    43.33 |     1.26 |        - |        - |         - |  2% |   2 |   0 | 0.75 [0.70, 0.91] ascii-16      |
| Utf32ToLatin1         |   13 |    46.14 |     0.93 |        - |        - |         - |  1% |   6 |   6 | 0.68 [0.66, 0.69] ascii-16      |
| ValidUtf32ToLatin1    |   13 |    52.39 |     1.02 |        - |        - |         - |  1% |   2 |   5 | 0.70 [0.68, 0.73] ascii-16      |
| Latin1ToUtf8          |   13 |    14.98 |     0.79 |        - |     4.18 |         - |  2% |  10 |   3 | 0.51 [0.50, 0.59] ascii-4096    |
| ValidLatin1ToUtf8     |   13 |    13.79 |     0.80 |        - |     4.20 |         - |  3% |  11 |   2 | 0.50 [0.45, 0.52] ascii-4096    |
| Latin1ToUtf16le       |   13 |    17.21 |     0.89 |        - |     1.85 |         - |  2% |   8 |   5 | 0.76 [0.63, 0.95] ascii-16      |
| ValidLatin1ToUtf16le  |   13 |    17.50 |     0.90 |        - |     1.87 |         - |  2% |   6 |   7 | 0.79 [0.76, 0.83] ascii-4096    |
| Latin1ToUtf16be       |   13 |    16.77 |     0.88 |        - |        - |         - |  3% |   8 |   5 | 0.71 [0.69, 0.72] latin1-16     |
| ValidLatin1ToUtf16be  |   13 |    16.38 |     0.91 |        - |        - |         - |  2% |   8 |   4 | 0.81 [0.80, 0.83] latin1-16     |
| Latin1ToUtf32         |   13 |    12.65 |     1.02 |        - |        - |         - |  2% |   4 |   4 | 0.89 [0.87, 0.90] ascii-16      |
| ValidLatin1ToUtf32    |   13 |    12.09 |     1.02 |        - |        - |         - |  3% |   3 |   8 | 0.88 [0.83, 0.89] ascii-16      |
| Utf16FromUtf8         |   15 |    29.15 |     0.61 |   160.35 |        - |         - |  2% |  13 |   0 | 0.48 [0.46, 0.51] ascii-65536   |
| Utf16FromUtf32        |   15 |    38.27 |     0.46 |        - |        - |         - |  3% |  14 |   1 | 0.35 [0.35, 0.38] korean        |
| Utf8FromUtf16le       |   15 |    28.01 |     0.65 |    16.58 |        - |         - |  2% |  13 |   1 | 0.53 [0.51, 0.55] hindi         |
| Utf8FromUtf16be       |   15 |    30.60 |     0.82 |        - |        - |         - |  4% |  14 |   0 | 0.69 [0.67, 0.76] ascii-4096    |
| Utf8FromUtf32         |   15 |    31.13 |     0.80 |        - |        - |         - |  1% |  13 |   0 | 0.72 [0.70, 0.73] arabic        |
| Utf8FromLatin1        |   13 |    23.81 |     0.67 |        - |        - |         - |  2% |  11 |   0 | 0.38 [0.37, 0.51] ascii-65536   |
| CountUtf8             |   15 |    34.07 |     0.67 |    17.09 |     1.14 |     22.23 |  1% |  12 |   0 | 0.54 [0.53, 0.54] emoji         |
| CountUtf16le          |   15 |    40.92 |     0.64 |     9.26 |        - |         - |  2% |  15 |   0 | 0.54 [0.53, 0.54] ascii-4096    |
| CountUtf16be          |   15 |    41.85 |     0.77 |        - |        - |         - |  1% |  14 |   0 | 0.72 [0.71, 0.72] ascii-4096    |
| Base64Encode          |    6 |    13.42 |     0.82 |     4.69 |     1.93 |      9.37 |  6% |   4 |   1 | 0.68 [0.67, 0.71] random-16     |
| Base64EncodeUrl       |    6 |    13.30 |     0.83 |     4.58 |     1.95 |      9.46 |  3% |   4 |   0 | 0.66 [0.59, 0.67] random-16     |
| Base64Decode          |    6 |    13.67 |     1.07 |     3.50 |     1.87 |      8.65 |  4% |   1 |   0 | 0.85 [0.84, 0.97] random-4096   |
| Base64DecodeUrl       |    6 |    13.31 |     1.08 |     3.55 |     1.95 |      7.94 |  3% |   1 |   2 | 0.89 [0.86, 0.90] random-4096   |
| Base64DecodeStrict    |    6 |    12.41 |     1.06 |     3.39 |     1.81 |      8.42 |  3% |   1 |   2 | 0.83 [0.71, 0.85] random-4096   |
| Base64DecodePartial   |    6 |    14.22 |     1.11 |        - |        - |         - |  2% |   1 |   1 | 0.86 [0.83, 0.91] random-4096   |
| Base64DecodeMime      |    6 |     7.97 |     0.92 |    15.88 |     5.05 |      5.76 |  3% |   4 |   1 | 0.79 [0.63, 0.90] random-4096   |
| **all**               |  877 |    24.26 | **0.97** | **9.83** | **2.61** | **10.20** |     | 403 | 183 |                                 |

## Rows under 1.0 outside the noise

Every row whose 95% interval lies under 1.0, against every arm, by level, with the reason the wave-3 write-ups give where they give one. Rows whose interval holds 1 are not listed: their spread exceeds their gap, so they cannot be called either way, and each level's `~` count above says how many there are. The full lists, with intervals, are each level's `rows.txt`.

### Native against `icelake`: 105 rows against simdutf, 5 against std

Of the 877 rows, 105 are under simdutf beyond their interval and 279 cannot be called (interval holds 1). By kind:

| rows                                                                                                                                                                                                                                                       |                          ratio | reason in the wave-3 write-ups                                                                                                                                                                                                                                                                                                                        |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -----------------------------: | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Short calls, 16–64 B**: Latin-1 to UTF-16 and UTF-32 at 16–64 B, UTF-16 to Latin-1 at 16 units, UTF-32 to Latin-1 and UTF-16 at 16 units, UTF-16 to UTF-32 and UTF-8 on ASCII at 64 B, the valid UTF-8 decodes on ASCII at 64 B, `CountUtf16le/ascii-16` |                      0.67–0.98 | "Short rows at 16–64 B (0.79–0.90): 1–2 ns a call, within the harness's swing at this size" ([convert-wave3](convert-wave3-20261031.md)). They are outside the noise now: 0.4–1.2 ns a call, real. Each AVX-512 kernel loads 20–25 constants before its loop; the ASCII prefix test covers UTF-8 and UTF-16 to UTF-8 but not the fixed-ratio kernels. |
| **UTF-8 to Latin-1** on Latin-1 text, both forms, 16 B–64 KiB, and the valid form on ASCII at 64–256 B                                                                                                                                                     |                      0.60–0.91 | "A few percent at 256 B is real; the harness's 0.7 is not" (layout driver 0.88–1.17). With both libraries' buffers placed alike, 16–256 B read 0.60–0.79, so most of this gap is real.                                                                                                                                                                |
| **Latin-1 to UTF-8** on Latin-1 text, every size, both rows (one function)                                                                                                                                                                                 | 0.72–0.82 (0.90–0.95 at 1 MiB) | Real, not closed: about 8 shuffle-port operations per 64 bytes; `vpcompressb` to memory was 0.41–0.48.                                                                                                                                                                                                                                                |
| **The valid UTF-16 byte swap**, ASCII, 16 B–4 KiB, both byte orders                                                                                                                                                                                        |                      0.59–0.88 | "Layout": the wave-3 driver had us at 1.57–1.90× `icelake` at 256 B. Here it is behind from 16 B to 4 KiB in both byte orders, so layout is not the whole story; unexplained.                                                                                                                                                                         |
| **ASCII at 256 B**: valid UTF-8 to UTF-16, UTF-16 to UTF-32, UTF-16 validation                                                                                                                                                                             |                      0.79–0.95 | "256-byte ASCII widening, not investigated" (hypothesis: the first step to the output's 64-byte boundary, a partial block at this size); validation "layout".                                                                                                                                                                                         |
| **Base64 encode, 16 B** (both alphabets)                                                                                                                                                                                                                   |                      0.75–0.82 | The partial block loads zero-padded in registers, where `icelake` uses a masked load that would wait on recent stores to the bytes it masks off.                                                                                                                                                                                                      |
| **Length from UTF-16 and Latin-1**: `utf8FromUtf16be` on text and 64 KiB, `utf8FromUtf16le` on emoji, Latin text, and 64 KiB, `utf8FromLatin1` at 4 KiB                                                                                                    |                      0.81–0.95 | Wave 3 saw unchanged native length code move 0.86–0.98 with layout. Within this build they are outside the noise; within the ±15% layout band.                                                                                                                                                                                                        |
| **Large inputs within 10%**: UTF-16 validation at 1 MiB, ASCII validation with an error at 4 KiB, UTF-32 to Latin-1 at 64 KiB and on Latin text, UTF-16 to UTF-8 and UTF-8 to UTF-16 on one text each, base64 URL decode at 4 KiB                          |                      0.91–0.99 | Validation "level, memory"; base64 decode "the clean-block loop did not change; hypothesis: a 64-byte store at a 48-byte stride splits a cache line three times in four".                                                                                                                                                                             |

Against std: `utf16LeToUtf8` on ASCII at 16–256 units (0.65–0.92: std's loop, autovectorized for AVX-512, beats ours at 64 units), and `utf8ToUtf16Le` and `utf8CountCodepoints` on 16 ASCII bytes (0.94–0.95). None in the wave-3 write-ups, which compared std at AVX2 and SSE only.

### AVX2 against `haswell`: 41 rows against simdutf, 3 against Rust, 3 against std

| rows                                                                                                                            |     ratio | reason in the wave-3 write-ups                                                                                                                                                                            |
| ------------------------------------------------------------------------------------------------------------------------------- | --------: | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Latin-1 to UTF-16 and UTF-32, 16–64 B**, both forms, both byte orders                                                         | 0.77–0.94 | Wave 2 left "16-byte Latin-1 (0.44–0.50 of `haswell`)"; wave 3 closed most of it. What is left is 0.4–1 ns a call.                                                                                        |
| **ASCII at 4 KiB**: the valid UTF-8 decodes to UTF-16, UTF-32, and Latin-1, and UTF-16 to UTF-32 (both forms, both byte orders) | 0.84–0.91 | None. New.                                                                                                                                                                                                |
| **`utf8FromLatin1` at 64 B**                                                                                                    |      0.74 | "AVX2 `utf8FromUtf32` and `utf8FromLatin1` at 64–256 B (0.83–0.85): the run is shorter than the 16 vectors from which `sumBlocks` aligns, and the reduction to one sum is 15–20 operations; not changed." |
| **Short**: `utf16FromUtf32/ascii-16`, `countUtf16le/ascii-64`, the valid byte swap at 16–64 B                                   | 0.81–0.87 | Short rows, 1–2 ns a call.                                                                                                                                                                                |
| **Base64 decode at 64 KiB** (standard and URL)                                                                                  | 0.91–0.97 | "Encode and decode 4 KiB–1 MiB 0.93–0.98: run-to-run spread on these rows"; outside the noise here, so a real few percent.                                                                                |
| **UTF-16 to UTF-8 and UTF-32 on Japanese**                                                                                      | 0.95–0.99 | Wave 3 brought AVX2 UTF-16 to UTF-8 on CJK from 0.79–0.83 to about 1.0.                                                                                                                                   |

Against Rust, now built for `x86-64-v3`: base64 decode at 64 B (0.87–0.94), where wave 2 and 3 compared AVX-512 Rust. Against std at `x86_64_v3`: `utf16LeToUtf8` on 16 and 64 ASCII units (0.81–0.84) and `utf8ToUtf16Le` on 16 bytes (0.89).

### SSE against `westmere`: 82 rows against simdutf, 7 against std, 8 against Rust

| rows                                                                                                                                                                  |     ratio | reason in the wave-3 write-ups                                                                                                                                                                                                    |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------: | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Latin-1 to UTF-16**, both forms, 16 B–64 KiB and the Latin text (big-endian at 16 B and 64 KiB)                                                                     | 0.80–0.96 | "SSE Latin-1 to UTF-16 at 4 KiB-64 KiB (0.77-0.88, unchanged code): one `punpcklbw`/`punpckhbw` and two 16-byte stores per 16 bytes; judged store-bound in wave 2, not measured further." The 16–256 B rows are new in this list. |
| **Checked UTF-32 to UTF-16**, both byte orders, on every text and 4–64 KiB of ASCII                                                                                   | 0.88–0.95 | None. New: the valid forms lead (geomeans 1.75–1.88), so the cost is the checked form's range and surrogate test.                                                                                                                 |
| **`utf8FromLatin1` at 16–64 B**                                                                                                                                       | 0.71–0.80 | The AVX2 reason applies with 16-byte vectors: "the run is shorter than the 16 vectors from which `sumBlocks` aligns, and the reduction to one sum is 15-20 operations; not changed."                                              |
| **Base64 at 1 MiB** (encode, decode, URL, strict, partial) and URL decode at 4–64 KiB                                                                                 | 0.79–0.97 | Wave 3 called the AVX2 rows at 4 KiB–1 MiB "run-to-run spread"; outside the noise here. `Base64Encode/random-4096`, which wave 3 left at 0.92 ("the SSSE3 encode loop"), reads 1.00 now, its interval holding 1.                  |
| **UTF-16BE validation on emoji**, both forms                                                                                                                          |      0.82 | None. New.                                                                                                                                                                                                                        |
| **Short**: the valid byte swap at 16–64 B, UTF-16BE to Latin-1, UTF-32 to UTF-16LE, `utf16FromUtf32`, and Latin-1 to UTF-32 at 16 units, `countUtf8/ascii-64`         | 0.85–0.98 | Short rows, 1–2 ns a call.                                                                                                                                                                                                        |
| **Length from UTF-16LE** on Hindi, Russian, and Latin text                                                                                                            | 0.97–0.98 | `utf8FromUtf16le` "0.88 to 1.00 of `westmere`"; layout (identical code read 1.05× and 1.19× at two addresses).                                                                                                                    |
| **Large inputs at memory or level**: Latin-1 to UTF-32 at 64 KiB and on Latin text, ASCII validation at 1 MiB, `ValidUtf8ToLatin1/latin`, `ValidUtf16leToUtf8/korean` | 0.95–0.99 | Level and memory, as natively.                                                                                                                                                                                                    |

Against std at `x86_64_v2`: `ValidateUtf8Err` on 64 and 256 ASCII bytes (0.83, 0.88) and the base64 decodes at 16 B (0.80–0.84), as wave 3 gives ("std's loop finds it in place, where the short path builds the zero-padded block"; "std decodes 16 characters in a scalar loop"), plus UTF-8 validation and `utf16LeToUtf8` on 16 ASCII bytes (0.84–0.88). Against Rust, now really SSE (`x86-64-v2`, no run-time detection): the base64 decodes at 16–64 B (0.78–0.88; wave 3's "Rust 0.77-0.87 is its AVX-512 build" still holds at SSE), `encoding_rs` on emoji for valid UTF-8 to UTF-16 (0.89), and UTF-8 validation on Latin text (0.99).

The first SSE run (`westmere-detect/`, Rust's SIMD crates still detecting AVX2) and this one ran the same utf and simdutf binaries 30 minutes apart in separate processes: every operation's geomean against simdutf agreed within 2.6% (median 0%, 90th percentile 1.0%), and the overall geomean read 1.39 in both. Per row, the ratios agreed within 0.6% at the median, 2.0% at the 90th percentile, and 17% at worst (`Utf32ToUtf16le/emoji`, ahead in both); no row called under in one run was called ahead in the other (66 under in both, 31 under in one and within the noise in the other).

### Baseline build, dispatching, against simdutf's runtime pick (`icelake`): 167 rows against simdutf, 6 against std, 1 against Rust

The same AVX-512 kernels as the native build, reached through `dispatch.call`, against simdutf's dispatch to `icelake`. The rows under are the native rows plus most short ones:

| rows                                                                                                                                                                                                                                                          |     ratio | reason in the wave-3 write-ups                                                                                                                                                  |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Short calls, 16–64 B**, nearly every operation: validation (ASCII, UTF-8, UTF-16, UTF-32 at 16–64 B), the fixed-ratio conversions (0.55–0.82 at 16 units), the UTF-8 and UTF-16 decodes on 64 ASCII bytes, the counts, base64 encode at 16–64 B (0.68–0.80) | 0.55–0.99 | "Dispatch now costs 0.1–3 ns over native" ([dispatch-wave3](dispatch-wave3-20261031.md)). simdutf's own dispatch is a load and an indirect call; ours costs more on these rows. |
| **ASCII at 256 B**: UTF-16 and UTF-32 validation, the valid UTF-8 decodes, UTF-16 to UTF-32, Latin-1 widening, and the checked fixed-ratio conversions                                                                                                        | 0.73–0.97 | As native ("256-byte ASCII widening, not investigated"), plus the dispatch.                                                                                                     |
| **UTF-8 to Latin-1, Latin-1 to UTF-8, the valid byte swap**, larger sizes                                                                                                                                                                                     | 0.51–0.96 | As native.                                                                                                                                                                      |
| **Length**: `utf8FromUtf16be` on every text (0.92–0.94), `utf8FromLatin1` at 64 B–4 KiB                                                                                                                                                                       | 0.81–0.98 | As native.                                                                                                                                                                      |
| **Large inputs within 5%**: UTF-16 validation at 1 MiB, UTF-32 to Latin-1 and UTF-16BE to Latin-1 at 64 KiB, base64 decode at 4 KiB, MIME decode at 256 B                                                                                                     | 0.89–0.99 | As native.                                                                                                                                                                      |

Against std, built for baseline x86-64 (SSE2): UTF-8 validation on 16 and 64 ASCII bytes (0.66, 0.82), `utf16LeToUtf8` on 16 and 64 ASCII units (0.77–0.79), `utf8ToUtf16Le` and `utf8CountCodepoints` on 16 bytes (0.80–0.83): std's scalar loops are inline, where ours dispatch to AVX-512. Against Rust (baseline target, `base64-simd` detecting AVX2): strict decode at 16 B (0.94).

### ReleaseSafe against `icelake`: 403 rows against simdutf, 11 against std, 5 against Rust

Only utf is built ReleaseSafe; simdutf, std (ReleaseFast), Rust, and Go are the native arms. The wave-3 write-ups do not measure ReleaseSafe, so none of these rows has a reason there. Of the 877 rows, 403 are under simdutf beyond their interval and 183 cannot be called. The overall geomean drops from 1.18 to 0.97, and the loss is not spread evenly:

| rows                                                                                                                                                                        |                                               ratio | likely cause (a hypothesis; not profiled)                                                                                                                                                                   |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------: | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Length and count**, every input from 4 KiB up: `utf16FromUtf8`, `utf16FromUtf32`, `utf8FromUtf16le/be`, `utf8FromUtf32`, `utf8FromLatin1`, `countUtf8`, `countUtf16le/be` | 0.35–0.86 (op geomeans 0.46–0.82, native 1.04–1.55) | Their loops do the least work per byte, so a bounds check and an overflow-checked accumulator per block are a large share of each iteration.                                                                |
| **ASCII and UTF-32 validation**, 64 B and up                                                                                                                                | 0.44–0.87 (op geomeans 0.71–0.89, native 1.00–1.18) | The same: a compare and a branch per block, so the checks are a large share.                                                                                                                                |
| **Fixed-ratio conversions** (Latin-1 ↔ UTF-8, UTF-16, UTF-32; UTF-16 and UTF-32 to Latin-1; the byte swaps), mostly 16 B–4 KiB                                              |                                           0.38–0.99 | The native gaps (see icelake) widened by 5–15 points; the short rows by the checks around the partial block.                                                                                                |
| **Base64 encode** at 16 B–4 KiB, MIME decode at every size, plain decode at 4 KiB                                                                                           |                                           0.66–0.89 | As native, widened.                                                                                                                                                                                         |
| **UTF-8 ↔ UTF-16 and UTF-32 transcoding, UTF-16 to UTF-32, UTF-8 and UTF-16 validation**                                                                                    | 0.95–0.99 on text; 0.54–0.96 on ASCII at 64 B–4 KiB | On text the branchy per-block work dominates and the checks cost 5–10%; the op geomeans stay at 0.95–2.41 (native 1.07–2.89). The ASCII fast paths are tight loops like the length functions and lose more. |

Against std (ReleaseFast): the native list plus `utf8ToUtf16Le` on ASCII at 16 B–64 KiB (0.83–0.97) and UTF-8 validation on 64 ASCII bytes (0.91). Against Rust: UTF-8 validation, with and without error position, on ASCII and Latin text at 64 KiB and up (0.83–0.89), where `simdutf8` is at memory speed and our checked loop is not.

### Every row under 1.0 outside the noise, by level

`arm op input ratio`, the ratio being the median of the per-round ratios.

#### icelake: 105 vs simdutf, 5 vs std

```
simdutf  ValidateAsciiErr       ascii-64 0.95, ascii-4096 0.91
simdutf  ValidateUtf16le        ascii-256 0.85, ascii-1048576 0.91
simdutf  ValidateUtf16leErr     ascii-256 0.80
simdutf  ValidateUtf16be        ascii-256 0.89
simdutf  ValidateUtf16beErr     ascii-256 0.95
std      Utf8ToUtf16le          ascii-16 0.94
simdutf  Utf8ToUtf16le          russian 0.97
simdutf  ValidUtf8ToUtf16le     ascii-256 0.79, ascii-4096 0.86
simdutf  ValidUtf8ToUtf16be     ascii-64 0.92, ascii-256 0.80
simdutf  ValidUtf8ToUtf32       ascii-64 0.85
simdutf  Utf8ToLatin1           latin1-16 0.73, latin1-64 0.62, latin1-256 0.79, latin 0.99
simdutf  ValidUtf8ToLatin1      latin1-16 0.60, ascii-64 0.88, latin1-64 0.61, ascii-256 0.91, latin1-256 0.73, latin1-4096 0.91, latin1-65536 0.87
std      Utf16leToUtf8          ascii-16 0.88, ascii-64 0.65, ascii-256 0.92
simdutf  Utf16leToUtf8          latin 0.97
simdutf  ValidUtf16leToUtf8     ascii-64 0.94, latin 0.96
simdutf  ValidUtf16leToUtf16be  ascii-16 0.60, ascii-64 0.79, ascii-256 0.86, ascii-4096 0.84
simdutf  Utf16leToUtf32         ascii-64 0.86, ascii-256 0.92
simdutf  Utf16leToLatin1        ascii-16 0.67, latin1-16 0.67, ascii-64 0.85, latin1-64 0.87
simdutf  ValidUtf16leToLatin1   ascii-16 0.67, latin1-16 0.68
simdutf  Utf16beToUtf8          ascii-64 0.93
simdutf  ValidUtf16beToUtf16le  ascii-16 0.59, ascii-64 0.77, ascii-256 0.88, ascii-4096 0.85
simdutf  Utf16beToUtf32         ascii-64 0.92
simdutf  ValidUtf16beToUtf32    ascii-64 0.92
simdutf  Utf16beToLatin1        ascii-16 0.74, latin1-16 0.73, ascii-64 0.95
simdutf  ValidUtf16beToLatin1   ascii-16 0.69, latin1-16 0.69
simdutf  Utf32ToUtf16le         ascii-16 0.81
simdutf  ValidUtf32ToUtf16le    ascii-16 0.87
simdutf  Utf32ToUtf16be         ascii-16 0.81
simdutf  ValidUtf32ToUtf16be    ascii-16 0.80
simdutf  Utf32ToLatin1          ascii-16 0.88, latin1-16 0.88, ascii-65536 0.96, latin 0.97
simdutf  ValidUtf32ToLatin1     ascii-16 0.85, latin1-16 0.85
simdutf  Latin1ToUtf8           latin1-16 0.76, latin1-64 0.74, latin1-256 0.77, latin1-4096 0.82, latin1-65536 0.77, latin1-1048576 0.95
simdutf  ValidLatin1ToUtf8      ascii-16 0.79, latin1-16 0.80, latin1-64 0.72, latin1-256 0.81, latin1-4096 0.81, latin1-65536 0.80, latin1-1048576 0.90
simdutf  Latin1ToUtf16le        ascii-16 0.77, latin1-16 0.78, ascii-64 0.87, latin1-64 0.86
simdutf  ValidLatin1ToUtf16le   ascii-16 0.84, latin1-16 0.84, ascii-64 0.95
simdutf  Latin1ToUtf16be        ascii-16 0.80, latin1-16 0.80, ascii-64 0.93
simdutf  ValidLatin1ToUtf16be   ascii-16 0.84, latin1-16 0.85
simdutf  Latin1ToUtf32          ascii-16 0.89, latin1-16 0.89
simdutf  ValidLatin1ToUtf32     ascii-16 0.98
simdutf  Utf16FromUtf8          ascii-4096 0.96
simdutf  Utf8FromUtf16le        emoji 0.94, ascii-65536 0.95, latin 0.94
simdutf  Utf8FromUtf16be        hindi 0.92, hebrew 0.92, russian 0.92, ascii-65536 0.90, latin 0.91
simdutf  Utf8FromLatin1         ascii-4096 0.81, latin1-4096 0.81
std      CountUtf8              ascii-16 0.95
simdutf  CountUtf16le           ascii-16 0.89
simdutf  Base64Encode           random-16 0.82
simdutf  Base64EncodeUrl        random-16 0.75, random-256 0.97
simdutf  Base64DecodeUrl        random-4096 0.96
```

#### haswell: 3 vs std, 41 vs simdutf, 3 vs rust

```
std      Utf8ToUtf16le          ascii-16 0.89
simdutf  ValidUtf8ToUtf16le     ascii-4096 0.88
simdutf  ValidUtf8ToUtf16be     ascii-4096 0.89
simdutf  ValidUtf8ToUtf32       ascii-4096 0.91
simdutf  ValidUtf8ToLatin1      ascii-4096 0.84
std      Utf16leToUtf8          ascii-16 0.81, ascii-64 0.84
simdutf  ValidUtf16leToUtf16be  ascii-16 0.87
simdutf  Utf16leToUtf32         ascii-64 0.96, ascii-256 0.98, ascii-4096 0.88, japanese 0.99
simdutf  ValidUtf16leToUtf32    ascii-4096 0.86
simdutf  Utf16leToLatin1        latin1-16 0.93
simdutf  Utf16beToUtf8          japanese 0.95
simdutf  ValidUtf16beToUtf16le  ascii-16 0.85, ascii-64 0.82
simdutf  Utf16beToUtf32         ascii-16 0.89, ascii-64 0.92, ascii-4096 0.87
simdutf  Latin1ToUtf16le        ascii-16 0.77, latin1-16 0.77, ascii-64 0.84, latin1-64 0.84
simdutf  ValidLatin1ToUtf16le   ascii-16 0.87, latin1-16 0.87, ascii-64 0.93, latin1-64 0.93
simdutf  Latin1ToUtf16be        ascii-16 0.82, latin1-16 0.82, ascii-64 0.86, latin1-64 0.87
simdutf  ValidLatin1ToUtf16be   ascii-16 0.93, latin1-16 0.94
simdutf  Latin1ToUtf32          ascii-16 0.82, latin1-16 0.82
simdutf  ValidLatin1ToUtf32     ascii-16 0.93, latin1-16 0.94
simdutf  Utf16FromUtf32         ascii-16 0.81
simdutf  Utf8FromLatin1         ascii-64 0.74, latin1-64 0.74
simdutf  CountUtf16le           ascii-64 0.86
rust     Base64Decode           random-64 0.92
simdutf  Base64Decode           random-65536 0.97
rust     Base64DecodeUrl        random-64 0.94
simdutf  Base64DecodeUrl        random-65536 0.91
rust     Base64DecodeStrict     random-64 0.87
```

#### westmere: 82 vs simdutf, 7 vs std, 8 vs rust

```
simdutf  ValidateAscii          ascii-1048576 0.98
std      ValidateUtf8           ascii-16 0.88
rust     ValidateUtf8           latin 0.99
std      ValidateUtf8Err        ascii-64 0.83, ascii-256 0.88
simdutf  ValidateUtf16be        emoji 0.82
simdutf  ValidateUtf16beErr     emoji 0.82
rust     ValidUtf8ToUtf16le     emoji 0.89
simdutf  ValidUtf8ToLatin1      latin 0.99
std      Utf16leToUtf8          ascii-16 0.84
simdutf  ValidUtf16leToUtf8     korean 0.97
simdutf  ValidUtf16leToUtf16be  ascii-16 0.93, ascii-64 0.89
simdutf  ValidUtf16beToUtf16le  ascii-16 0.92, ascii-64 0.89
simdutf  Utf16beToLatin1        ascii-16 0.94, latin1-16 0.94
simdutf  Utf32ToUtf16le         ascii-16 0.98, japanese 0.93, korean 0.94, hindi 0.95, hebrew 0.94, arabic 0.94, russian 0.94, ascii-65536 0.95, latin 0.95
simdutf  Utf32ToUtf16be         ascii-4096 0.88, japanese 0.91, chinese 0.91, korean 0.91, hindi 0.90, hebrew 0.91, russian 0.91, ascii-65536 0.91, latin 0.91
simdutf  Latin1ToUtf16le        ascii-16 0.80, latin1-16 0.80, ascii-64 0.82, latin1-64 0.82, ascii-256 0.89, latin1-256 0.89, ascii-4096 0.80, latin1-4096 0.80, ascii-65536 0.96, latin1-65536 0.96, latin 0.95
simdutf  ValidLatin1ToUtf16le   ascii-16 0.91, latin1-16 0.92, ascii-64 0.90, latin1-64 0.89, ascii-256 0.93, ascii-4096 0.81, latin1-4096 0.80, ascii-65536 0.96, latin1-65536 0.96, latin 0.96
simdutf  Latin1ToUtf16be        ascii-16 0.87, latin1-16 0.88, ascii-65536 0.96
simdutf  ValidLatin1ToUtf16be   ascii-16 0.95, latin1-16 0.96, latin1-65536 0.96, latin 0.96
simdutf  Latin1ToUtf32          ascii-16 0.94, ascii-65536 0.96, latin1-65536 0.96, latin 0.96
simdutf  ValidLatin1ToUtf32     ascii-65536 0.95, latin1-65536 0.96, latin 0.96
simdutf  Utf16FromUtf32         ascii-16 0.94
simdutf  Utf8FromUtf16le        hindi 0.97, russian 0.98, latin 0.97
simdutf  Utf8FromUtf32          ascii-64 0.98
simdutf  Utf8FromLatin1         ascii-16 0.71, latin1-16 0.71, ascii-64 0.79, latin1-64 0.80
simdutf  CountUtf8              ascii-64 0.85
simdutf  Base64Encode           random-1048576 0.95
simdutf  Base64EncodeUrl        random-1048576 0.93
std      Base64Decode           random-16 0.84
rust     Base64Decode           random-16 0.82, random-64 0.86
simdutf  Base64Decode           random-1048576 0.92
std      Base64DecodeUrl        random-16 0.80
rust     Base64DecodeUrl        random-16 0.88, random-64 0.88
simdutf  Base64DecodeUrl        random-4096 0.97, random-65536 0.93, random-1048576 0.79
std      Base64DecodeStrict     random-16 0.80
rust     Base64DecodeStrict     random-16 0.78, random-64 0.81
simdutf  Base64DecodeStrict     random-1048576 0.92
simdutf  Base64DecodePartial    random-1048576 0.91
```

#### baseline: 167 vs simdutf, 6 vs std, 1 vs rust

```
simdutf  ValidateAscii          ascii-16 0.93
simdutf  ValidateAsciiErr       ascii-16 0.80, ascii-64 0.64, ascii-256 0.91, latin 0.98
simdutf  ValidateUtf8           ascii-16 0.87, ascii-64 0.94
std      ValidateUtf8           ascii-16 0.66, ascii-64 0.82
simdutf  ValidateUtf16le        ascii-256 0.73, arabic 1.00, ascii-1048576 0.95
simdutf  ValidateUtf16leErr     ascii-16 0.94, ascii-256 0.78
simdutf  ValidateUtf16be        ascii-16 0.81, ascii-64 0.93, ascii-256 0.81
simdutf  ValidateUtf16beErr     ascii-16 0.92, ascii-256 0.88
simdutf  ValidateUtf32          ascii-256 0.93
simdutf  ValidateUtf32Err       ascii-16 0.77, ascii-64 0.75, ascii-256 0.88, ascii-4096 0.99, chinese 0.99
std      Utf8ToUtf16le          ascii-16 0.80
simdutf  ValidUtf8ToUtf16le     ascii-64 0.94, ascii-256 0.75
simdutf  ValidUtf8ToUtf16be     ascii-64 0.81, ascii-256 0.76
simdutf  Utf8ToUtf32            ascii-1048576 0.99
simdutf  ValidUtf8ToUtf32       ascii-64 0.78, ascii-256 0.74, latin 0.99
simdutf  Utf8ToLatin1           ascii-16 0.82, latin1-16 0.65, ascii-64 0.99, latin1-64 0.57, ascii-256 0.82, latin1-256 0.77
simdutf  ValidUtf8ToLatin1      ascii-16 0.75, latin1-16 0.57, ascii-64 0.75, latin1-64 0.51, ascii-256 0.78, latin1-256 0.70, latin1-4096 0.96, latin1-65536 0.89
std      Utf16leToUtf8          ascii-16 0.79, ascii-64 0.77
simdutf  Utf16leToUtf8          ascii-64 0.86, latin 0.96
simdutf  ValidUtf16leToUtf8     ascii-64 0.92
simdutf  ValidUtf16leToUtf16be  ascii-16 0.55, ascii-64 0.73, ascii-256 0.91, ascii-4096 0.92
simdutf  Utf16leToUtf32         ascii-64 0.77, ascii-256 0.90
simdutf  ValidUtf16leToUtf32    ascii-64 0.81, ascii-256 0.91
simdutf  Utf16leToLatin1        ascii-16 0.57, latin1-16 0.57, ascii-64 0.73, latin1-64 0.74, ascii-256 0.86
simdutf  ValidUtf16leToLatin1   ascii-16 0.57, latin1-16 0.56
simdutf  Utf16beToUtf8          ascii-64 0.89
simdutf  ValidUtf16beToUtf8     ascii-64 0.91
simdutf  ValidUtf16beToUtf16le  ascii-16 0.57, ascii-64 0.73, ascii-256 0.96
simdutf  Utf16beToUtf32         ascii-64 0.77, ascii-256 0.93
simdutf  ValidUtf16beToUtf32    ascii-64 0.84, ascii-256 0.94
simdutf  Utf16beToLatin1        ascii-16 0.62, latin1-16 0.64, ascii-64 0.77, latin1-64 0.77, ascii-256 0.91, latin1-256 0.93, ascii-65536 0.95, latin1-65536 0.96
simdutf  ValidUtf16beToLatin1   ascii-16 0.55, latin1-16 0.55
simdutf  Utf32ToUtf16le         ascii-16 0.73, emoji 0.95
simdutf  ValidUtf32ToUtf16le    ascii-16 0.82
simdutf  Utf32ToUtf16be         ascii-16 0.75, emoji 0.94
simdutf  ValidUtf32ToUtf16be    ascii-16 0.71
simdutf  Utf32ToLatin1          ascii-16 0.68, latin1-16 0.68, ascii-256 0.97, latin1-256 0.97, latin1-65536 0.97, latin 0.97
simdutf  ValidUtf32ToLatin1     ascii-16 0.73, latin1-16 0.73
simdutf  Latin1ToUtf8           ascii-16 0.69, latin1-16 0.71, ascii-64 0.87, latin1-64 0.64, ascii-256 0.95, latin1-256 0.73, latin1-4096 0.78, latin1-65536 0.79, latin1-1048576 0.91
simdutf  ValidLatin1ToUtf8      ascii-16 0.73, latin1-16 0.72, ascii-64 0.90, latin1-64 0.67, latin1-256 0.76, latin1-4096 0.77, latin1-65536 0.78, latin1-1048576 0.95
simdutf  Latin1ToUtf16le        ascii-16 0.65, latin1-16 0.65, ascii-64 0.65, latin1-64 0.63
simdutf  ValidLatin1ToUtf16le   ascii-16 0.69, latin1-16 0.70, ascii-64 0.73, latin1-64 0.72
simdutf  Latin1ToUtf16be        ascii-16 0.65, latin1-16 0.65, ascii-64 0.69, latin1-64 0.68, ascii-256 0.88, latin1-256 0.87
simdutf  ValidLatin1ToUtf16be   ascii-16 0.70, latin1-16 0.68, ascii-64 0.76, latin1-64 0.75, ascii-256 0.90, latin1-256 0.90
simdutf  Latin1ToUtf32          ascii-16 0.67, latin1-16 0.64, latin1-64 0.87
simdutf  ValidLatin1ToUtf32     ascii-16 0.81, latin1-16 0.81, ascii-64 0.88, latin1-64 0.88
simdutf  Utf16FromUtf8          ascii-4096 0.96
simdutf  Utf16FromUtf32         ascii-256 0.94, ascii-4096 0.97
simdutf  Utf8FromUtf16le        hebrew 0.95
simdutf  Utf8FromUtf16be        ascii-4096 0.98, korean 0.94, hindi 0.94, emoji 0.93, hebrew 0.93, russian 0.93, ascii-65536 0.92, latin 0.93
simdutf  Utf8FromLatin1         ascii-64 0.81, latin1-64 0.81, ascii-4096 0.89, latin1-4096 0.87
std      CountUtf8              ascii-16 0.83
simdutf  CountUtf16le           ascii-16 0.71, ascii-256 0.88
simdutf  CountUtf16be           ascii-16 0.75, ascii-256 0.95
simdutf  Base64Encode           random-16 0.68, random-64 0.80
simdutf  Base64EncodeUrl        random-16 0.68, random-64 0.80
simdutf  Base64Decode           random-4096 0.96
rust     Base64DecodeStrict     random-16 0.94
simdutf  Base64DecodeStrict     random-4096 0.96
simdutf  Base64DecodeMime       random-256 0.89
```

#### ReleaseSafe: 403 vs simdutf, 11 vs std, 5 vs rust

```
simdutf  ValidateAscii          ascii-4096 0.53, ascii-65536 0.69, latin 0.67, ascii-1048576 0.67
simdutf  ValidateAsciiErr       ascii-64 0.85, ascii-256 0.82, ascii-4096 0.44, ascii-65536 0.67, latin 0.66, ascii-1048576 0.62
simdutf  ValidateUtf8           ascii-16 0.94
std      ValidateUtf8           ascii-64 0.91
rust     ValidateUtf8           ascii-65536 0.85, latin 0.89, ascii-1048576 0.84
rust     ValidateUtf8Err        ascii-65536 0.84, ascii-1048576 0.83
simdutf  ValidateUtf16le        ascii-256 0.73, ascii-4096 0.87, japanese 0.84, chinese 0.86, korean 0.88, hindi 0.88, hebrew 0.88, arabic 0.88, russian 0.88, ascii-65536 0.89, latin 0.89
simdutf  ValidateUtf16leErr     ascii-256 0.77, ascii-4096 0.93, korean 0.97, arabic 0.98, latin 0.98
simdutf  ValidateUtf16be        ascii-16 0.87, ascii-256 0.80
simdutf  ValidateUtf16beErr     ascii-256 0.89
simdutf  ValidateUtf32          ascii-256 0.77, ascii-4096 0.79, emoji 0.81, japanese 0.83, hindi 0.83, hebrew 0.83, arabic 0.82, russian 0.83, ascii-65536 0.83, latin 0.84
simdutf  ValidateUtf32Err       ascii-64 0.70, ascii-256 0.75, ascii-4096 0.74, emoji 0.79, japanese 0.78, chinese 0.78, korean 0.78, hindi 0.80, arabic 0.79, russian 0.80, ascii-65536 0.79, latin 0.80
std      Utf8ToUtf16le          ascii-16 0.83, ascii-64 0.88, ascii-256 0.82, ascii-4096 0.94, ascii-65536 0.97
simdutf  Utf8ToUtf16le          hebrew 0.97, arabic 0.96, russian 0.96
simdutf  ValidUtf8ToUtf16le     ascii-64 0.97, ascii-256 0.67, ascii-4096 0.54, latin 0.98
simdutf  Utf8ToUtf16be          arabic 0.98, russian 0.98
simdutf  ValidUtf8ToUtf16be     ascii-64 0.85, ascii-256 0.72, ascii-4096 0.70
simdutf  Utf8ToUtf32            ascii-256 0.80, ascii-4096 0.82, ascii-65536 0.97
simdutf  ValidUtf8ToUtf32       ascii-64 0.71, ascii-256 0.63, ascii-4096 0.72, ascii-65536 0.97, latin 0.97
simdutf  Utf8ToLatin1           ascii-16 0.94, latin1-16 0.68, latin1-64 0.59, ascii-256 0.79, latin1-256 0.71, ascii-4096 0.60, latin1-4096 0.80, ascii-65536 0.99, latin1-65536 0.80, latin1-1048576 0.85
simdutf  ValidUtf8ToLatin1      ascii-16 0.80, latin1-16 0.61, ascii-64 0.79, latin1-64 0.57, ascii-256 0.67, latin1-256 0.62, ascii-4096 0.50, latin1-4096 0.57, ascii-65536 0.99, latin1-65536 0.61, latin1-1048576 0.78
std      Utf16leToUtf8          ascii-16 0.78, ascii-64 0.64, ascii-256 0.78, ascii-4096 0.94
simdutf  Utf16leToUtf8          ascii-256 0.95, ascii-4096 0.80, latin 0.91, ascii-1048576 0.96
simdutf  ValidUtf16leToUtf8     ascii-64 0.92, ascii-4096 0.83, ascii-1048576 0.97
simdutf  Utf16leToUtf16be       ascii-256 0.98, ascii-4096 0.52, emoji 0.97
simdutf  ValidUtf16leToUtf16be  ascii-16 0.47, ascii-64 0.67, ascii-256 0.63, ascii-4096 0.38, korean 0.98, emoji 0.96, hebrew 0.98, arabic 0.98, ascii-65536 0.98
simdutf  Utf16leToUtf32         ascii-64 0.79, ascii-256 0.70, ascii-4096 0.64, japanese 0.99, korean 0.99, russian 0.98, ascii-65536 0.96, latin 0.98
simdutf  ValidUtf16leToUtf32    ascii-64 0.79, ascii-256 0.71, ascii-4096 0.63, japanese 0.99, korean 0.99, russian 0.98, latin 0.98
simdutf  Utf16leToLatin1        ascii-16 0.60, latin1-16 0.61, ascii-64 0.80, latin1-64 0.80, ascii-256 0.76, latin1-256 0.76, ascii-4096 0.65, latin1-4096 0.65, ascii-65536 0.91, latin1-65536 0.89, latin 0.87
simdutf  ValidUtf16leToLatin1   ascii-16 0.59, latin1-16 0.59, ascii-4096 0.80, latin1-4096 0.80, ascii-65536 0.96, latin 0.96, ascii-1048576 0.98
simdutf  Utf16beToUtf8          ascii-256 0.93, ascii-4096 0.83, latin 0.86
simdutf  ValidUtf16beToUtf8     ascii-256 0.96, ascii-4096 0.85, latin 0.87
simdutf  Utf16beToUtf16le       ascii-4096 0.57
simdutf  ValidUtf16beToUtf16le  ascii-16 0.47, ascii-64 0.67, ascii-256 0.64, ascii-4096 0.39, japanese 0.99, russian 0.97
simdutf  Utf16beToUtf32         ascii-64 0.83, ascii-256 0.76, ascii-4096 0.81, japanese 0.98, korean 0.98, hindi 0.97, hebrew 0.98, arabic 0.99, latin 0.98
simdutf  ValidUtf16beToUtf32    ascii-64 0.84, ascii-256 0.78, ascii-4096 0.82, chinese 0.97, korean 0.98, arabic 0.96, russian 0.97, ascii-65536 0.97
simdutf  Utf16beToLatin1        ascii-16 0.65, latin1-16 0.65, ascii-64 0.77, latin1-64 0.76, ascii-256 0.79, latin1-256 0.78, ascii-4096 0.80, latin1-4096 0.80, ascii-65536 0.83, latin 0.85
simdutf  ValidUtf16beToLatin1   ascii-16 0.63, latin1-16 0.63, latin1-256 0.95, ascii-65536 0.89, latin1-65536 0.92, latin 0.96
simdutf  Utf32ToUtf16le         ascii-16 0.78, ascii-64 0.92, emoji 0.80, hindi 0.97
simdutf  ValidUtf32ToUtf16le    ascii-16 0.84, emoji 0.86
simdutf  Utf32ToUtf16be         ascii-16 0.79, ascii-64 0.96, emoji 0.83
simdutf  ValidUtf32ToUtf16be    ascii-16 0.75, emoji 0.85
simdutf  Utf32ToLatin1          ascii-16 0.68, latin1-16 0.68, ascii-256 0.94, latin1-256 0.95, ascii-65536 0.93, latin 0.93
simdutf  ValidUtf32ToLatin1     ascii-16 0.70, latin1-16 0.71
simdutf  Latin1ToUtf8           ascii-16 0.76, latin1-16 0.76, latin1-64 0.73, ascii-256 0.82, latin1-256 0.72, ascii-4096 0.51, latin1-4096 0.74, latin1-65536 0.70, latin 0.98, latin1-1048576 0.85
simdutf  ValidLatin1ToUtf8      ascii-16 0.77, latin1-16 0.76, latin1-64 0.75, ascii-256 0.86, latin1-256 0.74, ascii-4096 0.50, latin1-4096 0.75, ascii-65536 0.97, latin1-65536 0.72, latin 0.98, latin1-1048576 0.85
simdutf  Latin1ToUtf16le        ascii-16 0.77, latin1-16 0.77, ascii-64 0.77, latin1-64 0.77, ascii-256 0.96, latin1-256 0.96, ascii-4096 0.82, latin1-4096 0.83
simdutf  ValidLatin1ToUtf16le   ascii-16 0.82, latin1-16 0.81, ascii-64 0.79, latin1-64 0.81, ascii-4096 0.79, latin1-4096 0.80
simdutf  Latin1ToUtf16be        ascii-16 0.71, latin1-16 0.71, ascii-64 0.75, latin1-64 0.76, ascii-256 0.89, latin1-256 0.92, ascii-4096 0.89, latin1-4096 0.91
simdutf  ValidLatin1ToUtf16be   ascii-16 0.81, latin1-16 0.81, ascii-64 0.87, latin1-64 0.86, ascii-256 0.86, latin1-256 0.85, ascii-4096 0.90, latin1-4096 0.90
simdutf  Latin1ToUtf32          ascii-16 0.89, latin1-16 0.89, ascii-64 0.96, latin1-64 0.96
simdutf  ValidLatin1ToUtf32     ascii-16 0.88, latin1-16 0.88, latin1-64 0.97
simdutf  Utf16FromUtf8          ascii-256 0.77, ascii-4096 0.49, ascii-65536 0.48, emoji 0.49, hebrew 0.50, korean 0.49, japanese 0.51, chinese 0.52, arabic 0.52, latin 0.52, hindi 0.50, russian 0.49, ascii-1048576 0.51
simdutf  Utf16FromUtf32         ascii-64 0.91, ascii-256 0.59, ascii-4096 0.38, emoji 0.35, japanese 0.36, chinese 0.35, korean 0.35, hindi 0.36, hebrew 0.36, arabic 0.37, russian 0.38, ascii-65536 0.38, latin 0.39, ascii-1048576 0.91
simdutf  Utf8FromUtf16le        ascii-256 0.73, ascii-4096 0.53, japanese 0.55, chinese 0.55, korean 0.54, hindi 0.53, emoji 0.54, hebrew 0.54, arabic 0.54, russian 0.54, ascii-65536 0.54, latin 0.53, ascii-1048576 0.77
simdutf  Utf8FromUtf16be        ascii-64 0.95, ascii-256 0.87, ascii-4096 0.69, japanese 0.71, chinese 0.70, korean 0.72, hindi 0.72, emoji 0.72, hebrew 0.72, arabic 0.71, russian 0.71, ascii-65536 0.71, latin 0.72, ascii-1048576 0.85
simdutf  Utf8FromUtf32          ascii-256 0.88, ascii-4096 0.76, emoji 0.72, japanese 0.72, chinese 0.72, korean 0.72, hindi 0.73, hebrew 0.73, arabic 0.72, russian 0.72, ascii-65536 0.73, latin 0.72, ascii-1048576 0.88
simdutf  Utf8FromLatin1         ascii-64 0.87, latin1-64 0.87, ascii-256 0.93, latin1-256 0.93, ascii-4096 0.39, latin1-4096 0.41, ascii-65536 0.38, latin1-65536 0.39, latin 0.40, ascii-1048576 0.39, latin1-1048576 0.42
std      CountUtf8              ascii-16 0.89
simdutf  CountUtf8              ascii-4096 0.59, ascii-65536 0.54, emoji 0.54, hebrew 0.55, korean 0.54, japanese 0.54, chinese 0.54, arabic 0.54, latin 0.54, hindi 0.54, russian 0.54, ascii-1048576 0.54
simdutf  CountUtf16le           ascii-16 0.75, ascii-64 0.83, ascii-256 0.68, ascii-4096 0.54, japanese 0.58, chinese 0.55, korean 0.64, hindi 0.63, emoji 0.64, hebrew 0.63, arabic 0.63, russian 0.64, ascii-65536 0.61, latin 0.63, ascii-1048576 0.76
simdutf  CountUtf16be           ascii-16 0.78, ascii-256 0.81, ascii-4096 0.71, japanese 0.77, chinese 0.74, korean 0.74, hindi 0.74, emoji 0.74, hebrew 0.75, arabic 0.73, russian 0.74, ascii-65536 0.74, latin 0.74, ascii-1048576 0.86
simdutf  Base64Encode           random-16 0.68, random-64 0.79, random-256 0.71, random-4096 0.72
simdutf  Base64EncodeUrl        random-16 0.66, random-64 0.84, random-256 0.72, random-4096 0.69
simdutf  Base64Decode           random-4096 0.85
simdutf  Base64DecodeUrl        random-4096 0.89
simdutf  Base64DecodeStrict     random-4096 0.83
simdutf  Base64DecodePartial    random-4096 0.86
simdutf  Base64DecodeMime       random-256 0.81, random-4096 0.79, random-65536 0.80, random-1048576 0.83
```

## Peak RSS

GNU `time` around one `check` pass per arm and operation: the inputs, the output buffers an arm writes, and its runtime. Every arm now holds the inputs and outputs alike (each in its own mapping, the slack around an input written), so the differences are runtime. Native, MiB:

| op                       | simdutf |  utf | std | rust |  go |
| ------------------------ | ------: | ---: | --: | ---: | --: |
| validate-ascii           |     5.6 |  2.5 |   - |  3.5 |   - |
| validate-ascii-err       |     5.7 |  2.5 |   - |  3.5 |   - |
| validate-utf8            |     6.2 |  3.1 | 2.9 |  4.1 | 4.5 |
| validate-utf8-err        |     6.2 |  3.1 | 2.9 |  4.1 | 4.5 |
| validate-utf16le         |     7.3 |  4.2 |   - |  5.2 |   - |
| validate-utf16le-err     |     7.3 |  4.2 |   - |  5.2 |   - |
| validate-utf16be         |     7.3 |  4.2 |   - |    - |   - |
| validate-utf16be-err     |     7.3 |  4.2 |   - |    - |   - |
| validate-utf32           |    10.1 |  7.0 |   - |    - |   - |
| validate-utf32-err       |    10.1 |  7.0 |   - |    - |   - |
| utf8-to-utf16le          |     8.2 |  4.9 | 4.7 |  5.1 | 5.5 |
| valid-utf8-to-utf16le    |     8.1 |  4.9 |   - |  5.1 |   - |
| utf8-to-utf16be          |     8.2 |  4.9 |   - |    - |   - |
| valid-utf8-to-utf16be    |     8.1 |  4.9 |   - |    - |   - |
| utf8-to-utf32            |    10.2 |  7.0 |   - |    - | 7.6 |
| valid-utf8-to-utf32      |    10.2 |  7.0 |   - |    - |   - |
| utf8-to-latin1           |     7.7 |  4.5 |   - |    - |   - |
| valid-utf8-to-latin1     |     7.7 |  4.5 |   - |  5.2 |   - |
| utf16le-to-utf8          |     8.2 |  5.0 | 4.8 |  5.2 | 5.6 |
| valid-utf16le-to-utf8    |     8.2 |  5.0 |   - |    - |   - |
| utf16le-to-utf16be       |     9.2 |  6.0 |   - |    - |   - |
| valid-utf16le-to-utf16be |     9.2 |  6.0 |   - |    - |   - |
| utf16le-to-utf32         |    11.3 |  8.1 |   - |    - |   - |
| valid-utf16le-to-utf32   |    11.3 |  8.1 |   - |    - |   - |
| utf16le-to-latin1        |     9.8 |  6.6 |   - |    - |   - |
| valid-utf16le-to-latin1  |     9.8 |  6.6 |   - |  7.1 |   - |
| utf16be-to-utf8          |     8.2 |  5.0 |   - |    - |   - |
| valid-utf16be-to-utf8    |     8.2 |  5.0 |   - |    - |   - |
| utf16be-to-utf16le       |     9.2 |  6.0 |   - |    - |   - |
| valid-utf16be-to-utf16le |     9.2 |  6.0 |   - |    - |   - |
| utf16be-to-utf32         |    11.3 |  8.1 |   - |    - |   - |
| valid-utf16be-to-utf32   |    11.3 |  8.1 |   - |    - |   - |
| utf16be-to-latin1        |     9.8 |  6.6 |   - |    - |   - |
| valid-utf16be-to-latin1  |     9.8 |  6.6 |   - |    - |   - |
| utf32-to-utf8            |    11.0 |  7.7 |   - |    - | 8.5 |
| valid-utf32-to-utf8      |    11.0 |  7.7 |   - |    - |   - |
| utf32-to-utf16le         |    12.0 |  8.7 |   - |    - |   - |
| valid-utf32-to-utf16le   |    12.0 |  8.7 |   - |    - |   - |
| utf32-to-utf16be         |    11.9 |  8.7 |   - |    - |   - |
| valid-utf32-to-utf16be   |    12.0 |  8.7 |   - |    - |   - |
| utf32-to-latin1          |    14.3 | 11.0 |   - |    - |   - |
| valid-utf32-to-latin1    |    14.2 | 11.0 |   - |    - |   - |
| latin1-to-utf8           |     7.9 |  4.6 |   - |  5.1 |   - |
| valid-latin1-to-utf8     |     7.9 |  4.6 |   - |  5.1 |   - |
| latin1-to-utf16le        |     8.6 |  5.4 |   - |  6.1 |   - |
| valid-latin1-to-utf16le  |     8.6 |  5.4 |   - |  6.1 |   - |
| latin1-to-utf16be        |     8.6 |  5.4 |   - |    - |   - |
| valid-latin1-to-utf16be  |     8.6 |  5.4 |   - |    - |   - |
| latin1-to-utf32          |    10.7 |  7.4 |   - |    - |   - |
| valid-latin1-to-utf32    |    10.7 |  7.4 |   - |    - |   - |
| utf16-from-utf8          |     6.4 |  3.1 | 2.9 |    - |   - |
| utf16-from-utf32         |    10.2 |  6.9 |   - |    - |   - |
| utf8-from-utf16le        |     7.5 |  4.2 | 4.0 |    - |   - |
| utf8-from-utf16be        |     7.5 |  4.2 |   - |    - |   - |
| utf8-from-utf32          |    10.2 |  6.9 |   - |    - |   - |
| utf8-from-latin1         |     6.8 |  3.6 |   - |    - |   - |
| count-utf8               |     6.4 |  3.1 | 2.9 |  4.1 | 4.6 |
| count-utf16le            |     7.4 |  4.2 | 4.0 |    - |   - |
| count-utf16be            |     7.4 |  4.2 |   - |    - |   - |
| base64-encode            |     6.9 |  3.7 | 3.5 |  4.6 | 5.0 |
| base64-encode-url        |     6.9 |  3.7 | 3.5 |  4.6 | 5.1 |
| base64-decode            |     6.8 |  3.5 | 3.4 |  4.4 | 4.8 |
| base64-decode-url        |     6.8 |  3.5 | 3.4 |  4.4 | 4.9 |
| base64-decode-strict     |     6.9 |  3.5 | 3.4 |  4.4 | 4.8 |
| base64-decode-partial    |     6.7 |  3.5 |   - |    - |   - |
| base64-decode-mime       |     6.9 |  3.5 | 3.4 |  5.0 | 4.8 |

The floor is the data: 2.5 MiB for ASCII validation, 11 MiB for UTF-32 to Latin-1, whose inputs are four bytes a character. Against utf on every operation each arm has, by level:

| level                 |      simdutf |          std |         Rust |           Go |
| --------------------- | -----------: | -----------: | -----------: | -----------: |
| native                | +3.1 to +3.4 | −0.2 to −0.1 | +0.2 to +1.5 | +0.6 to +1.5 |
| AVX2                  | +3.1 to +3.4 | −0.3 to −0.2 | +0.2 to +1.5 | +0.6 to +1.5 |
| SSE                   | +3.1 to +3.4 | −0.2 to −0.1 | +0.2 to +1.5 | +0.6 to +1.5 |
| baseline, dispatching | +2.8 to +3.1 | −0.6 to −0.4 | −0.2 to +1.2 | +0.2 to +1.3 |
| ReleaseSafe           | +2.9 to +3.2 | −0.4 to −0.3 |  0.0 to +1.3 | +0.4 to +1.3 |

- **simdutf** is 3 MiB over utf everywhere: libstdc++ and libsimdutf, shared libraries the C++ arm maps. Nothing allocates in either library's timed path.
- **std** is 0.1–0.3 MiB under utf in the non-dispatching builds, as in waves 2 and 3: `bench-utf`'s text is larger, and neither allocates. The dispatching baseline build carries every tier's kernels, 0.3–0.4 MiB more than native on every operation.
- **Rust** and **Go** are 0.2–1.5 MiB over utf: their runtimes.
- **ReleaseSafe** utf is 0.2–0.3 MiB over the ReleaseFast build on every operation: the safety checks' code. Its column was measured again after a harness fix: the Zig arms' buffer placement allocated through `Allocator.alignedAlloc`, which fills the memory with `undefined` in a safe build, so the ReleaseSafe `bench-utf` made every output page resident, 1.0–3.4 MiB more on the conversions whose output buffer is larger than what they write. It now maps through `rawAlloc`, which does not fill; the timed modes write every page before timing in any case, so no throughput number changed.

## Files

In [baseline-final-20261031/](baseline-final-20261031/), one directory per level (`native`, `haswell`, `westmere`, `baseline`, `safe`), each what `just bench-compare` left in `zig-out/bench-compare/`, less the checksums: `config.txt`, `summary.txt`, `rows.txt` (every row against every arm: utf's and the arm's median GB/s, the median per-round ratio, its 95% interval, and `<`, `>`, or `~`), `rss.txt`, and, gzipped, `benchstat.txt` and each arm's per-round GB/s (`<arm>.txt`, the input of `bench/summary.awk`). `safe/rss.txt` has utf's column from after the placement fix under Peak RSS. `westmere-detect/` is the first SSE run, with Rust's SIMD crates still picking AVX2 at run time; its utf and simdutf columns agree with `westmere/`. `gen.py` makes this file's tables from the level directories. `noise/` holds the harness comparison: `runs.tar.gz` (each invocation's per-round GB/s, summary, and config), `noisecmp.txt` from `noisecmp.py`. `loop/` holds the loop-cost programs: `main.cpp` with `noop.cpp` built as a shared library, `loop.zig` (built against testingx like `bench/zig/arm.zig`), `loop.rs`, and `loop.go`.

To reproduce a level: `just bench-compare` (native), `just cpu=x86_64_v3 dispatch=false kernel=haswell bench-compare`, `just cpu=x86_64_v2 dispatch=false kernel=westmere bench-compare`, `just cpu=baseline bench-compare`, `just optimize=ReleaseSafe bench-compare`; each about 26 minutes on this orb, with nothing else running.
