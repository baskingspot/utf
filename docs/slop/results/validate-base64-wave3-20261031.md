# Validation and base64, wave 3, 2026-10-31

The wave-3 pass over `src/validate.zig` and `src/base64.zig`, after the dispatch result fix, the shared `simd.zig` helpers, and the harness fix moved the short rows. First a rerun of every `validate-*` and `base64-*` operation on `origin/main` (`6edad68`), then changes for the rows under 1.0, each measured against the base. Compare within a table, not across tables.

- Machine: Amp orb, KVM guest, Intel Xeon @ 2.60GHz (Ice Lake server, AVX-512 with VBMI2), 4 vCPUs; CPUs 2 and 3 are one core. Timed processes pinned to CPU 3; builds ran on CPUs 0 and 1 during A/Bs.
- Zig 0.16.0 ReleaseFast; simdutf 9.2.1 (nixpkgs); Rust 1.99.0 (`simdutf8`, `base64-simd`), built `-C target-cpu=native` in every harness run, so its column is AVX-512 Rust even in the AVX2 and SSE runs.
- Harness: `just bench-compare 6` over the 17 operations, three ways: native against `icelake`; `cpu=x86_64_v3 dispatch=false kernel=haswell`; `cpu=x86_64_v2 dispatch=false kernel=westmere`. `before-*` is `6edad68`; `after-*` this branch. The base64 operations were run again after the last base64 change (`b64-*`, native and AVX2; the SSE run already had it). Raw output, benchstat, summaries, and peak RSS per run in [validate-base64-wave3-20261031/](validate-base64-wave3-20261031/).
- Validation A/Bs: the wave-2 suite, unchanged ([validate-wave2-20261031/suite/](validate-wave2-20261031/suite/)): every validator and form (plain, `WithErrors` on valid input, `Err` with an error in the last character) on five texts at 7 bytes to 1 MiB, 16 bytes past a 64-byte boundary, called out of line; `ab.sh`, 5 interleaved rounds at 30 ms per row, `old` (`6edad68`), `new` (this branch), and simdutf's kernel on the same inputs. [vcmp.py](validate-base64-wave3-20261031/vcmp.py) prints medians and ratios; `suite-native/` and `suite-avx2/` hold the raw output, benchstat, and its rows.
- Base64 A/Bs: the wave-2 driver, unchanged ([base64-20261031/driver.zig](base64-20261031/driver.zig)): interleaved samples of each arm through a function pointer, benchstat on the samples. Its rows swing ±10–20% with code layout, so a result counts only when it holds with the arms' roles swapped (`e9` against `e9s`) or in the harness.

## Takeaways

Harness geomean against simdutf at the matching ISA, per operation:

| operation           | native before | native after | AVX2 before | AVX2 after | SSE before | SSE after |
| ------------------- | ------------: | -----------: | ----------: | ---------: | ---------: | --------: |
| ValidateAscii       |          1.18 |         1.22 |        1.44 |       1.42 |       1.41 |      1.36 |
| ValidateAsciiErr    |          1.07 |         1.10 |        1.87 |       1.91 |       1.96 |      2.02 |
| ValidateUtf8        |          1.44 |         1.46 |        1.47 |       1.48 |       1.29 |      1.32 |
| ValidateUtf8Err     |          1.76 |         1.78 |        1.46 |       1.49 |       1.30 |      1.29 |
| ValidateUtf16le     |          1.13 |         1.13 |        4.14 |       4.16 |       1.85 |      1.80 |
| ValidateUtf16leErr  |          1.49 |         1.50 |        3.93 |       4.03 |       1.69 |      1.71 |
| ValidateUtf16be     |          1.45 |         1.45 |        3.77 |       3.77 |       1.62 |      1.64 |
| ValidateUtf16beErr  |          1.42 |         1.49 |        3.57 |       3.64 |       1.53 |      1.52 |
| ValidateUtf32       |          1.20 |         1.24 |        1.71 |       1.73 |       1.62 |      1.60 |
| ValidateUtf32Err    |          1.06 |         1.06 |        3.58 |       3.59 |       4.48 |      4.40 |
| Base64Encode        |          0.96 |         0.86 |        1.18 |       1.17 |       0.98 |      1.00 |
| Base64EncodeUrl     |          1.00 |         0.92 |        1.20 |       1.17 |       1.04 |      1.04 |
| Base64Decode        |          1.11 |         1.13 |        1.23 |       1.27 |       1.15 |      1.21 |
| Base64DecodeUrl     |          1.08 |         1.10 |        1.23 |       1.29 |       1.12 |      1.10 |
| Base64DecodeStrict  |          1.00 |         1.13 |        1.20 |       1.27 |       1.12 |      1.14 |
| Base64DecodePartial |          1.09 |         1.14 |        1.27 |       1.29 |       1.19 |      1.19 |
| Base64DecodeMime    |          0.96 |         1.15 |        0.99 |       1.31 |       0.90 |      1.20 |
| all (176 rows)      |          1.25 |         1.27 |        2.13 |       2.18 |       1.56 |      1.57 |

