# NEON length functions, 2026-11-01

The `length` functions on aarch64 against simdutf's `arm64` kernel: how the 16-byte and 64-byte paths summed their lanes, and the UTF-16 kernels in 16-bit lanes. Code: `src/length.zig`, NEON paths only (`fold = simd.isa == .neon`).

- Machine: GitHub `ubuntu-26.04-arm` runner, ARM Neoverse-N2, 4 vCPUs, a shared VM ([final/lscpu.txt](neon-length-20261101/final/lscpu.txt)). Zig 0.16.0 ReleaseFast `-Dcpu=native`, simdutf 9.2.1 (`kernel arm64`), Rust `target-cpu=native`, Go 1.26.
- Method: `.github/workflows/bench.yml` (`just base=1476ab0 bench-compare <rounds>`) over the nine length operations: `count-utf8 count-utf16le count-utf16be utf16-from-utf8 utf16-from-utf32 utf8-from-utf16le utf8-from-utf16be utf8-from-utf32 utf8-from-latin1` (133 rows). Every arm is timed back to back in each round; a ratio is the median of the per-round ratios. `base` is `1476ab0`'s `bench-utf` in the same rounds. GB/s are from a shared VM; read the ratios.
- Runs: [final](neon-length-20261101/final/) (run 41321548477, `882db25`, the tree of this branch's two code commits, 10 rounds); 3-round A/Bs against `1476ab0`: [first-commit](neon-length-20261101/first-commit/) (41321551748, `308b4b3`, the first code commit's tree), [fold](neon-length-20261101/fold/) (41316535012, the one accumulator and widening sums alone), [bytes16](neon-length-20261101/bytes16/) (41317197213, plus UTF-16 in byte lanes), [chunks-branchless](neon-length-20261101/chunks-branchless/) (41317532886), [chunks-volatile](neon-length-20261101/chunks-volatile/) (41318099227), [chunks](neon-length-20261101/chunks/) (41319507727, the short path as committed), and [addv](neon-length-20261101/addv/) (41320363395, dropped). The working commits are on the `wip/neon-length-*` branches on GitHub. The "before" column is the ten-round baseline at `25ccea6` (run 41312568501), whose `length.zig` is `1476ab0`'s.

## Takeaways

utf ÷ simdutf `arm64` per operation (geomean over rows), and the A/B against `1476ab0` in the final run:

| operation           | before | after | ÷ `1476ab0` | rows under, before → after | slowest row after |
| ------------------- | -----: | ----: | ----------: | -------------------------: | ----------------- |
| `count-utf8`        |   1.52 |  1.79 |        1.18 |                      2 → 0 | 1.06 ascii-64     |
| `count-utf16le`     |   1.80 |  2.55 |        1.42 |                      0 → 0 | 1.14 ascii-16     |
| `count-utf16be`     |   2.07 |  2.95 |        1.42 |                      0 → 0 | 1.24 ascii-16     |
| `utf16-from-utf8`   |   1.67 |  1.93 |        1.16 |                      2 → 0 | 1.28 ascii-64     |
| `utf16-from-utf32`  |   3.04 |  3.13 |        1.02 |                      1 → 0 | 1.37 ascii-16     |
| `utf8-from-utf16le` |   1.13 |  1.86 |        1.65 |                      1 → 0 | 1.30 ascii-64     |
| `utf8-from-utf16be` |   1.00 |  1.68 |        1.67 |                     13 → 0 | 1.22 ascii-64     |
| `utf8-from-utf32`   |   2.86 |  2.89 |        1.01 |                      0 → 0 | 2.12 ascii-16     |
| `utf8-from-latin1`  |   1.03 |  1.45 |        1.38 |                      6 → 4 | 0.82 ascii-16     |

Over the nine operations 1.66 to 2.17 of simdutf. No row is under `base` outside the noise (lowest 0.997, `utf16FromUtf32/ascii-1048576` and `utf8FromUtf32/ascii-64`, whose long paths did not change). The short rows, utf ÷ simdutf before → after (÷ `1476ab0`): `countUtf8` 16 B 1.04 → 1.44 (1.48), 64 B 0.41 → 1.06 (2.63), 256 B 0.61 → 1.18 (1.88); `utf8FromLatin1` 16 B 0.57 → 0.82 (1.43), 64 B 0.36 → 0.97 (2.55), 256 B 0.68 → 1.26 (1.84); `utf16FromUtf8` 64 B 0.47 → 1.28 (2.72); `utf8FromUtf16be` 64 units 0.84 → 1.22 (1.45). Long UTF-16: `utf8FromUtf16le` 64 KiB 15.5 to 26.9 GB/s (simdutf 13.6), `utf8FromUtf16be` 13.5 to 23.9, `countUtf16` 36 to 53. Peak RSS unchanged ([final/rss.txt](neon-length-20261101/final/rss.txt)): nothing allocates.

