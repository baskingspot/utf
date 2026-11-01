# NEON validation, 2026-11-01

Validation on aarch64 against simdutf's `arm64` kernel: the reductions LLVM lowered through bit masks, UTF-16 pairs checked in vectors, the UTF-8 previous-byte loads, and a short UTF-16 path. Code: `src/validate.zig`, NEON paths only (`simd.isa == .neon`).

- Machine: GitHub `ubuntu-26.04-arm` runner, ARM Neoverse-N2, 4 vCPUs, a shared VM ([final/lscpu.txt](neon-validate-20261101/final/lscpu.txt)). Zig 0.16.0 ReleaseFast `-Dcpu=native`, simdutf 9.2.1 (`kernel arm64`), Rust `target-cpu=native`, Go 1.26.
- Method: `.github/workflows/bench.yml` (`just base=<rev> bench-compare <rounds>`), every arm timed back to back in each round, ratios the median of the per-round ratios. `base` is the named revision's `bench-utf` in the same rounds. GB/s are from the shared VM; read the ratios.
- Runs: [final](neon-validate-20261101/final/) (run 41318431700, `75b7422` against `1476ab0`, 10 rounds, all ten validation operations); the per-change A/Bs, 3 rounds each: [reductions](neon-validate-20261101/reductions/) (41316451796, UTF-8 and ASCII reductions against `1476ab0`), [utf16](neon-validate-20261101/utf16/) (41317093212, all reductions and the UTF-16 pairs against `1476ab0`), [pairs](neon-validate-20261101/pairs/) (41318442587, `316b88b` against `d9e028d`), [load](neon-validate-20261101/load/) (41317836637, `prev_by_load` against the reductions and pairs), [leads-short](neon-validate-20261101/leads-short/) (41317754397, the dropped leads shift and the short UTF-16 path). The "before" column is the ten-round baseline at `25ccea6` (run 41312568501), whose validation code is `1476ab0`'s.

## Takeaways

utf ÷ simdutf `arm64` per operation (geomean over rows), and the A/B against `1476ab0` in the final run:

| operation              | before | after | ÷ `1476ab0` | slowest row after  |
| ---------------------- | -----: | ----: | ----------: | ------------------ |
| `validate-ascii`       |   0.93 |  1.31 |        1.43 | 1.09 ascii-1048576 |
| `validate-ascii-err`   |   1.04 |  1.46 |        1.35 | 1.07 latin         |
| `validate-utf8`        |   0.74 |  1.21 |        1.66 | 1.12 japanese      |
| `validate-utf8-err`    |   0.77 |  1.29 |        1.66 | 1.12 ascii-256     |
| `validate-utf16le`     |   1.80 |  2.47 |        1.34 | 1.15 emoji         |
| `validate-utf16le-err` |   1.74 |  2.34 |        1.29 | 1.06 emoji         |
| `validate-utf16be`     |   1.74 |  2.28 |        1.29 | 1.23 emoji         |
| `validate-utf16be-err` |   1.67 |  2.13 |        1.22 | 1.03 ascii-64      |
| `validate-utf32`       |   1.14 |  1.28 |        1.13 | 1.18 ascii-256     |
| `validate-utf32-err`   |   2.29 |  2.58 |        1.13 | 2.18 ascii-16      |