"after" is `after-*` for validation and `b64-*` for base64 on native and AVX2 (`after-sse` on SSE). Base64 encode code is the same in `after-native` and `b64-native`, which put it at 1.08 and 0.86: its 4 KiB row reads 46 GB/s in one process and 30 in the next, and simdutf's 28 and 47 (`encode-ab/`, the two builds and simdutf interleaved in one run: 30.2, 30.3, 46.7). Read the native encode geomean as 0.86–1.08.

- **base64 MIME decode** (lines of 76 characters and CRLF or LF) 0.96 to 1.15 native, 0.99 to 1.31 on AVX2, 0.90 to 1.20 on SSE. Regular lines no longer go through the staging ring: the block that ends a line decodes straight from the input, overlapping what the line's earlier blocks wrote, and the 1–4 whitespace bytes are skipped (see [Line mode](#line-mode)). Driver, 4 KiB of lines: native 398 to 302 ns (1.32×), AVX2 914 to 476 ns (1.92×), SSE 1230 to 794 ns (1.55×); `icelake` 371, `haswell` 658, `westmere` 799.
- **base64 encode on AVX-512**: 64 bytes 1.24×, 256 bytes 1.35–1.51×, 4 KiB 1.07–1.11× in the harness run with the encode change (`after-native`); in the driver with roles swapped 1.1–1.4× from 64 bytes and level with `icelake` from 100 bytes. The loop takes 48-byte steps from the 64 bytes that end at the step's end, so one partial block finishes, and LLVM no longer unrolls it four times with a remainder loop (see [Encode](#encode)).
- **Validation with an error**, up to two blocks: the `WithErrors` forms find the position from the masks of the one or two blocks they test, without a second pass. Suite, native, inputs with an error in the last character: UTF-16 at 64–128 bytes 1.4–1.9×, UTF-32 at 64 bytes 1.25×, ASCII at 16–64 bytes 1.4–1.5×, UTF-8 at 7–45 bytes 1.1–1.3×; per-op geomeans `Err` 1.08–1.29× old. On valid input level or better (1.00–1.07).
- **Short UTF-8 on AVX-512** tests ASCII on the masked load instead of the overlapping loads first: non-ASCII text at 7–45 bytes 1.00–1.09× old, `WithErrors` 1.04–1.16×; ASCII at 7–45 bytes 0.91–0.93×, still 1.01–1.02× `icelake`.
- **Memory**: nothing allocates, and the decoder's 640-byte stage ring moved out of `decodeWith` into `decodeStaged`, which only irregular whitespace reaches. Peak RSS unchanged from `6edad68` in every run (±0.1 MiB jitter): 0.1–0.2 MiB above std's on UTF-8 and base64 as before, which is code: `bench-utf`'s text is 0.26 MB larger than `bench-std`'s (`size`), and validation and base64 allocate nothing.
- **Correctness**: `zig build test` in ReleaseSafe at native, `x86_64_v3`, `x86_64_v2`, and baseline, baseline Debug, and ReleaseSafe on aarch64 and aarch64_be under qemu-user 11.1.2, all passing (aarch64_be included; the transcoding failures earlier waves saw there are gone on this base). `just oracle`: 0 mismatches under `icelake` and `fallback`. `just ci` passes. A new test decodes regular lines at every line length and whitespace gap the line mode takes, with a fault (invalid byte, wrong gap, short line) in any line, in every kernel; a mutant without the gap check fails it.