- **The 64-byte gap was the final sum.** Without AVX-512 the kernels add each compare's 0/1 (or all-ones) byte into a vector accumulator, and `sumVectors` then reduced it as `@reduce(.Add, @as(@Vector(64, u64), acc))`: 8-bit lanes widened to 64 bits, about 60 instructions on NEON, once per run of up to 255 blocks, which a 64-byte input paid whole (`countUtf8/ascii-64` 12.7 ns for 64 bytes, 5.9 ns for 16). The masked head and last vector were each summed alone, and LLVM made those a bit mask (`and`, `ext`, `zip1`, `addv` per 16 bytes) and a `cnt`. On NEON the head and last vector now join the accumulator of the run they border (runs are two blocks shorter to leave room), the last vector's lanes are masked with a window of a 128-byte table (two `ldp` for the three instructions per 16 bytes an index compare took), and the lanes are summed once in lanes twice as wide: widening adds and one `addv`, or `uaddlv` for 16 bytes. Alone (fold run, an early form): `countUtf8/ascii-64` 2.19×, `utf8FromLatin1/ascii-64` 1.90×, `utf16FromUtf8/ascii-64` 2.20×, 256 B 1.57–1.89×.
- **Short inputs without a loop.** 16–63 bytes (up to four 16-byte vectors) and 64–128 bytes (up to two 64-byte ones) take `sumChunks`: the first vector, then each further one only while the input reaches past it, from the next multiple of the vector or else the last vector's worth, masked to the lanes no earlier vector counted, and one sum. `sumVectors`'s loop cost five branches and its setup for one block and a partial one. The chunks run (with `uaddlv` for 16-byte sums) against the bytes16 run, both with the byte lanes below: 16 B 1.11–1.24× on `countUtf8`, `utf8FromLatin1`, and the UTF-16 functions (16 units), `utf8FromUtf32` 16 units 1.17×, `utf16FromUtf32` 16 units 1.43×, 64 B 1.18–1.34× on `countUtf8`, `utf8FromLatin1`, and `utf16FromUtf8`. The first commit alone (first-commit run): `utf16FromUtf8` 1.16, `utf8FromLatin1` 1.40, `countUtf8` 1.18, the UTF-16 functions 1.00–1.01.
- **Why UTF-16BE was slower than UTF-16LE** (1.00 against 1.13 of simdutf, 13.5 against 15.5 GB/s from 4 KiB; simdutf runs both at 13.6): the 16-bit kernel tests masked equalities so the other byte order can swap the constants, not the units (the x86 tuning). For little-endian input LLVM turned `v & 0xFF80 == 0` into one unsigned compare (`cmhi`), which NEON has; for big-endian it stayed `bic` and `cmeq`. 8 vector instructions per 8 units against 7, which is the 0.88 measured.
- **UTF-16 in byte lanes.** The UTF-16 kernels now count in byte lanes, one per unit, from each unit's high byte, which `uzp2` (`uzp1` for big-endian units, from the bytes as loaded, so the host's byte order does not matter) takes from two registers: a 64-byte block is four registers of counting, not eight. `utf8FromUtf16` is two, one more above U+007F (a `cmhi` per 8 units, narrowed with `uzp1`; for big-endian units, a high byte not 0 or a low byte from 0x80), one less where the top five bits are 00000 or 11011, which one `tbl` of a 32-entry table indexed by the high byte shifted right 3 finds: 16 vector instructions per 32 units for little-endian (28 before) and 18 for big-endian (32). `countUtf16` compares the high byte shifted right 2 with 0x37: 8 per 32 units (12). bytes16 run: `utf8FromUtf16le` 1.62×, `be` 1.65×, long rows 1.73–1.76×; `countUtf16be` 1.38×.
- **Volatile loads keep `ld2` out** (chunks-volatile run): with the high byte the only use of a load, LLVM made `countUtf16le`'s loads `ld2` (de-interleaving loads, as `uzp2` from the load), and on N2 that was slower than `ldp` and `uzp2`: `countUtf16le` from 4 KiB ran 2.38 of simdutf where `countUtf16be`, which kept `ldp` and `uzp1`, ran 3.45. A volatile load of the units stays whole (`loadUnits`, only for the byte-lane kernels): `countUtf16le` 1.15 to 1.38 of `1476ab0`, level with `be`.
- Neoverse N2 has two 128-bit vector pipes; Apple's cores have four, and the parent thread saw `utf8-from-utf16le` at 0.91 of simdutf on an M4 Max at `1476ab0`. Not measured there (no Apple runner in the workflow); the UTF-16 kernels run 43% fewer vector instructions per unit and the short paths fewer branches, which should carry over.
- x86-64 is unchanged: every new path is behind `fold` or `bytes16`, and the assembly of all nine public length functions at `baseline`, `x86_64_v2`, `x86_64_v3`, and `x86_64_v4` is identical, outside debug info, at `1476ab0` and `882db25` (`zig build-obj -OReleaseFast -femit-asm` on a file exporting each function). So no x86 bench was run.