No row of the 134 is under simdutf (lowest 1.03, `utf16beErr/ascii-64`). UTF-8 on non-ASCII text 3.47 to 5.91 GB/s (simdutf 5.28, Rust's `simdutf8` 5.57); ASCII 4 KiB 34 to 66 GB/s (simdutf 54, Rust 60); UTF-16 emoji 11.0 to 18.3 GB/s (simdutf 15.9). utf ÷ Rust is 1.11 on UTF-8 validation and 1.08 on ASCII, from 0.67 and 0.76. Peak RSS unchanged ([final/rss.txt](neon-validate-20261101/final/rss.txt)): nothing allocates.

- **Reductions were the gap.** NEON has no `pmovmskb`, and LLVM reduces a 64-lane bool vector (`@reduce(.Or, v >= 0x80)`, `@reduce(.Or, v != 0)`) through a bit mask: `cmlt`, `and`, `ext`, `zip1`, `addv`, and `fmov` per 16-byte register, then `orr`s, about 26 instructions. UTF-8 validation paid that twice a block (ASCII test, error test) on top of a ~75-instruction block, and the ASCII loops once per block or group. A byte max (`@reduce(.Max, v) < 0x80`, `!= 0`) is three `umax` and one `umaxv`; for UTF-16 and UTF-32 keys, `uminv`/`umaxv` on the min or max of the keys. Alone (reductions run): UTF-8 1.57× (non-ASCII text 1.56×, `ascii-256` 2.60×), ASCII 1.41× (4 KiB 1.93×). With UTF-16's and UTF-32's: UTF-16 on text without surrogates 1.27–1.30× (utf16 run; the pairs run shows these rows at 1.00 from the pairs change, so they are the reductions'), UTF-32 1.11–1.25×.
- `utf8Incomplete` returns the block's last 16 bytes on NEON: LLVM kept `uqsub` against 0xFF in the other three registers and carried and reduced all four through the loop.
- **UTF-16 pairs in vectors** (pairs run, `316b88b` ÷ `d9e028d`): emoji 1.54× little-endian, 1.74× big-endian, other text 1.00. A group with a surrogate took two 32-lane masks per block and compared them in general registers; now each block's high bytes (one `uzp2`, `uzp1` for big-endian units, from the byte load, so the host's byte order does not matter) are compared against 0xD8 and 0xDC and the low-surrogate lanes XORed with the high-surrogate lanes one unit back (`ext`), ORed over the group, one `umaxv`. Only a failing group runs the masks, to find its block. The check's loads are volatile: otherwise LLVM kept the group's 32 loaded registers from the surrogate test and spilled them on every group.
- **`prev_by_load` on NEON** (load run): the bytes one, two, and three back from unaligned loads instead of `ext`s, 1.09× on every non-ASCII text, `latin` and ASCII 1.00. The plan had left this unmeasured on NEON. N2 has two vector pipes and loads to spare, so 12 loads a block for 12 `ext`s is a win, as on AVX2 and SSE.
- **Short UTF-16** (leads-short run): 8–31 units test for a surrogate on two or four overlapping 16-byte loads before building the zero-padded block: 16 units 1.31× little-endian, 1.39× big-endian; 1.65–1.68× in the final run with the reductions.
- x86-64 is unchanged: every NEON path is behind `neon = simd.isa == .neon`, and the assembly of all ten public validators at `baseline`, `x86_64_v2`, `x86_64_v3`, and `x86_64_v4` plus the AVX-512 tier's extensions is identical, byte for byte outside debug info, at `1476ab0` and `75b7422` (`zig build-obj -OReleaseFast -femit-asm` on a file exporting each function). So no x86 bench was run.

## Tried and dropped

- **One shift for the bytes two and three back** (leads-short run: 1.04× on non-ASCII text against the reductions and pairs): `h = (cur -| 0x60) | (prev1 -| 0x70)` has bit 7 where `must_be_23` will two bytes later, so one `ext` of `h` replaced two, 8 `ext`s a block instead of 12. The loads above took all 12 off the vector pipes for 1.09×, so the shift is gone.
- **An out-of-line ASCII long path**, for the final run's one row under `base`, `ascii/ascii-64` 0.96: the exported `validate.ascii` now sets up its frame pointer on entry where `1476ab0`'s skipped it on short inputs (LLVM's shrink wrapping), and moving the long path out of line did not change that, so it was not benchmarked. `asciiErr/ascii-64` 0.99 and `utf16beErr/ascii-16` 0.98, whose code did not change, show the size of layout noise here.
- Not tried: accumulating UTF-8 errors over blocks for `validate.utf8` (simdutf's way; it saves two instructions of about 70 a block here), and skipping the ASCII test within runs of non-ASCII blocks.

## Left

`validate.utf8WithErrors` saves `d8`–`d12` on entry on every call, short ones too (also at `1476ab0`); on x86 tiers its long path is out of line for this reason (`dispatch.exported`), which NEON builds do not use.

## Raw output

Every file is in [neon-validate-20261101/](neon-validate-20261101/). The final summary:

```text
utf/arm, geomean          rows  utf GB/s  simdutf     base      std     rust       go     ±   <1    ~   slowest vs simdutf
ValidateAscii                7     32.14     1.31     1.43        -     1.08        -    0%    0    0   1.09 [1.06, 1.15] ascii-1048576
ValidateAsciiErr             7     24.62     1.46     1.35        -     0.81        -    1%    0    0   1.07 [1.06, 1.07] latin
ValidateUtf8                15     12.73     1.21     1.66     4.44     1.11     3.43    0%    0    0   1.12 [1.12, 1.12] japanese
ValidateUtf8Err             15      9.54     1.29     1.66     3.77     1.06     2.57    0%    0    0   1.12 [1.12, 1.13] ascii-256
ValidateUtf16le             15     37.92     2.47     1.34        -     4.62        -    0%    0    0   1.15 [1.15, 1.15] emoji
ValidateUtf16leErr          15     33.09     2.34     1.29        -     4.19        -    0%    0    0   1.06 [1.06, 1.06] emoji
ValidateUtf16be             15     28.70     2.28     1.29        -        -        -    0%    0    0   1.23 [1.23, 1.23] emoji
ValidateUtf16beErr          15     24.62     2.13     1.22        -        -        -    0%    0    0   1.03 [1.03, 1.03] ascii-64
ValidateUtf32               15     32.22     1.28     1.13        -        -        -    0%    0    0   1.18 [1.18, 1.18] ascii-256
ValidateUtf32Err            15     32.38     2.58     1.13        -        -        -    0%    0    0   2.18 [2.17, 2.18] ascii-16
all                        134     24.46     1.81     1.33     4.09     1.86     2.97          0    0
```