## Rows still under 1.0

Native, against `icelake` (`after-native` for validation, `b64-native` for base64):

| rows                                                                   |     ratio | why                                                                                                                                                                                                                                                                                                                                              |
| ---------------------------------------------------------------------- | --------: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| ASCII, UTF-16LE, UTF-32 at 64 KiB–1 MiB and the 87–110 KB corpus texts | 0.94–0.99 | Level: both libraries at 140–146 GB/s (31–34 at 1 MiB, memory) and these rows move ±3% run to run; `6edad68` had the same rows at 0.95–1.0.                                                                                                                                                                                                      |
| `ValidateUtf32Err/ascii-64`                                            |      0.84 | One block of 16 units with the error in the last: 2.8 against 2.4 ns. 0.89 before this branch; the suite has this case at 0.91–0.95 (from 0.71–0.76). What is left is the test and the masks on one block, which simdutf does the same way; not found.                                                                                           |
| `Base64Encode/random-16`, `Url/random-16`                              | 0.78–0.81 | The partial block loads zero-padded in registers (`loadPartial`), where `icelake` uses a masked load. A masked load waits for recent stores to the bytes it masks off, which doubled short calls with the output right after the input ([base64-20261031.md](base64-20261031.md)), so it stays. Driver: 16 bytes 7.4 against `icelake`'s 6.2 ns. |
| `Base64Encode/random-64`, `random-256`, `Url/random-256`               | 0.75–0.98 | Harness only: the driver has this code ahead of or level with `icelake` (64 bytes 5.9 against 7.7 ns, 192 bytes 8.1 against 8.0), and the same rows read 0.98–1.04 in `after-native`.                                                                                                                                                            |
| `Base64Encode/random-4096`, `Url/random-4096`                          | 0.65–0.73 | Noise: the same code reads 46 GB/s in `after-native` (1.63 of simdutf) and 30 here; simdutf 28–47 between processes (`encode-ab/`).                                                                                                                                                                                                              |
| `Base64Decode*/random-4096`, `random-65536` (clean)                    | 0.87–0.96 | The clean-block loop did not change (`6edad68`: 0.86–0.94); not worked on this wave. A hypothesis, not measured: each block's 64-byte store at a 48-byte stride splits a cache line three times in four.                                                                                                                                         |
| `Base64DecodeMime/random-1048576`                                      |      0.98 | Memory.                                                                                                                                                                                                                                                                                                                                          |

AVX2, against `haswell` (std and Rust at the same ISA where they lead; Rust is built for the host, AVX-512):

| rows                                             |     ratio | why                                                                                                                                                                                                                                                                            |
| ------------------------------------------------ | --------: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `ValidateUtf8Err/ascii-16` vs std                |      0.91 | From 0.76. 15 ASCII bytes and an error: std's loop finds it in place, where the AVX2 short path builds the zero-padded 64-byte block in registers before the scalar validator runs from the first high byte. Fixing it would cost valid non-ASCII text, which needs the block. |
| `Base64Decode/random-16`, `Url/random-16` vs std | 0.83–0.88 | std decodes 16 characters in a scalar loop; the AVX2 kernel classifies two 32-byte vectors of a padded block. Native, the same rows lead std (1.12–1.19). Rust 0.77–0.87 is its AVX-512 build.                                                                                 |
| Encode and decode 4 KiB–1 MiB                    | 0.93–0.98 | Run-to-run spread on these rows, as natively; level with `haswell`.                                                                                                                                                                                                            |

SSE (`westmere`):

| rows                                             |            ratio | why                                                       |
| ------------------------------------------------ | ---------------: | --------------------------------------------------------- |
| `ValidateUtf8Err/ascii-16`, `-64`, `-256` vs std | 0.70, 0.90, 0.99 | As on AVX2, with 16-byte vectors (from 0.61, 0.88, 1.03). |
| `Base64Decode*/random-16` vs std                 |        0.62–0.77 | As on AVX2.                                               |
| `Base64Encode/random-4096`                       |             0.92 | The SSSE3 encode loop, unchanged; 0.93 before.            |

## Line mode

