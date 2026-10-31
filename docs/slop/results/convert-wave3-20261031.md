# Transcoding wave 3: the rows under simdutf, 2026-10-31

Wave 3 of `src/convert.zig` and `src/length.zig`, with two additions to `src/simd.zig`: rerun every transcoding and length operation on `6edad68` (after the wave-3 dispatch, shared-helper, and harness fixes moved the short rows), then close the rows under 1.0 against simdutf 9.2.1 at the matching ISA.

- Machine: Amp orb, KVM guest, Intel Xeon @ 2.60GHz (Ice Lake server, family 6 model 106, AVX-512 with VBMI2), 2 cores × 2 threads; every timed process pinned to CPU 3, builds pinned to CPUs 0-1, and nothing built while anything was timed (a build on the other core moved an A/B by about 30%).
- Zig 0.16.0 ReleaseFast. `native` runs the AVX-512 kernels (`v512`), `x86_64_v3` with `dispatch=false` AVX2, `x86_64_v2` with `dispatch=false` SSE.
- Harness: `just bench-compare 3` over the 49 conversion and length operations ([final.sh](convert-wave3-20261031/final.sh)), native against simdutf's `icelake`, `cpu=x86_64_v3 dispatch=false kernel=haswell`, and `cpu=x86_64_v2 dispatch=false kernel=westmere`; before on `6edad68` ([before/](convert-wave3-20261031/before/)), after on this branch ([after/](convert-wave3-20261031/after/)). Ratios are utf ÷ simdutf, the median of the rounds per row, geomeans per op from [opgeo.py](convert-wave3-20261031/opgeo.py).
- Interleaved A/B: the harness's own binaries, one per arm built by [hb.sh](convert-wave3-20261031/hb.sh), run by [hrun.sh](convert-wave3-20261031/hrun.sh) in rotating order, one invocation per arm per round, with simdutf's arm at the matching kernel as the third; 3 or 5 rounds, benchstat over the rounds, ratios from [cmp.py](convert-wave3-20261031/cmp.py) and [cmp4.py](convert-wave3-20261031/cmp4.py) (median GB/s per row). `old` is `6edad68`. Raw output (gzipped) and benchstat in [ab/](convert-wave3-20261031/ab/).
- Layout driver: [lay/lay.zig](convert-wave3-20261031/lay/lay.zig) calls one of our functions out of line and simdutf's through its C API, on an input at a chosen offset from a page and an output at another, interleaved sample by sample. It settles rows that the harness's arena puts at one alignment.

## Takeaways

