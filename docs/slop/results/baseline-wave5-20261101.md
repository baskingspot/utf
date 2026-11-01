# Baseline on wave 5, 2026-11-01

Every operation (66) and every arm at every configuration, on `35029f5` (wave 5's short-call changes on `39088d1`; [short-20261101.md](short-20261101.md)), by the method of [baseline-final-20261031.md](baseline-final-20261031.md), and each level against that baseline (`d2d515e`). The comparison spans two orbs, and they differ: see [Two hosts](#two-hosts) before reading a change in the per-operation table as a change in the code.

- Machine: Amp orb, KVM guest, Intel Xeon @ 2.60GHz (Ice Lake server, AVX-512 with VBMI2), 2 cores × 2 threads; every timed process pinned to CPU 3, the driver to CPU 0, nothing else running.
- Package: `35029f5` (`src/` as `d7c51f1`, the tree this file was committed on). simdutf 9.2.1 (nixpkgs), Zig 0.16.0, Rust 1.99.0 (`simdutf8` 0.1.5, `encoding_rs` 0.8.44, `base64-simd` 0.8.0), Go 1.26.10, as before.
- Levels, each `just bench-compare` (10 rounds of 50 ms samples after a sizing round) over all 66 operations, with the `just` variables of baseline-final: icelake (defaults), haswell (`cpu=x86_64_v3 dispatch=false kernel=haswell`), westmere (`cpu=x86_64_v2 dispatch=false kernel=westmere`), baseline (`cpu=baseline`: utf dispatching to AVX-512, simdutf's runtime pick `icelake`, Rust with run-time detection, Go `v1`), ReleaseSafe (`optimize=ReleaseSafe`, native). 26–30 minutes a level.

## Takeaways

utf ÷ each arm, geomean over every row both have, baseline-final → this run; the rows under simdutf beyond their 95% interval; the rows whose interval holds 1; the operations whose geomean is under simdutf:

| level       |     simdutf |           std |        Rust |            Go | rows under simdutf | cannot call | ops under simdutf |
| ----------- | ----------: | ------------: | ----------: | ------------: | -----------------: | ----------: | ----------------: |
| icelake     | 1.18 → 1.15 | 13.38 → 13.14 | 3.12 → 3.41 | 12.34 → 14.08 |          105 → 176 |   279 → 235 |           12 → 14 |
| haswell     | 1.55 → 1.59 | 10.62 → 11.98 | 2.54 → 2.79 |  9.50 → 11.39 |            41 → 15 |   165 → 198 |             2 → 0 |
| westmere    | 1.39 → 1.44 |   7.65 → 7.68 | 2.25 → 2.32 |   7.02 → 7.55 |            82 → 11 |   124 → 227 |             2 → 1 |
| baseline    | 1.13 → 1.11 | 13.74 → 13.40 | 3.08 → 3.41 | 11.87 → 13.60 |          167 → 182 |   254 → 320 |           18 → 22 |
| ReleaseSafe | 0.97 → 0.98 |  9.83 → 11.01 | 2.61 → 2.88 | 10.20 → 12.16 |          403 → 357 |   183 → 237 |           34 → 38 |

Without the nine length and count operations, whose AVX-512 loop runs at about half speed on this orb's host whatever build runs it ([Two hosts](#two-hosts)), utf ÷ simdutf (geomean of the operations' geomeans, weighted by rows):

| level       | without length | length only |
| ----------- | -------------: | ----------: |
| icelake     |    1.18 → 1.20 | 1.18 → 0.94 |
| haswell     |    1.59 → 1.61 | 1.34 → 1.45 |
| westmere    |    1.39 → 1.44 | 1.40 → 1.43 |
| baseline    |    1.13 → 1.16 | 1.13 → 0.90 |
| ReleaseSafe |    1.03 → 1.04 | 0.67 → 0.73 |

- **AVX2 and SSE gained and close almost everything**: haswell 1.59, no operation under simdutf (two before) and 15 rows (41); westmere 1.44, one operation (`Utf8FromLatin1`, 0.97 on three 64-byte rows) and 11 rows (82). Wave 4's AVX2 and SSE work landed between the two runs; wave 5 changed neither tier, and part of the gain may be the host.
- **AVX-512 is ahead without the length functions**: 1.20 native, 1.16 dispatching. With them, 1.15 and 1.11, because on this host `popBlocks`' loop runs at 43–60 GB/s where baseline-final's host ran it at 75–105, while simdutf's slowed less or not at all; `66fa49c`'s build reads the same as this one's here (1.00–1.03, [Two hosts](#two-hosts)). Why the host changes this loop and not simdutf's is unexplained.
- **What is still under simdutf, natively**, is the length functions (host), and 16–256-byte rows of operations wave 5 did not change: Latin-1 to UTF-16 and UTF-32, the valid byte swap, UTF-16LE to Latin-1, all 0.90–0.99. Their code is instruction for instruction `39088d1`'s; the harness's Zig loop costs about 3 ns a call more than the C++ arm's ([short-20261101.md](short-20261101.md#the-harness-loop)), measured on `Latin1ToUtf16le` (0.64 of `icelake` at 16 bytes in the harness, level per call). Every operation under simdutf, with its reason, is in [Under simdutf](#under-simdutf).
- **Operations wave 5 changed**: `Latin1ToUtf8` and `ValidLatin1ToUtf8` 0.90 → 1.05–1.06 native and 0.85–0.87 → 0.99–1.00 dispatched; `Utf8ToLatin1` 0.98 → 1.11 and `ValidUtf8ToLatin1` 0.87 → 1.03 native (0.92 → 1.09, 0.83 → 0.98 dispatched); base64 decode 1.16–1.20 → 1.19–1.23 native. The per-change measurements, paired against `39088d1` on one host, are in [short-20261101.md](short-20261101.md); this table's deltas also hold the host and wave 4.
- **ReleaseSafe 0.98**, from 0.97: the checks (plan decision 5) still cost about 15% against the ReleaseFast build (1.15), most in the length functions (0.55–0.93) and ASCII and UTF-32 validation (0.71–0.82). 38 operations under simdutf, every one for the checks; 14 of them are also under natively.
- **std** 7.68–13.40×, **Rust** 2.32–3.41×, **Go** 7.55–14.08× at every level, each built for the same ISA.
- **Peak RSS**: unchanged, within 0.2 MiB of baseline-final's on every operation at every level (2.4–11.2 MiB: the data). simdutf +3.0 to +3.4 MiB, Rust +0.0 to +1.5, Go +0.4 to +1.5, std −0.5 to −0.1 against utf. Nothing allocates in any arm's timed path.

## Two hosts

baseline-final ran on another orb. On this orb's host most operations run up to 25% slower in absolute GB/s, in both utf and simdutf, and the two do not slow alike. Where an operation's ratio moved, the question is whether the code did; a build of the old code timed here against the new answers it, since their ratio is paired on one host. Builds of `66fa49c` (wave 3's final code, after baseline-final's harness work) and `39088d1` from [short-20261101.md](short-20261101.md)'s runs, against this run's final tree, with [ab.sh](short-20261101/ab.sh) (5 rounds; `host/`):

| run         | build      | operations                                                                                           |            final ÷ `66fa49c` |            final ÷ `icelake` |   baseline-final ÷ `icelake` |
| ----------- | ---------- | ---------------------------------------------------------------------------------------------------- | ---------------------------: | ---------------------------: | ---------------------------: |
| `host/len`  | native     | `Utf16FromUtf8`, `Utf8FromLatin1`, `CountUtf8` (4 KiB and up, `39088d1` as final)                    |             1.00 (`39088d1`) | 0.55, 0.52, 0.92 (`66fa49c`) |             1.17, 1.22, 1.55 |
| `host/len2` | native     | `Utf8FromUtf32`, `Utf8FromUtf16le`, `Utf16FromUtf32`, `Utf16leToLatin1`, `Latin1ToUtf32` (every row) | 1.00, 1.03, 1.02, 1.02, 1.03 | 0.85, 0.91, 1.01, 1.01, 0.99 | 1.30, 1.07, 1.06, 0.94, 1.08 |
| `host/len3` | native     | `ValidateUtf8Err`, `Utf8ToUtf32`, `ValidUtf8ToUtf32`                                                 |             1.01, 1.02, 1.01 |             1.81, 1.11, 1.03 |             2.89, 1.51, 1.14 |
| `host/len4` | dispatched | `Utf16FromUtf8`, `Utf16FromUtf32`, `Utf8FromUtf32`, `Utf8FromLatin1`, `CountUtf8` (4 KiB and up)     | 1.00, 0.92, 1.00, 1.00, 1.01 | 0.53, 0.93, 0.80, 0.54, 0.89 | 1.13, 1.01, 1.26, 1.11, 1.49 |

`66fa49c`'s code reads within 3% of the final tree's here on every one of them; their ratios to simdutf moved with the host. In `host/len` the inner loop of `Utf16FromUtf8`'s harness wrapper is the same 13 instructions in `66fa49c` and `39088d1` (two `vpcmp` into mask registers, two `kmovq`, two `popcnt`, the adds), at 43 GB/s on this host against about 75 on baseline-final's. Wave 4's runs, on their own orb, read the same as this one (`Utf16FromUtf8` 0.64–0.65, `CountUtf8` 0.99–1.02, `ValidateUtf8Err` 1.77–1.82, `Utf8ToUtf32` 1.11 native, [calls-20261031.md](calls-20261031.md)), so baseline-final's host is the one that differs. Dispatched `Utf16FromUtf32` is 0.92 of `66fa49c`: its loop is instruction for instruction the same, at another address (layout; wave 4 saw it natively).

So a per-operation change in the table below, against baseline-final, is the code only where it is larger than the host moved that operation. For wave 5's own effect, use the paired A/Bs in [short-20261101.md](short-20261101.md).

## Per operation against simdutf

utf ÷ simdutf, geomean of the operation's rows, baseline-final → this run, at each level; `(n<)` is how many of its rows are now under 1.0 beyond their interval.

| op                    |           icelake |          haswell |         westmere |          baseline |       ReleaseSafe |
| --------------------- | ----------------: | ---------------: | ---------------: | ----------------: | ----------------: |
| ValidateAscii         |       1.14 → 1.16 |      1.60 → 1.40 |      1.47 → 1.39 |       1.02 → 1.05 |  0.80 → 0.82 (4<) |
| ValidateAsciiErr      |  1.01 → 1.06 (1<) |      2.21 → 1.91 |      2.10 → 2.02 |  0.87 → 0.91 (4<) |  0.71 → 0.71 (5<) |
| ValidateUtf8          |       1.34 → 1.57 |      1.31 → 1.51 |      1.26 → 1.30 |  1.32 → 1.46 (1<) |       1.17 → 1.29 |
| ValidateUtf8Err       |       2.89 → 1.82 |      2.36 → 1.46 |      1.25 → 1.30 |       2.78 → 1.74 |       2.41 → 1.49 |
| ValidateUtf16le       |  1.08 → 1.09 (2<) |      4.04 → 4.13 |      1.66 → 1.81 |  1.04 → 1.05 (1<) | 0.95 → 0.85 (11<) |
| ValidateUtf16leErr    |       1.16 → 1.51 |      4.01 → 4.08 |      1.54 → 1.75 |       1.10 → 1.47 |  1.00 → 1.18 (1<) |
| ValidateUtf16be       |  1.25 → 1.40 (1<) |      3.83 → 3.73 |      1.35 → 1.65 |  1.21 → 1.40 (1<) |  1.10 → 1.06 (2<) |
| ValidateUtf16beErr    |       1.28 → 1.46 |      3.74 → 3.63 |      1.27 → 1.51 |       1.24 → 1.41 |  1.12 → 1.10 (1<) |
| ValidateUtf32         |       1.18 → 1.21 |      1.23 → 1.66 |      1.37 → 1.67 |  1.13 → 1.16 (1<) | 0.89 → 0.81 (13<) |
| ValidateUtf32Err      |       1.00 → 1.10 |      3.59 → 3.72 |      4.07 → 4.68 |  0.95 → 1.02 (2<) | 0.80 → 0.74 (12<) |
| Utf8ToUtf16le         |  1.23 → 1.15 (4<) |      1.76 → 1.56 |      1.48 → 1.53 |  1.20 → 1.13 (4<) |  1.15 → 1.15 (3<) |
| ValidUtf8ToUtf16le    |  1.32 → 1.25 (3<) | 1.47 → 1.38 (1<) |      1.38 → 1.38 |  1.28 → 1.23 (1<) |  1.24 → 1.24 (2<) |
| Utf8ToUtf16be         |  1.26 → 1.18 (4<) |      1.79 → 1.62 |      1.54 → 1.45 |  1.24 → 1.16 (2<) |  1.18 → 1.17 (4<) |
| ValidUtf8ToUtf16be    |  1.35 → 1.32 (1<) |      1.48 → 1.49 |      1.43 → 1.36 |  1.32 → 1.30 (1<) |  1.29 → 1.28 (2<) |
| Utf8ToUtf32           |  1.51 → 1.12 (1<) |      1.62 → 1.41 |      1.37 → 1.37 |       1.45 → 1.08 |  1.40 → 1.10 (1<) |
| ValidUtf8ToUtf32      |  1.14 → 1.03 (2<) |      1.41 → 1.40 |      1.26 → 1.23 |  1.13 → 1.02 (3<) |  1.09 → 1.02 (3<) |
| Utf8ToLatin1          |       0.98 → 1.11 |      2.38 → 1.69 |      1.73 → 1.73 |       0.92 → 1.09 |  0.82 → 0.96 (6<) |
| ValidUtf8ToLatin1     |  0.87 → 1.03 (4<) |      1.52 → 1.60 |      1.62 → 1.56 |  0.83 → 0.98 (5<) |  0.71 → 0.87 (6<) |
| Utf16leToUtf8         |  1.31 → 1.33 (2<) |      1.47 → 1.45 | 1.47 → 1.40 (2<) |  1.26 → 1.26 (2<) |  1.18 → 1.24 (3<) |
| ValidUtf16leToUtf8    |  1.29 → 1.33 (1<) |      1.45 → 1.37 | 1.42 → 1.31 (1<) |  1.28 → 1.32 (2<) |  1.16 → 1.23 (3<) |
| Utf16leToUtf16be      |       1.41 → 1.43 |      2.74 → 3.07 |      1.65 → 1.80 |       1.38 → 1.44 |  1.01 → 1.21 (2<) |
| ValidUtf16leToUtf16be |  0.94 → 0.90 (3<) | 0.99 → 1.02 (2<) | 1.01 → 1.03 (1<) |  0.93 → 0.96 (3<) |  0.83 → 0.95 (3<) |
| Utf16leToUtf32        |  1.07 → 1.08 (1<) |      1.19 → 1.16 |      1.34 → 1.35 |  1.06 → 1.06 (1<) | 1.00 → 0.94 (12<) |
| ValidUtf16leToUtf32   |  1.08 → 1.09 (1<) |      1.20 → 1.26 |      1.32 → 1.42 |       1.07 → 1.08 | 0.99 → 0.94 (10<) |
| Utf16leToLatin1       |  0.94 → 0.99 (6<) | 1.69 → 1.75 (1<) |      1.71 → 1.84 |  0.87 → 0.94 (3<) | 0.78 → 0.77 (11<) |
| ValidUtf16leToLatin1  |  1.13 → 1.07 (5<) |      1.27 → 1.26 |      2.11 → 1.88 |  1.05 → 1.03 (1<) |  0.90 → 0.85 (8<) |
| Utf16beToUtf8         |  1.27 → 1.31 (2<) |      1.47 → 1.42 |      1.45 → 1.44 |  1.26 → 1.29 (2<) |  1.15 → 1.22 (3<) |
| ValidUtf16beToUtf8    |  1.30 → 1.31 (1<) |      1.44 → 1.42 | 1.42 → 1.32 (1<) |  1.27 → 1.29 (1<) |  1.18 → 1.22 (3<) |
| Utf16beToUtf16le      |       1.37 → 1.45 |      2.89 → 3.13 |      1.72 → 1.83 |       1.42 → 1.47 |  1.06 → 1.27 (1<) |
| ValidUtf16beToUtf16le |  0.93 → 0.97 (3<) | 0.99 → 1.00 (1<) |      1.01 → 1.04 |  0.94 → 0.96 (1<) |  0.84 → 0.95 (2<) |
| Utf16beToUtf32        |  1.10 → 1.11 (1<) |      1.07 → 1.22 |      1.23 → 1.51 |  1.08 → 1.08 (2<) | 1.03 → 0.96 (12<) |
| ValidUtf16beToUtf32   |  1.10 → 1.10 (2<) |      1.11 → 1.35 |      1.36 → 1.53 |  1.09 → 1.08 (2<) | 1.03 → 0.95 (11<) |
| Utf16beToLatin1       |  0.96 → 1.02 (2<) |      1.68 → 1.68 |      1.50 → 1.65 |  0.90 → 0.97 (4<) | 0.80 → 0.80 (10<) |
| ValidUtf16beToLatin1  |  1.18 → 1.11 (5<) |      1.38 → 1.43 |      2.13 → 2.10 |  1.09 → 1.07 (3<) |  0.94 → 0.89 (5<) |
| Utf32ToUtf8           |       1.81 → 1.97 |      1.30 → 1.27 |      1.50 → 1.41 |       1.76 → 1.94 |       1.59 → 1.66 |
| ValidUtf32ToUtf8      |       1.94 → 1.94 |      1.38 → 1.30 |      1.53 → 1.45 |       1.88 → 1.89 |       1.71 → 1.68 |
| Utf32ToUtf16le        |  1.11 → 1.15 (1<) |      1.33 → 1.73 | 1.09 → 1.17 (1<) |  1.11 → 1.16 (3<) |  0.96 → 0.95 (5<) |
| ValidUtf32ToUtf16le   |       1.27 → 1.36 |      1.98 → 2.45 |      1.88 → 1.65 |  1.22 → 1.33 (1<) |  1.07 → 1.12 (2<) |
| Utf32ToUtf16be        |  1.23 → 1.33 (2<) |      1.44 → 1.76 |      1.00 → 1.23 |       1.19 → 1.29 |  1.05 → 1.04 (2<) |
| ValidUtf32ToUtf16be   |  1.46 → 1.50 (1<) |      1.95 → 2.49 |      1.75 → 1.72 |       1.43 → 1.47 |  1.26 → 1.26 (1<) |
| Utf32ToLatin1         |  1.01 → 1.09 (2<) |      1.29 → 1.31 |      1.16 → 1.14 |  0.95 → 1.06 (3<) |  0.93 → 1.02 (4<) |
| ValidUtf32ToLatin1    |  1.12 → 1.14 (1<) |      1.41 → 1.31 |      1.42 → 1.40 |  1.06 → 1.08 (3<) |  1.02 → 1.08 (2<) |
| Latin1ToUtf8          |  0.90 → 1.05 (2<) |      1.70 → 1.79 |      1.45 → 1.42 |       0.85 → 0.99 |  0.79 → 0.95 (3<) |
| ValidLatin1ToUtf8     |       0.90 → 1.06 |      1.69 → 1.79 |      1.44 → 1.42 |  0.87 → 1.00 (1<) |  0.80 → 0.95 (5<) |
| Latin1ToUtf16le       |  0.97 → 0.98 (3<) | 1.01 → 1.09 (2<) |      0.88 → 1.06 |  0.88 → 0.90 (3<) |  0.89 → 0.92 (5<) |
| ValidLatin1ToUtf16le  |  0.99 → 0.97 (3<) |      1.06 → 1.07 |      0.92 → 1.07 |  0.91 → 0.92 (3<) |  0.90 → 0.92 (6<) |
| Latin1ToUtf16be       |  0.97 → 0.97 (5<) |      1.00 → 1.09 |      1.05 → 1.05 |  0.88 → 0.88 (3<) |  0.88 → 0.87 (7<) |
| ValidLatin1ToUtf16be  |  1.00 → 0.96 (5<) |      1.05 → 1.13 |      1.09 → 1.08 |  0.91 → 0.89 (8<) |  0.91 → 0.92 (6<) |
| Latin1ToUtf32         |  1.08 → 0.98 (7<) | 1.06 → 1.08 (2<) |      1.04 → 1.07 |  0.96 → 0.91 (6<) |  1.02 → 0.95 (4<) |
| ValidLatin1ToUtf32    |  1.10 → 0.97 (8<) |      1.12 → 1.11 |      1.07 → 1.12 |  1.00 → 0.92 (6<) |  1.02 → 0.95 (8<) |
| Utf16FromUtf8         | 1.17 → 0.65 (12<) |      1.30 → 1.61 | 1.34 → 1.43 (1<) | 1.13 → 0.64 (12<) | 0.61 → 0.55 (12<) |
| Utf16FromUtf32        |  1.06 → 1.02 (3<) |      1.66 → 2.14 |      1.76 → 2.20 | 1.01 → 0.94 (13<) | 0.46 → 0.64 (13<) |
| Utf8FromUtf16le       | 1.07 → 0.91 (13<) | 1.01 → 1.09 (1<) |      1.02 → 1.26 | 1.05 → 0.88 (12<) | 0.65 → 0.84 (13<) |
| Utf8FromUtf16be       | 1.06 → 0.96 (11<) |      1.14 → 1.36 |      1.17 → 1.06 | 1.03 → 0.93 (13<) | 0.82 → 0.79 (13<) |
| Utf8FromUtf32         | 1.30 → 0.86 (13<) |      1.09 → 1.04 |      1.07 → 1.06 | 1.26 → 0.82 (12<) | 0.80 → 0.70 (14<) |
| Utf8FromLatin1        |  1.22 → 0.85 (7<) | 1.04 → 1.01 (3<) | 1.00 → 0.97 (3<) |  1.11 → 0.80 (6<) |  0.67 → 0.65 (8<) |
| CountUtf8             | 1.55 → 1.02 (10<) |      1.21 → 1.17 | 1.23 → 1.27 (1<) | 1.49 → 0.96 (11<) | 0.67 → 0.64 (12<) |
| CountUtf16le          |       1.04 → 1.21 | 1.94 → 2.01 (1<) |      2.28 → 2.08 |  1.00 → 1.14 (2<) |  0.64 → 0.93 (8<) |
| CountUtf16be          |       1.23 → 1.12 |      2.03 → 2.18 |      2.29 → 2.04 |  1.20 → 1.08 (1<) | 0.77 → 0.88 (11<) |
| Base64Encode          |  1.00 → 1.00 (1<) | 1.23 → 1.13 (1<) |      1.05 → 1.03 |       0.90 → 0.96 |  0.82 → 0.79 (4<) |
| Base64EncodeUrl       |  0.97 → 1.00 (1<) |      1.23 → 1.12 |      1.05 → 1.02 |  0.91 → 0.98 (3<) |  0.83 → 0.80 (5<) |
| Base64Decode          |  1.17 → 1.19 (2<) |      1.30 → 1.34 |      1.16 → 1.29 |       1.11 → 1.11 |  1.07 → 1.12 (2<) |
| Base64DecodeUrl       |  1.16 → 1.20 (2<) |      1.26 → 1.33 |      1.09 → 1.24 |       1.11 → 1.18 |  1.08 → 1.08 (2<) |
| Base64DecodeStrict    |  1.17 → 1.19 (2<) |      1.28 → 1.29 |      1.12 → 1.27 |  1.10 → 1.09 (2<) |  1.06 → 1.11 (2<) |
| Base64DecodePartial   |  1.20 → 1.23 (1<) |      1.32 → 1.36 |      1.17 → 1.32 |  1.14 → 1.13 (1<) |       1.11 → 1.16 |
| Base64DecodeMime      |       1.12 → 1.13 |      1.34 → 1.35 |      1.31 → 1.23 |  1.04 → 1.08 (1<) |  0.92 → 0.94 (3<) |
| all                   |       1.18 → 1.15 |      1.55 → 1.59 |      1.39 → 1.44 |       1.13 → 1.11 |       0.97 → 0.98 |

## Under simdutf

Every operation whose geomean is under simdutf at each level, against its baseline-final figure, with its rows under beyond their interval split into short (16, 64, and 256 code units) and long, its slowest row, and the reason. "Harness loop" is the Zig arm's per-call cost in the harness, measured on `Latin1ToUtf8` and `Latin1ToUtf16le` ([short-20261101.md](short-20261101.md#the-harness-loop)): for other operations it is suspected, not shown. "Host" is [Two hosts](#two-hosts). "Code as `39088d1`" means the harness wrapper's instructions are the same in a `39088d1` build and the final tree ([fndiff.py](short-20261101/fndiff.py)), so wave 5 did not change it. Made by [under.py](baseline-wave5-20261101/under.py).

### icelake: 14 operations

| op                    | wave 5 | baseline-final | rows under (short, long) | slowest              | reason                                                                                                      |
| --------------------- | -----: | -------------: | -----------------------: | -------------------- | ----------------------------------------------------------------------------------------------------------- |
| Utf16FromUtf8         |   0.65 |           1.17 |                    0, 12 | `ascii-1048576` 0.49 | host: same loop as `66fa49c`, which reads the same here                                                     |
| Utf8FromLatin1        |   0.85 |           1.22 |                     0, 7 | `latin1-65536` 0.46  | host: same loop as `66fa49c`, which reads the same here                                                     |
| Utf8FromUtf32         |   0.86 |           1.30 |                    1, 12 | `hindi` 0.79         | host: same loop as `66fa49c`, which reads the same here                                                     |
| ValidUtf16leToUtf16be |   0.90 |           0.94 |                     3, 0 | `ascii-64` 0.52      | short rows; code as `39088d1`; unexplained (harness loop suspected)                                         |
| Utf8FromUtf16le       |   0.91 |           1.07 |                    1, 12 | `korean` 0.77        | host: same loop as `66fa49c`, which reads the same here                                                     |
| ValidLatin1ToUtf16be  |   0.96 |           1.00 |                     3, 2 | `ascii-16` 0.85      | short rows; harness loop suspected (measured on UTF-16LE)                                                   |
| Utf8FromUtf16be       |   0.96 |           1.06 |                    0, 11 | `chinese` 0.81       | host: same loop as `66fa49c`, which reads the same here                                                     |
| ValidUtf16beToUtf16le |   0.97 |           0.93 |                     3, 0 | `ascii-256` 0.78     | short rows; code as `39088d1`; unexplained (harness loop suspected)                                         |
| ValidLatin1ToUtf16le  |   0.97 |           0.99 |                     2, 1 | `latin1-16` 0.80     | short rows; harness loop suspected (measured on the checked form)                                           |
| Latin1ToUtf16be       |   0.97 |           0.97 |                     2, 3 | `latin1-256` 0.93    | short rows; harness loop suspected (measured on UTF-16LE)                                                   |
| ValidLatin1ToUtf32    |   0.97 |           1.10 |                     3, 5 | `ascii-256` 0.91     | short rows; harness loop suspected; long rows 0.96–0.99                                                     |
| Latin1ToUtf16le       |   0.98 |           0.97 |                     2, 1 | `ascii-16` 0.80      | short rows: harness loop (measured, 3 ns a call)                                                            |
| Latin1ToUtf32         |   0.98 |           1.08 |                     4, 3 | `ascii-256` 0.91     | short rows; harness loop suspected; host (0.99 of `icelake` in `host/len2`, where `66fa49c` reads the same) |
| Utf16leToLatin1       |   0.99 |           0.94 |                     3, 3 | `ascii-16` 0.76      | layout and noise: code as `39088d1`, 1.01 of `icelake` in `host/len2`                                       |

### westmere: 1 operation

| op             | wave 5 | baseline-final | rows under (short, long) | slowest         | reason                                                   |
| -------------- | -----: | -------------: | -----------------------: | --------------- | -------------------------------------------------------- |
| Utf8FromLatin1 |   0.97 |           1.00 |                     3, 0 | `ascii-64` 0.85 | three 64-byte rows; unexplained (harness loop suspected) |

### baseline: 22 operations

| op                    | wave 5 | baseline-final | rows under (short, long) | slowest            | reason                                                                                                                  |
| --------------------- | -----: | -------------: | -----------------------: | ------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| Utf16FromUtf8         |   0.64 |           1.13 |                    0, 12 | `russian` 0.50     | host: same loop as `66fa49c`, which reads the same here (the tier object runs it)                                       |
| Utf8FromLatin1        |   0.80 |           1.11 |                     0, 6 | `ascii-65536` 0.50 | host: same loop as `66fa49c`, which reads the same here (the tier object runs it)                                       |
| Utf8FromUtf32         |   0.82 |           1.26 |                    0, 12 | `ascii-65536` 0.71 | host: same loop as `66fa49c`, which reads the same here (the tier object runs it)                                       |
| Latin1ToUtf16be       |   0.88 |           0.88 |                     3, 0 | `latin1-16` 0.68   | short rows only: dispatched call plus harness loop (measured on Latin-1 to UTF-8 and UTF-16LE)                          |
| Utf8FromUtf16le       |   0.88 |           1.05 |                    1, 11 | `latin` 0.76       | host: same loop as `66fa49c`, which reads the same here (the tier object runs it)                                       |
| ValidLatin1ToUtf16be  |   0.89 |           0.91 |                     6, 2 | `latin1-16` 0.66   | short rows: dispatched call plus harness loop; long rows 0.99                                                           |
| Latin1ToUtf16le       |   0.90 |           0.88 |                     3, 0 | `latin1-16` 0.64   | short rows only: dispatched call plus harness loop (measured on Latin-1 to UTF-8 and UTF-16LE)                          |
| ValidateAsciiErr      |   0.91 |           0.87 |                     2, 2 | `ascii-4096` 0.76  | unexplained: unchanged since `baseline-final` (0.87), `ascii-4096` 0.76                                                 |
| Latin1ToUtf32         |   0.91 |           0.96 |                     5, 1 | `ascii-16` 0.72    | short rows: dispatched call plus harness loop; long row 0.98                                                            |
| ValidLatin1ToUtf16le  |   0.92 |           0.91 |                     3, 0 | `latin1-16` 0.69   | short rows only: dispatched call plus harness loop (measured on Latin-1 to UTF-8 and UTF-16LE)                          |
| ValidLatin1ToUtf32    |   0.92 |           1.00 |                     5, 1 | `latin1-16` 0.80   | short rows: dispatched call plus harness loop; long row 0.96                                                            |
| Utf8FromUtf16be       |   0.93 |           1.03 |                    1, 12 | `emoji` 0.79       | host: same loop as `66fa49c`, which reads the same here (the tier object runs it)                                       |
| Utf16leToLatin1       |   0.94 |           0.87 |                     3, 0 | `latin1-16` 0.67   | short rows only: dispatched call plus harness loop (measured on Latin-1 to UTF-8 and UTF-16LE)                          |
| Utf16FromUtf32        |   0.94 |           1.01 |                    2, 11 | `ascii-256` 0.87   | layout and host: its loop is instruction for instruction `66fa49c`'s, which reads 1.09× here (`host/len4`); native 1.02 |
| ValidUtf16leToUtf16be |   0.96 |           0.93 |                     3, 0 | `ascii-64` 0.72    | short rows only: dispatched call plus harness loop (measured on Latin-1 to UTF-8 and UTF-16LE)                          |
| ValidUtf16beToUtf16le |   0.96 |           0.94 |                     1, 0 | `ascii-256` 0.86   | short rows only: dispatched call plus harness loop (measured on Latin-1 to UTF-8 and UTF-16LE)                          |
| CountUtf8             |   0.96 |           1.49 |                    0, 11 | `hebrew` 0.84      | host: same loop as `66fa49c`, which reads the same here (the tier object runs it)                                       |
| Base64Encode          |   0.96 |           0.90 |                     0, 0 | -                  | no row under beyond its interval                                                                                        |
| Utf16beToLatin1       |   0.97 |           0.90 |                     4, 0 | `latin1-16` 0.72   | short rows only: dispatched call plus harness loop (measured on Latin-1 to UTF-8 and UTF-16LE)                          |
| ValidUtf8ToLatin1     |   0.98 |           0.83 |                     5, 0 | `ascii-256` 0.68   | short rows only: dispatched call plus harness loop (measured on Latin-1 to UTF-8 and UTF-16LE)                          |
| Base64EncodeUrl       |   0.98 |           0.91 |                     2, 1 | `random-16` 0.87   | short rows: dispatched call plus harness loop; `random-1048576` 0.97                                                    |
| Latin1ToUtf8          |   0.99 |           0.85 |                     0, 0 | -                  | no row under beyond its interval                                                                                        |

### ReleaseSafe: 38 operations

| op                    | wave 5 | baseline-final | native ReleaseFast | rows under (short, long) | reason                                           |
| --------------------- | -----: | -------------: | -----------------: | -----------------------: | ------------------------------------------------ |
| Utf16FromUtf8         |   0.55 |           0.61 |               0.65 |                    0, 12 | safety checks (decision 5); host, as native      |
| Utf16FromUtf32        |   0.64 |           0.46 |               1.02 |                    2, 11 | safety checks (decision 5)                       |
| CountUtf8             |   0.64 |           0.67 |               1.02 |                    0, 12 | safety checks (decision 5)                       |
| Utf8FromLatin1        |   0.65 |           0.67 |               0.85 |                     1, 7 | safety checks (decision 5); host, as native      |
| Utf8FromUtf32         |   0.70 |           0.80 |               0.86 |                    2, 12 | safety checks (decision 5); host, as native      |
| ValidateAsciiErr      |   0.71 |           0.71 |               1.06 |                     1, 4 | safety checks (decision 5)                       |
| ValidateUtf32Err      |   0.74 |           0.80 |               1.10 |                    1, 11 | safety checks (decision 5)                       |
| Utf16leToLatin1       |   0.77 |           0.78 |               0.99 |                     6, 5 | safety checks (decision 5); also under in native |
| Utf8FromUtf16be       |   0.79 |           0.82 |               0.96 |                    1, 12 | safety checks (decision 5); host, as native      |
| Base64Encode          |   0.79 |           0.82 |               1.00 |                     3, 1 | safety checks (decision 5)                       |
| Utf16beToLatin1       |   0.80 |           0.80 |               1.02 |                     5, 5 | safety checks (decision 5)                       |
| Base64EncodeUrl       |   0.80 |           0.83 |               1.00 |                     3, 2 | safety checks (decision 5)                       |
| ValidateUtf32         |   0.81 |           0.89 |               1.21 |                    1, 12 | safety checks (decision 5)                       |
| ValidateAscii         |   0.82 |           0.80 |               1.16 |                     0, 4 | safety checks (decision 5)                       |
| Utf8FromUtf16le       |   0.84 |           0.65 |               0.91 |                    1, 12 | safety checks (decision 5); host, as native      |
| ValidateUtf16le       |   0.85 |           0.95 |               1.09 |                    1, 10 | safety checks (decision 5)                       |
| ValidUtf16leToLatin1  |   0.85 |           0.90 |               1.07 |                     6, 2 | safety checks (decision 5)                       |
| ValidUtf8ToLatin1     |   0.87 |           0.71 |               1.03 |                     2, 4 | safety checks (decision 5)                       |
| Latin1ToUtf16be       |   0.87 |           0.88 |               0.97 |                     6, 1 | safety checks (decision 5); also under in native |
| CountUtf16be          |   0.88 |           0.77 |               1.12 |                     2, 9 | safety checks (decision 5)                       |
| ValidUtf16beToLatin1  |   0.89 |           0.94 |               1.11 |                     5, 0 | safety checks (decision 5)                       |
| Latin1ToUtf16le       |   0.92 |           0.89 |               0.98 |                     4, 1 | safety checks (decision 5); also under in native |
| ValidLatin1ToUtf16le  |   0.92 |           0.90 |               0.97 |                     3, 3 | safety checks (decision 5); also under in native |
| ValidLatin1ToUtf16be  |   0.92 |           0.91 |               0.96 |                     5, 1 | safety checks (decision 5); also under in native |
| CountUtf16le          |   0.93 |           0.64 |               1.21 |                     2, 6 | safety checks (decision 5)                       |
| Utf16leToUtf32        |   0.94 |           1.00 |               1.08 |                    2, 10 | safety checks (decision 5)                       |
| ValidUtf16leToUtf32   |   0.94 |           0.99 |               1.09 |                     2, 8 | safety checks (decision 5)                       |
| Base64DecodeMime      |   0.94 |           0.92 |               1.13 |                     1, 2 | safety checks (decision 5)                       |
| ValidUtf16leToUtf16be |   0.95 |           0.83 |               0.90 |                     3, 0 | safety checks (decision 5); also under in native |
| ValidUtf16beToUtf16le |   0.95 |           0.84 |               0.97 |                     2, 0 | safety checks (decision 5); also under in native |
| ValidUtf16beToUtf32   |   0.95 |           1.03 |               1.10 |                     2, 9 | safety checks (decision 5)                       |
| Utf32ToUtf16le        |   0.95 |           0.96 |               1.15 |                     2, 3 | safety checks (decision 5)                       |
| Latin1ToUtf8          |   0.95 |           0.79 |               1.05 |                     1, 2 | safety checks (decision 5)                       |
| ValidLatin1ToUtf8     |   0.95 |           0.80 |               1.06 |                     1, 4 | safety checks (decision 5)                       |
| Latin1ToUtf32         |   0.95 |           1.02 |               0.98 |                     2, 2 | safety checks (decision 5); also under in native |
| ValidLatin1ToUtf32    |   0.95 |           1.02 |               0.97 |                     4, 4 | safety checks (decision 5); also under in native |
| Utf8ToLatin1          |   0.96 |           0.82 |               1.11 |                     3, 3 | safety checks (decision 5)                       |
| Utf16beToUtf32        |   0.96 |           1.03 |               1.11 |                    2, 10 | safety checks (decision 5)                       |

In the ReleaseSafe table "native ReleaseFast" is the same operation in the icelake column: same code, same host, only the optimization mode differs, so what ReleaseSafe loses beyond it is the checks.

## Peak RSS

GNU `time` around one `check` pass per arm and operation, as in baseline-final ([its Peak RSS](baseline-final-20261031.md#peak-rss) explains what it counts). Each arm against utf over every operation it has, and utf against baseline-final, MiB:

| level       |      simdutf |          std |         Rust |           Go | utf, wave 5 − baseline-final |
| ----------- | -----------: | -----------: | -----------: | -----------: | ---------------------------: |
| icelake     | +3.1 to +3.4 | −0.3 to −0.2 | +0.2 to +1.5 | +0.6 to +1.5 |                 +0.0 to +0.1 |
| haswell     | +3.2 to +3.4 | −0.3 to −0.2 | +0.2 to +1.5 | +0.6 to +1.5 |                 −0.1 to +0.0 |
| westmere    | +3.2 to +3.4 | −0.2 to −0.1 | +0.2 to +1.5 | +0.6 to +1.5 |                 −0.1 to +0.1 |
| baseline    | +3.0 to +3.2 | −0.4 to −0.4 | +0.0 to +1.2 | +0.4 to +1.3 |                 −0.2 to +0.0 |
| ReleaseSafe | +3.0 to +3.2 | −0.5 to −0.4 | +0.0 to +1.3 | +0.4 to +1.2 |                 −0.1 to +0.1 |

utf's peak is 2.4–11.2 MiB by operation (ASCII validation to UTF-32 to Latin-1, whose inputs are four bytes a character): the data, as before. The out-of-line long paths in the tier objects did not move it.

## Files

In [baseline-wave5-20261101/](baseline-wave5-20261101/), one directory per level (`native`, `haswell`, `westmere`, `baseline`, `safe`), each what `just bench-compare` left in `zig-out/bench-compare/`, less the checksums and the servers' raw output, as in baseline-final: `config.txt`, `summary.txt` (per operation against every arm: the table baseline-final prints per level), `rows.txt`, `rss.txt`, and, gzipped, `benchstat.txt` and each arm's per-round GB/s. `host/` holds the runs in [Two hosts](#two-hosts) (`len`, `len2`, `len3`, `len4`: `summary.txt`, `rows.txt`, each arm's per-round GB/s). [cmp.py](baseline-wave5-20261101/cmp.py) makes the comparison tables from this directory and baseline-final's (`cmp.py ../baseline-final-20261031 . native haswell westmere baseline safe`); [under.py](baseline-wave5-20261101/under.py) the tables of operations under simdutf.

To reproduce a level: `just bench-compare` (native), `just cpu=x86_64_v3 dispatch=false kernel=haswell bench-compare`, `just cpu=x86_64_v2 dispatch=false kernel=westmere bench-compare`, `just cpu=baseline bench-compare`, `just optimize=ReleaseSafe bench-compare`, with nothing else running.