`decodeWith` decodes whole clean blocks two at a time straight into `dst`, as before. A block with whitespace or an error used to send everything after it through the ring: compress each block's values, store them, and decode once 256 more values followed (the load straddles the stores that wrote it). That costs a compress, a store, and a reload per block, and wave 2 measured MIME at 0.57–0.95 of simdutf on AVX2 and SSSE3 from 4 KiB.

MIME and PEM wrap at a fixed line length that is a multiple of four (76, 64), with the same 1–4 whitespace bytes after each line. So now, at a block with whitespace:

1. If the run of characters before the first whitespace byte, from the last run's start, is a multiple of four, the block ending the run is classified from `src` at `end - 64` and packed to `dst` at the run's output end minus 48: it overlaps what earlier blocks of the run wrote, with the same bytes. Then the whitespace bytes are skipped. No compress, no ring.
2. If that run is at least 64 characters and the whitespace is at most 4 bytes, `decodeLines` takes the following lines of the same length: whole blocks, then the rest (one overlapping block on AVX-512; one or two vectors with 16- and 32-byte kernels), and the gap compared as one `u32` against the first line's bytes. `lineReach` bounds the reads.
3. Anything else, and the first line that breaks the pattern, goes to `decodeStaged`, `noinline`, which keeps the ring and returns the result as two words so that no `Result` copy stalls (the dispatch fix of this wave).
4. The last partial block with whitespace compresses in registers (`finishSpaced`) instead of the ring.

Driver, `lines` (LF) and `crlf` 4 KiB, ns: native 302/326 against old 399/402 and `icelake` 371/393; AVX2 476/488 against 914/826 and `haswell` 658/699; SSE 794/805 against 1230/1198 and `westmere` 799/921. 64-byte lines are faster on every ISA too (5–8%); 256 bytes level native, 1.25× on AVX2 and SSE. Clean decode unchanged (`m8-*` in `driver/`). The loop's first test is now its condition, so that a short input skips the nine vector constants LLVM loads before the loop: with them `after-native` had decode at 16–64 bytes 0.83–0.92 of `6edad68`; without, `b64-native` has the five decode forms at 16 bytes 1.11–1.36× `6edad68` (decode 1.51 against 1.34 GB/s, strict 1.46 against 1.07) and at 64 bytes 0.86–1.19× (short rows swing ±15% with layout), and `encode-ab/` 1.11× at 16 bytes in one interleaved run. Driver `d1`, 16 bytes: 12.3 ns against old 14.1, simdutf 19.4, std 18.6, the scalar reference 20.2.

Tried and dropped: a branchless two-gap compress (5–12% slower than the branchy one kept), branch-free space masks in the staged loop (slower), and inlining `decodeStaged` (slower: it adds saved registers and a 640-byte frame to every call).

## Encode

The AVX-512 loop read 64 bytes and encoded 48, so it ran while 64 were left, and an input with 49–63 left over finished in two partial blocks. LLVM also unrolled it four times with a remainder loop, which at 100–256 bytes is all remainder dispatch. Now the first block encodes from `src[0..64]`, and every later step encodes the top 48 of the 64 bytes ending with them (`encodeTop`, the spread indices plus 16), so the loop runs while 48 are left and one partial block finishes; an empty `asm` on the index stops the unrolling, and the stores are volatile, which keeps LLVM from splitting each into two 32-byte halves. The partial block folds its move into the spread `vpermb` (zero-masked by its index), one `vpermb` where `loadTail` plus spread took two.

Driver with roles swapped (`e9s`: `old` is this code), ns: 64 bytes 5.9 against 8.4 (`icelake` 7.7), 100 bytes 8.0 against 9.3 (8.1), 192 bytes 8.1 against 9.7 (8.0), 1 KiB 41.2 against 51.3 (41.2), 4 KiB 109 against 118 (108); 16 bytes 7.4 against 7.2 (6.2). Harness: 64 bytes 1.24×, 256 bytes 1.51×, 4 KiB 1.11× old.

## Validation