- **Against simdutf, harness** (701 rows, geomean of utf ÷ simdutf): `icelake` 1.25 to 1.29, `haswell` 1.38 to 1.55, `westmere` 1.32 to 1.38. Rows under 1.0: 139 to 114 native, 139 to 51 AVX2, 194 to 112 SSE. Per op in the table below. Read the harness's before and after as two processes: every arm's rows move up to ±50% between processes (simdutf's own `Utf16leToUtf8/korean` at `haswell` read 6.05 GB/s in one run and 7.99 in another), so the per-change numbers below come from interleaved A/Bs in one process per arm and round, and the layout driver.
- **Against `6edad68`, interleaved** (the harness's binaries, rotating, `old` and this branch with simdutf as the third arm): UTF-16 to UTF-8 on Korean and Hindi 1.31× on AVX2 (0.79-0.81 of `haswell` to 0.99-1.08); UTF-16 to UTF-8 on Cyrillic and Hebrew 1.35-1.43× on AVX2; UTF-32 to UTF-8 1.13× on AVX2, 1.12× on SSE; Latin-1 to UTF-8 1.21× on AVX2, 1.11× on SSE; the checked byte swap 1.32× on AVX2 and SSE, 1.11× native, emoji 0.69-0.93×; UTF-32 to UTF-16 1.06-1.23× native; `utf8FromUtf16le` 1.05-1.19×, `utf8FromUtf16be` 1.19-1.22×, and `utf8FromUtf32` 1.12-1.15× on SSE and AVX2. All 49 ops native, 3 rounds ([ab/fin-nat](convert-wave3-20261031/ab/fin-nat/summary.txt)): 1.05× `old`, 1.23 of `icelake`, where ops whose code did not change (`utf16FromUtf8`, `countUtf16le`/`be` on AVX-512) read 0.86-0.98: a function's address moves its rows ±15%. The identical `utf8FromUtf16le` code at two addresses read 1.05× and 1.19× `old` in one run (`be-sse`).
- **Memory.** No allocation. Peak RSS (`rss.txt`) the same as before to ±0.1 MiB at each level, 0.2-0.5 MiB over Zig std's where std has the operation, as in wave 2.
- **Correctness**: every gate passes, `just oracle` 0 mismatches; the harness's checksum caught a length bug the tests missed (below), fixed with a test.

## Against simdutf, harness, before and after

Geomean utf ÷ simdutf per op, `6edad68` ([before/](convert-wave3-20261031/before/)) and this branch ([after/](convert-wave3-20261031/after/)), from [table.py](convert-wave3-20261031/table.py). `6edad68` to `d904359` changed only validation and base64.

| op                    | icelake before | after | haswell before | after | westmere before | after |
| --------------------- | -------------: | ----: | -------------: | ----: | --------------: | ----: |
| Utf8ToUtf16le         |           1.20 |  1.19 |           1.75 |  1.80 |            1.57 |  1.55 |
| ValidUtf8ToUtf16le    |           1.34 |  1.43 |           1.50 |  1.51 |            1.38 |  1.31 |
| Utf8ToUtf16be         |           1.38 |  1.41 |           1.77 |  1.72 |            1.53 |  1.46 |
| ValidUtf8ToUtf16be    |           1.43 |  1.47 |           1.52 |  1.65 |            1.41 |  1.40 |
| Utf8ToUtf32           |           1.51 |  1.56 |           1.63 |  1.84 |            1.36 |  1.26 |
| ValidUtf8ToUtf32      |           1.15 |  1.20 |           1.44 |  1.58 |            1.24 |  1.20 |
| Utf8ToLatin1          |           1.05 |  1.15 |           2.56 |  2.69 |            1.66 |  1.62 |
| ValidUtf8ToLatin1     |           1.07 |  0.93 |           1.62 |  1.50 |            1.61 |  1.54 |
| Utf16leToUtf8         |           1.27 |  1.17 |           1.15 |  1.36 |            1.30 |  1.39 |
| ValidUtf16leToUtf8    |           1.36 |  1.15 |           1.22 |  1.35 |            1.34 |  1.38 |
| Utf16leToUtf16be      |           1.28 |  1.46 |           1.98 |  2.87 |            1.17 |  1.58 |
| ValidUtf16leToUtf16be |           1.05 |  1.07 |           1.07 |  1.13 |            0.98 |  1.08 |
| Utf16leToUtf32        |           1.32 |  1.36 |           1.19 |  1.51 |            1.28 |  1.26 |
| ValidUtf16leToUtf32   |           1.27 |  1.54 |           1.32 |  1.34 |            1.41 |  1.34 |
| Utf16leToLatin1       |           1.15 |  1.18 |           1.60 |  1.85 |            1.57 |  1.66 |
| ValidUtf16leToLatin1  |           1.26 |  1.22 |           1.23 |  1.51 |            1.98 |  1.91 |
| Utf16beToUtf8         |           1.25 |  1.16 |           1.25 |  1.64 |            1.38 |  1.34 |
| ValidUtf16beToUtf8    |           1.31 |  1.17 |           1.25 |  1.53 |            1.39 |  1.32 |
| Utf16beToUtf16le      |           1.22 |  1.46 |           2.09 |  3.09 |            1.21 |  1.61 |
| ValidUtf16beToUtf16le |           1.02 |  1.11 |           1.08 |  1.23 |            1.00 |  1.08 |
| Utf16beToUtf32        |           1.19 |  1.27 |           1.16 |  1.27 |            1.33 |  1.20 |
| ValidUtf16beToUtf32   |           1.25 |  1.26 |           1.17 |  1.35 |            1.37 |  1.39 |
| Utf16beToLatin1       |           1.10 |  1.07 |           1.47 |  1.65 |            1.44 |  1.69 |
| ValidUtf16beToLatin1  |           1.28 |  1.25 |           1.31 |  1.35 |            2.01 |  2.46 |
| Utf32ToUtf8           |           2.02 |  1.84 |           1.12 |  1.40 |            1.33 |  1.61 |
| ValidUtf32ToUtf8      |           2.11 |  1.88 |           1.22 |  1.37 |            1.43 |  1.63 |
| Utf32ToUtf16le        |           1.03 |  1.20 |           1.47 |  1.58 |            1.07 |  1.26 |
| ValidUtf32ToUtf16le   |           1.26 |  1.43 |           2.04 |  2.12 |            1.75 |  2.04 |
| Utf32ToUtf16be        |           0.96 |  1.35 |           1.53 |  1.51 |            1.06 |  1.10 |
| ValidUtf32ToUtf16be   |           1.33 |  1.60 |           1.87 |  2.15 |            1.75 |  1.83 |
| Utf32ToLatin1         |           1.00 |  1.24 |           1.23 |  1.37 |            1.16 |  1.27 |
| ValidUtf32ToLatin1    |           1.09 |  1.25 |           1.42 |  1.62 |            1.35 |  1.50 |
| Latin1ToUtf8          |           1.02 |  1.09 |           1.44 |  2.00 |            1.36 |  1.53 |
| ValidLatin1ToUtf8     |           1.01 |  1.04 |           1.45 |  2.04 |            1.41 |  1.58 |
| Latin1ToUtf16le       |           1.04 |  1.15 |           1.11 |  1.37 |            0.95 |  0.96 |
| ValidLatin1ToUtf16le  |           1.08 |  1.18 |           1.20 |  1.45 |            1.00 |  0.99 |
| Latin1ToUtf16be       |           1.01 |  1.09 |           1.06 |  1.25 |            1.07 |  1.10 |
| ValidLatin1ToUtf16be  |           1.10 |  1.11 |           1.09 |  1.23 |            1.12 |  1.13 |
| Latin1ToUtf32         |           1.19 |  1.15 |           1.16 |  1.25 |            1.00 |  1.15 |
| ValidLatin1ToUtf32    |           1.15 |  1.15 |           1.22 |  1.25 |            1.04 |  1.18 |
| Utf16FromUtf8         |           1.28 |  1.25 |           1.32 |  1.25 |            1.23 |  1.34 |
| Utf16FromUtf32        |           1.28 |  1.42 |           1.66 |  1.60 |            1.75 |  1.75 |
| Utf8FromUtf16le       |           1.17 |  1.17 |           0.98 |  1.04 |            0.90 |  0.96 |
| Utf8FromUtf16be       |           1.22 |  1.14 |           0.93 |  1.17 |            0.95 |  0.91 |
| Utf8FromUtf32         |           1.47 |  1.30 |           1.02 |  1.00 |            0.93 |  0.97 |
| Utf8FromLatin1        |           1.54 |  1.55 |           1.30 |  1.17 |            1.10 |  1.06 |
| CountUtf8             |           1.75 |  1.81 |           1.36 |  1.50 |            1.21 |  1.14 |
| CountUtf16le          |           1.47 |  1.30 |           1.95 |  2.29 |            2.25 |  2.35 |
| CountUtf16be          |           1.55 |  1.55 |           2.04 |  2.31 |            2.21 |  2.25 |
| all                   |           1.25 |  1.29 |           1.38 |  1.55 |            1.32 |  1.38 |

## What changed

### UTF-16 and UTF-32 to UTF-8, AVX2 and SSE

- **The BMP encoder computes simdutf's byte layout.** `utf8FromBmp` (16 units below U+10000 with no surrogate, any mix of one, two, and three bytes) built each unit's bytes in order: a one-, two-, and three-byte form selected with two blends, fifteen operations. `bmpBytes` now builds the four candidate bytes the way simdutf's AVX2 kernel does: each unit's low byte twice (one `pshufb`) masked to the ASCII byte and the last continuation byte, and the three-byte lead with the middle continuation byte, where one `xor` turns the middle byte into the two-byte lead for units below U+0800. Ten operations, no blend; the shuffle table picks bytes 0; 3, 1; or 2, 3, 1. `utf8From16Three` (every unit three bytes) uses the same two vectors and a fixed shuffle where it widened to 32-bit lanes first. AVX2: UTF-16 to UTF-8 on Korean and Hindi 1.31× (0.79-0.81 of `haswell` to 0.99-1.08), Japanese 1.17-1.25×; UTF-32 to UTF-8 1.13× over the op ([ab/avx2-c](convert-wave3-20261031/ab/avx2-c/), arms `old`, `mid` without this change, `new`). SSE: 1.08-1.11× over UTF-16 and UTF-32 to UTF-8 (`sse-c`).
- **Two groups per `vpshufb` on AVX2.** `simd.shuffleLanes` is `pshufb` for any width, each 16-byte lane looking up its own bytes. `utf8From2x16` (16 units below U+0800) and `utf8FromBmp` load two groups' table rows into one register (a load and a `vinserti128`) and pack both with one 256-bit `vpshufb`; the masks come from byte movemasks and `pext`. UTF-16 to UTF-8 on Russian and Hebrew 1.35-1.43× on AVX2 (`avx2-b`).
- **UTF-32 to UTF-8** narrows a block below U+10000 to 16-bit lanes first (`simd.narrow`), so the surrogate check and the encoder take one register, and an ASCII block starts a loop of its own, as UTF-16 to UTF-8 has: the ASCII rows on SSE had moved 0.83-0.88 with layout on identical instructions (`sse-b`), and came back with the loop (`sse-c`, Utf32ToUtf8 geomean 1.12× `old`).

### Latin-1 to UTF-8

- AVX2 and SSE: a 64-byte block with a byte above 0x7F encodes all four 16-byte pieces without testing each for ASCII. AVX2 1.21× (`avx2-b`), SSE 1.11-1.12× (`sse-b`).
- AVX-512 (`latin1ToUtf8Avx512`): the upper half's high bits come from `pext` of the block's mask (no `kshiftrq`), and runs of non-ASCII blocks go through an inner loop that takes `min(rest / 64, room / 128)` blocks without room checks. Inputs up to 32 bytes finish before the loop loads its constants. In the layout driver, out of line with the output 2 KiB from the input ([lay/latin1-to-utf8.txt](convert-wave3-20261031/lay/latin1-to-utf8.txt)), Latin-1 text from 256 B to 64 KiB went from 0.77-0.84 of `icelake` to 0.77-0.88 (3-10% faster), ASCII 1.0-1.5. The harness A/B read 0.90× `old` on the op in one run and 1.11× in another (`fin-nat`, `nat-d`).

### AVX-512 UTF-16 to UTF-8

- A block of 32 units that is all two-byte, or all below U+10000 with no surrogate, stores whole registers where the output has 128 bytes of room, not masked stores of computed length. Two-byte scripts 1.10-1.34× (now at or above `icelake`), CJK 1.15-1.35× (`nat-b`).

### Short inputs on AVX-512

Each AVX-512 kernel loads 20-25 constants before its loop, 2-4 ns on a short call. An ASCII prefix check now runs before them: up to 32 units in `utf16ToUtf8Avx512` and `latin1ToUtf8Avx512`, up to 64 bytes in `utf8ToUnitsAvx512` and `utf8ToLatin1Avx512`. UTF-8 to UTF-16 and UTF-32 on ASCII at 16-64 bytes 1.13-1.26×, UTF-8 to Latin-1 1.17-1.63× (`nat-d`). The UTF-8 decode rows on non-Latin text read 0.93-0.94 in that 3-round run and 0.94-1.06 in a 5-round rerun with an arm without the prefix (`nat-e`: prefix against no prefix 0.999 over the op), so noise.

`latin1ToUnits` (Latin-1 to UTF-16 and UTF-32) on AVX-512, when the output holds the whole input: the blocks, then one widened store for the tail (`loadShort` under 64 bytes, else `simd.loadTail`), returning directly.

### Fixed-ratio conversions

- **The input sets the alignment.** UTF-32 and UTF-16 to Latin-1 aligned their loops to the output; they now align to the input, which they read four or two times as much of. The harness's `Utf32ToLatin1/*-65536` rows at 0.63-0.69 were the input at a 16-byte offset: in the layout driver at 64 KiB, UTF-32 to Latin-1 from an input 16 bytes past a boundary went from 60 to 88 GB/s, 1.3-1.5× `icelake`; UTF-16 to Latin-1 +5-12%.
- **One bound.** The fixed-ratio loops (UTF-16 and UTF-32 to Latin-1, the byte swap, Latin-1 to UTF-16 and UTF-32) test one `lim = min(src.len, dst.len)` (`src.len - 1` for the checked swap), so LLVM emits a counted loop.
- **`simd.narrow` on VBMI**: one `vpermt2b` makes 64 bytes of 16-bit lanes from two registers, and two `vpermi2b` and a blend 64 bytes of bytes from four, where `vpmovdw`/`vpmovdb` take two shuffle-port operations per 32 or 16 bytes. The byte indexes load at run time, or LLVM rewrites the two permutes as four `vpshufb`, two `vpermd`, and two 32-byte stores. `utf32ToUtf16Avx512` narrows with it (LLVM folds the big-endian swap into the permute): UTF-32 to UTF-16 1.21-1.23× checked, 1.06-1.10× valid (`nat-a`).

### The checked UTF-16 byte swap

`swapBlocks` checked each block's surrogate pairing with a second load one unit on and four operations a vector. It now tests first whether the block holds a surrogate or the unit after it is a low surrogate, and checks pairs only then; a block with neither has nothing to pair, and the unit after it is the next block's first. Over the op, `old` to this branch: 1.32× on SSE and AVX2, 1.11× native (1.75, 2.90, and 1.55 of `westmere`, `haswell`, and `icelake`; lowest row 1.21, 1.74, 1.22). Emoji, a pair in every block, pays for the extra test: 0.69-0.71× on SSE, 0.82-0.93× on AVX2, 0.85-1.06× native, still 1.21-1.36, 2.02-2.08, and 1.22-1.63 of simdutf ([ab/sw-sse](convert-wave3-20261031/ab/sw-sse/), `sw-avx2`, `sw-nat`; arms `old`, before this change, after). simdutf's arm validates, then swaps: two passes.

### Length

- `utf8FromUtf16` without AVX-512 counts three less a compare's all-ones lane for each of below U+0800, below U+0080, and surrogate, and `sumBlocks` adds the three once per run of blocks (its new `base`), not per block; 16-bit lanes sum in 32 bits, half the widening of 64.
- `utf8FromUtf32` without AVX-512: four less one per signed compare against U+0080, U+0800, and U+10000, each one operation where an unsigned compare is two (`pmaxud` and `pcmpeqd`, both on ports 0 and 1, which bound the loop at 3 cycles per 16 bytes); a value at or above 2^31 is masked to count four. A first version that wrote the compares as masked tests against zero was 0.89-0.94× `old`: LLVM turned them back into unsigned compares, and the same with a clamp to U+10FFFF.
- `utf8FromUtf16be` compares the units as loaded against byte-swapped constants, where it swapped each vector first: each count is a masked equality, which holds in either byte order. SSE 1.09× over swapping (0.95 to 1.04 of `westmere`), AVX2 1.08× (1.07 to 1.16 of `haswell`) ([ab/be-sse](convert-wave3-20261031/ab/be-sse/), `be-avx2`).
- SSE: `utf8FromUtf16le` 1.16× `old` (0.88 to 1.00 of `westmere`), `utf8FromUtf32` 1.12× (0.92 to 1.03); AVX2 1.13× and 1.15× (1.09 and 1.06 of `haswell`) ([ab/sse-d](convert-wave3-20261031/ab/sse-d/), `avx2-d`).

## Rejected

- AVX-512 Latin-1 to UTF-8 with `vpcompressb` straight to memory: 0.41-0.48 of `icelake`. A 32-byte `latin1Encode512` in the inner loop: 9.6 GB/s. A head-alignment step: ASCII at 4 KiB -20%.
- Longer scalar steps in the generic decode (wave 2): neutral to -15%.

## Rows still under 1.0

From the final harness run; each row's reason, measured where it says so.

- **Layout and aliasing, not the kernel** (the row moves with a function's address or the buffers' offsets, and the layout driver or an A/B in one process puts us at or above simdutf):
  - valid byte swap at 256 B (0.56-0.66 native, 0.61 AVX2): native, the layout driver puts us at 1.57-1.90× `icelake` ([lay/swap-256.txt](convert-wave3-20261031/lay/swap-256.txt)), and in wave 3 identical code at another address moved 20%. The driver calls simdutf through its C API, about 1 ns more at this size, which does not cover the gap.
  - native `ValidUtf8ToLatin1` on Latin-1 text (0.69-0.83 here, 0.54-0.89 on ASCII at 256 B between runs): in the layout driver with the output 2 KiB past the input, 0.88-1.17 of `icelake` from 64 B to 4 KiB, lowest at 256 B (0.88-0.96) and at 4 KiB with the input 16 bytes past a boundary (0.95). So a few percent at 256 B is real; the harness's 0.7 is not (its simdutf arm ran 32 GB/s at 4 KiB, the driver's 26-30).
  - AVX2 UTF-16 to UTF-8 on Korean and Hindi (0.81-0.83 here): 0.99-1.08 in the interleaved A/B (`avx2-c`), where simdutf's arm ran 6.05 GB/s against 7.99 here.
  - SSE `utf8FromUtf16le` and `be` (0.79-0.93 here): 1.00-1.04 of `westmere` in the A/Bs; the identical `le` code read 1.05× and 1.19× `old` at two addresses.
- **Real, not closed:**
  - AVX-512 Latin-1 to UTF-8 on Latin-1 text from 256 B (0.77-0.88 in the layout driver): by count about 8 shuffle-port operations per 64 input bytes (two `vpermt2b`, two compresses of two each, two mask moves), and no formulation with fewer found; `vpcompressb` to memory was 0.41-0.48.
  - SSE Latin-1 to UTF-16 at 4 KiB-64 KiB (0.77-0.88, unchanged code): one `punpcklbw`/`punpckhbw` and two 16-byte stores per 16 bytes; judged store-bound in wave 2, not measured further.
  - 256-byte ASCII widening on AVX-512 and AVX2 (`Utf16beToUtf32`, `ValidUtf16leToUtf32`, `ValidUtf8ToUtf32` at 0.73-0.82): not investigated; a hypothesis is the first step to the output's 64-byte boundary, a partial block at this size.
  - AVX2 `utf8FromUtf32` and `utf8FromLatin1` at 64-256 B (0.83-0.85): the run is shorter than the 16 vectors from which `sumBlocks` aligns, and the reduction to one sum is 15-20 operations; not changed.
  - Short rows at 16-64 B (0.79-0.90): 1-2 ns a call, within the harness's swing at this size.
- **Generic** (baseline, no dispatch): not changed. Wave 2's longer scalar steps were neutral to -15%; the generic checked forms are within ±10% of an out-of-line scalar call.

## Correctness

Tests (52, with the merged validation tests) on the final commit: ReleaseSafe at `-Dcpu=native`, `x86_64_v3` with and without dispatch, `x86_64_v2` without, and `baseline` with and without; baseline Debug; ReleaseSafe and Debug on `aarch64-linux-musl` and `aarch64_be-linux-musl` under qemu-user 11.1.2 (two skipped there, the x86 tier tests). `just oracle`: 0 mismatches over every public function, under `icelake` and `fallback`. A mutant of the swap's surrogate test that dropped the check of the unit after the block failed two existing tests.

The harness's checksum caught one bug the tests and the oracle missed: `sumVectors` took `blocks` from `@min`, which narrowed it to `u15` (the cap, 65535 / 3, fits 15 bits), so `base * blocks` wrapped once a run reached the cap, 21845 blocks of 32 units: `utf8FromUtf16le` on 1 MiB of ASCII UTF-16 counted 3 a unit. `blocks` is a `usize` now, and the overflow test runs `utf8FromUtf16le` past 21845 blocks (it panicked in ReleaseSafe before the fix).