## Tried and dropped

- **All `k` short vectors, no branches** (chunks-branchless and chunks-volatile runs): `sumChunks` loaded every vector, masking the ones past the end to nothing. Every row is a multiple of 16 bytes, so 16 B did four vectors' work for one, and 64 B two: against the bytes16 run, 16-byte rows 0.69–0.88× (`utf8FromLatin1` 0.69 to 0.58 of simdutf), `utf8FromUtf32` 16 units 0.62×, `utf16FromUtf8` 64 B 0.76×, while 64–256 B UTF-16 rows gained. The committed form branches before each further vector.
- **`addv` for sums that fit a byte** (addv run): an 8-bit `addv` instead of the widening `uaddlv` where the lanes' bound allows (16 B, 16 units). −4% to +4% by row, `utf8FromLatin1` 16 B and 64 B −3 to −4%.
- **The long path out of line**, for `utf8FromLatin1` 16 B: the 8-bit kernels set up a frame record on entry where the UTF-16 ones defer it to the long path (shrink wrapping). As a call, the kernel saved two more registers on entry to keep `src` across it; not benchmarked.

## Left

`utf8FromLatin1` at 16 and 64 bytes, 0.82 and 0.97 of simdutf (4.1 ns against 3.5 at 16 B). Our call costs what `countUtf8`'s does at these sizes (1.44 and 1.06 of simdutf's `count_utf8`); simdutf's Latin-1 length is a minimal `ld1`, `cmhs`, `addv` loop with no setup. Candidates: the frame record above, and a count in general registers for 16 bytes.

A compiler issue found on the way: in aarch64 ReleaseSafe builds, `+` on the halves of a 64-lane byte vector (`sumLanes`) reported overflow for lanes of 0–2 (also from `@addWithOverflow`), while the wrapping sum was right; `sumLanes` uses `+%`, which its bound allows.

## Raw output

Every file is in [neon-length-20261101/](neon-length-20261101/). The final summary:

```text
utf/arm, geomean          rows  utf GB/s  simdutf     base      std     rust       go     ±   <1    ~   slowest vs simdutf
Utf16FromUtf8               15     21.72     1.93     1.16   108.98        -        -    0%    0    0   1.28 [1.28, 1.29] ascii-64
Utf16FromUtf32              15     46.17     3.13     1.02        -        -        -    0%    0    0   1.37 [1.36, 1.37] ascii-16
Utf8FromUtf16le             15     23.06     1.86     1.65    16.44        -        -    0%    0    0   1.30 [1.30, 1.30] ascii-64
Utf8FromUtf16be             15     20.67     1.68     1.67        -        -        -    0%    0    0   1.22 [1.21, 1.22] ascii-64
Utf8FromUtf32               15     13.00     2.89     1.01        -        -        -    0%    0    0   2.12 [2.12, 2.12] ascii-16
Utf8FromLatin1              13     25.42     1.45     1.38        -        -        -    0%    4    0   0.82 [0.82, 0.82] ascii-16
CountUtf8                   15     38.47     1.79     1.18    21.75     3.62    28.92    0%    0    0   1.06 [1.06, 1.06] ascii-64
CountUtf16le                15     41.94     2.55     1.42    13.75        -        -    0%    0    0   1.14 [1.14, 1.14] ascii-16
CountUtf16be                15     42.02     2.95     1.42        -        -        -    0%    0    0   1.24 [1.24, 1.24] ascii-16
all                        133     28.07     2.18     1.30    27.06     3.62    28.92          4    0
```