- `utf8WithErrors` below a block (not generic): one block, as `utf8` does, and on an error the scalar validator from the first byte above 0x7F, whose position the same block gives. Before, it went through `utf8BadBlock` and then the scalar validator from the start.
- On AVX-512 both short UTF-8 paths test ASCII on the masked block instead of on overlapping loads first; non-ASCII text paid both. AVX2 and SSE keep the overlapping loads, where the padded block costs more.
- `asciiWithErrors` at 16–64 bytes: the mask of bytes above 0x7F from two or four overlapping loads, so the position comes with the test.
- `utf16WithErrors` and `utf32WithErrors` up to two blocks: the first and the last block, overlapping it, with one test as before (most input passes), then their masks give the first unpaired surrogate (UTF-16: paired exactly when `low == high << 1` and no high one is at the top bit) or the first bad value and which error (UTF-32: from the masks, not by reading the unit again).
- Tried and dropped: a `vpermb` with a hidden index for the UTF-8 shift-by-two (`vpermi2w` is three uops): 0.82–0.88× on non-ASCII text at 7–45 bytes; computing the masks before the pass test in the UTF-16 and UTF-32 short paths: valid UTF-16 at 7–128 bytes 0.47–0.75×.
- The UTF-8 page test (one `and`, `cmp`, and branch before the mask) stays: it was 0.3–0.6 ns at 16–48 bytes in wave 3's first measurement, and the suite's short UTF-8 rows are now at or above old there; the remaining gap to `icelake` on non-ASCII text below 64 bytes (0.90–0.94) is not the test, which old has too.

Suite, native, per-op geomean `new ÷ old` and `new ÷ icelake` (all rows, 7 bytes to 1 MiB):

| operation         | new ÷ old | old ÷ simdutf | new ÷ simdutf |
| ----------------- | --------: | ------------: | ------------: |
| Utf8              |     1.003 |         1.084 |         1.088 |
| Utf8WithErrors    |     1.019 |         1.136 |         1.158 |
| Utf8Err           |     1.082 |         2.016 |         2.181 |
| Ascii             |     1.044 |         1.288 |         1.345 |
| AsciiWithErrors   |     0.980 |         1.093 |         1.071 |
| AsciiErr          |     1.206 |         0.877 |         1.058 |
| Utf16le           |     0.975 |         1.386 |         1.352 |
| Utf16leWithErrors |     1.064 |         1.101 |         1.172 |
| Utf16leErr        |     1.289 |         0.938 |         1.210 |
| Utf16be           |     1.007 |         1.369 |         1.379 |
| Utf16beWithErrors |     1.073 |         1.095 |         1.174 |
| Utf16beErr        |     1.233 |         0.976 |         1.204 |
| Utf32             |     1.001 |         1.458 |         1.459 |
| Utf32WithErrors   |     1.000 |         1.109 |         1.109 |
| Utf32Err          |     1.117 |         0.924 |         1.032 |

Suite, AVX2 (`-Dcpu=x86_64_v3`), against `haswell`:

| operation         | new ÷ old | old ÷ simdutf | new ÷ simdutf |
| ----------------- | --------: | ------------: | ------------: |
| Utf8              |     1.002 |         1.564 |         1.567 |
| Utf8WithErrors    |     0.984 |         1.663 |         1.637 |
| Utf8Err           |     1.039 |         1.578 |         1.640 |
| Ascii             |     0.957 |         2.279 |         2.181 |
| AsciiWithErrors   |     0.971 |         2.531 |         2.457 |
| AsciiErr          |     1.273 |         2.289 |         2.915 |
| Utf16le           |     1.010 |         3.521 |         3.555 |
| Utf16leWithErrors |     1.052 |         3.428 |         3.607 |
| Utf16leErr        |     1.286 |         2.232 |         2.871 |
| Utf16be           |     0.990 |         3.433 |         3.400 |
| Utf16beWithErrors |     1.019 |         3.252 |         3.313 |
| Utf16beErr        |     1.252 |         1.931 |         2.418 |
| Utf32             |     0.984 |         1.828 |         1.800 |
| Utf32WithErrors   |     1.030 |         2.282 |         2.351 |
| Utf32Err          |     1.164 |         1.524 |         1.773 |

Rows that moved more than ±7% between builds of unchanged code (UTF-16LE at 256 bytes 0.91–0.93, UTF-32 at 256 bytes on AVX2 0.92) are layout: `utf16BadBlock` and `utf32BadBlock` did not change, and the same rows moved the other way in other builds of this branch.
