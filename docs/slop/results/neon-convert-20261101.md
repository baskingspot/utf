# NEON transcoding, 2026-11-01

Transcoding on aarch64 against simdutf's `arm64` kernel: lanes widened with `tbl`, reductions folded with `umaxp`, counts without a move per mask, runs of three- and four-byte UTF-8 decoded before the block's end is found, and windows for blocks with four-byte characters. Code: `src/convert.zig`, NEON paths only (`neon`, which is `simd.isa == .neon` with the LLVM backend).

- Machine: GitHub `ubuntu-26.04-arm` runner, ARM Neoverse-N2, 4 vCPUs, a shared VM ([final/lscpu.txt](neon-convert-20261101/final/lscpu.txt)). Zig 0.16.0 ReleaseFast `-Dcpu=native`, simdutf 9.2.1 (`kernel arm64`), Rust `target-cpu=native`, Go 1.26.
- Method: `.github/workflows/bench.yml` (`just base=<rev> bench-compare <rounds>`), every arm timed back to back in each round, ratios the median of the per-round ratios. `base` is `1476ab0`'s `bench-utf` in the same rounds; `src/convert.zig` is the only source file that differs between `1476ab0` and the measured tree for these operations (validation and base64 moved on `main`, and `convert.zig` imports neither). GB/s are from the shared VM; read the ratios.
- Runs: [final](neon-convert-20261101/final/) (run 41320731911, `043775e` (this change's code before the write-up was added to it) against `1476ab0`, 10 rounds, the 24 operations in the table) and [guard](neon-convert-20261101/guard/) (run 41320747953, same commit, 10 rounds, the other 14 conversions). The per-change A/Bs, 3 rounds each against `1476ab0`, cumulative: [zips](neon-convert-20261101/zips/) (41316624329), [windows](neon-convert-20261101/windows/) (41317117261), [tbl](neon-convert-20261101/tbl/) (41317489301), [popcount](neon-convert-20261101/popcount/) (41317840147), [swap](neon-convert-20261101/swap/) (41318208995), [runs](neon-convert-20261101/runs/) (41318737411), [guard3](neon-convert-20261101/guard3/) (41319184794, the other conversions at `a1f05e9`), [three21](neon-convert-20261101/three21/) (41319719860). The "before" column is the ten-round baseline at `25ccea6` (run 41312568501), whose conversion code is `1476ab0`'s but for `simd.bitmask` (UTF-8 to UTF-16 1.07 of `25ccea6`, [neon-20261101.md](neon-20261101.md)).

## Takeaways

utf ÷ simdutf `arm64` per operation (geomean over rows), and the A/B against `1476ab0` in the final run:

| operation               | before | after | ÷ `1476ab0` | slowest row after |
| ----------------------- | -----: | ----: | ----------: | ----------------- |
| `Utf8ToUtf16le`         |   1.10 |  1.40 |        1.19 | 0.95 chinese      |
| `ValidUtf8ToUtf16le`    |   0.94 |  1.32 |        1.27 | 0.92 chinese      |
| `Utf8ToUtf16be`         |   1.09 |  1.39 |        1.20 | 0.97 chinese      |
| `ValidUtf8ToUtf16be`    |   0.94 |  1.33 |        1.26 | 0.93 chinese      |
| `Utf8ToUtf32`           |   0.89 |  1.29 |        1.34 | 0.96 chinese      |
| `ValidUtf8ToUtf32`      |   0.75 |  1.20 |        1.47 | 0.86 ascii-16     |
| `Utf16leToUtf8`         |   1.14 |  1.36 |        1.19 | 0.91 russian      |
| `ValidUtf16leToUtf8`    |   1.08 |  1.30 |        1.20 | 0.92 russian      |
| `Utf16beToUtf8`         |   1.23 |  1.43 |        1.17 | 1.01 hindi        |
| `ValidUtf16beToUtf8`    |   1.18 |  1.38 |        1.17 | 1.01 hindi        |
| `Utf16leToUtf32`        |   0.79 |  1.13 |        1.44 | 0.88 ascii-16     |
| `ValidUtf16leToUtf32`   |   0.79 |  1.13 |        1.44 | 0.88 ascii-16     |
| `Utf16beToUtf32`        |   0.83 |  1.12 |        1.35 | 0.90 ascii-16     |
| `ValidUtf16beToUtf32`   |   0.83 |  1.12 |        1.33 | 0.88 ascii-16     |
| `Utf32ToUtf8`           |   1.08 |  1.32 |        1.21 | 0.92 korean       |
| `ValidUtf32ToUtf8`      |   1.17 |  1.39 |        1.19 | 1.03 hebrew       |
| `Latin1ToUtf16le`       |   0.81 |  0.91 |        1.12 | 0.77 latin1-16    |
| `ValidLatin1ToUtf16le`  |   0.81 |  0.91 |        1.12 | 0.77 latin1-16    |
| `Latin1ToUtf16be`       |   1.09 |  1.22 |        1.12 | 0.81 latin1-16    |
| `ValidLatin1ToUtf16be`  |   1.09 |  1.22 |        1.12 | 0.81 ascii-16     |
| `Latin1ToUtf32`         |   1.02 |  1.05 |        1.04 | 0.74 ascii-16     |
| `ValidLatin1ToUtf32`    |   1.02 |  1.05 |        1.03 | 0.74 latin1-16    |
| `ValidUtf16leToUtf16be` |   0.96 |  0.96 |        1.01 | 0.83 ascii-64     |
| `ValidUtf16beToUtf16le` |   0.96 |  0.96 |        1.01 | 0.83 ascii-64     |

Over the 348 rows: 0.97 to 1.20 of simdutf, 1.20 of `1476ab0`; rows under simdutf 216 to 85. Of the rows the task named: valid UTF-8 to UTF-32 on emoji 0.30 to 1.52 (6.4 GB/s, 4.65× `1476ab0`), to UTF-16 0.49 to 1.52, checked to UTF-32 0.44 to 1.23 and to UTF-16 0.63 to 1.30; UTF-8 to UTF-32 on Chinese 0.73 to 0.96; UTF-16 to UTF-8 on Chinese 0.76 to 1.22 (BE 0.82 to 1.33); UTF-32 to UTF-8 on Japanese 0.68 to 1.04; UTF-16 to UTF-32 at 4 KiB 0.74 to 1.12; Latin-1 to UTF-16LE at 4 KiB 0.74 to 0.97, at 64 KiB 0.75 to 1.00.

The other 14 conversions (guard run): none under `1476ab0` (1.00–1.19 per operation; UTF-16 to Latin-1 1.19, UTF-32 to Latin-1 1.19, Latin-1 to UTF-8 1.10, UTF-8 to Latin-1 1.10, from the reductions). Peak RSS unchanged ([final/rss.txt](neon-convert-20261101/final/rss.txt)): nothing allocates.

- **Neoverse N2 has one vector shifter.** Of its two vector pipes only V1 shifts by an immediate (`ushll`, `shl`, `ushr`, `shrn`), while both run `tbl`, `zip`, `uzp`, logic, and compares (Arm's N2 software optimization guide). Base aarch64 counts bits only in vector registers, so a `@popCount` of a mask costs `fmov`, `cnt`, `addv`, `fmov`, and llvm-mca puts each `fmov` at 3 cycles. The generic 16-byte path widened with `ushll` (every lane through V1), reduced bool vectors through lane masks (LLVM's `and`/`ext`/`zip1`/`addv` per 16 lanes), and took one `@popCount` per mask in the UTF-8 decoder.
- **Widen with `tbl` and plain stores** (`storeWide`, `storeWideUnits`): index tables put each byte in its lane and zero the rest, and LLVM pairs the plain stores into `stp`. Latin-1 to UTF-16 1.13 (tbl run), UTF-16 to UTF-32 1.28 to 1.44, Latin-1 to UTF-32 0.89 to 1.04. Used by `widenAscii` (Latin-1 and the UTF-8 ASCII runs), the UTF-16 to UTF-32 32-unit loop (which widens the registers it tested), and the UTF-8 window's ASCII case.
- **Latin-1 to UTF-16LE against BE was simdutf's asymmetry, not ours.** Our LE and BE run the same speed before and after (16.5 then 18.6 GB/s geomean); simdutf's BE byte swap holds it at 21.6 GB/s from 4 KiB, against 36 for its LE. LE's gap was our widening against simdutf's `zip`-based LE.
- **Reductions fold to one register** (`fold`, `anySet`, `anyTrue`): the 16-byte registers ORed together, one `umaxp`, the low word moved out. Used by the UTF-8 checks in the converters, the UTF-16 surrogate and swap checks, and `utf8FromBmp`/`utf8From16Three`'s range tests.
- **Counts without moves.** `utf8DecodeBlock` took a `@popCount` per mask, two register-file moves each; now one vector `cnt` of the block's lead masks and a multiply for the prefix sums (popcount run, which also kept windows only for blocks with four-byte characters: UTF-8 to UTF-32 1.20 to 1.28 of `1476ab0`, valid 1.27 to 1.37, to UTF-16 1.01 to 1.13). The window's pair count reads a nibble table (`0x3221_2110`).
- **Runs before the block end.** A valid block of 21 three-byte characters (leads `0x9249_2492_4924_9249`) decodes in `utf8DecodeThreeNeon(21)` and advances 63 bytes; 16 three-byte characters, 48; a lead every four bytes (`0x1111…1111`) in `utf8DecodeFour` (`rev32` and masks, surrogate pairs for UTF-16), 64. Other blocks with a byte ≥ 0xF0 decode in 12-byte windows, as simdutf's `arm64` kernel decodes every block. Runs run: emoji to UTF-16 1.9–3.0× `1476ab0`, to UTF-32 2.6–4.7×, the slowest rows from 0.58–0.71 of simdutf to 0.84–0.90; three21 run: Chinese to UTF-16 0.84 to 0.95, to UTF-32 0.85 to 0.96.
- **UTF-16 and UTF-32 to UTF-8.** `utf8From16Three` stores each half with its own `tbl` and a volatile store: LLVM had merged the overlapping stores into byte moves and two-register lookups. `utf8FromBmp` builds each group's shuffle index from lane bits and two `addp.v8i16` on little-endian NEON, where two lane masks took twelve vector operations and as many to pick the indexes out. UTF-16 to UTF-8 1.11 to 1.20 (windows run), UTF-32 to UTF-8 1.15 to 1.22.
- **The valid byte swap** loads with plain loads, which LLVM pairs into `ldp` (1.00 to 1.01). `ascii-64` stays 0.83 of simdutf: 64 bytes is one block and the harness's call.
- **Zig: `&`, `^`, and `|` have equal precedence, left to right.** `a ^ b & c` is `(a ^ b) & c`; parenthesize every mixed expression. A mutation of the four- and 21-character paths failed the tests, so they catch it.

## x86

Unchanged: every new path is behind `neon`. The x86-64 assembly of every `convert` kernel (an export per function, `-OReleaseFast`) is identical to `1476ab0`'s after renaming anonymous symbols, at `baseline`, `x86_64_v2`, `x86_64_v3`, `x86_64_v4` with VBMI, VBMI2, BITALG, VPOPCNTDQ, and GFNI, and `znver4`.

## Tests

`zig build test` under qemu-user for `aarch64-linux-musl` and `aarch64_be-linux-musl` (ReleaseSafe), `just ci` on x86-64, and the repo's CI (run 41321005636: ubuntu-26.04, ubuntu-26.04-arm, macos-26) pass. The differential tests run every conversion against `src/scalar_convert.zig` on text of every mix and length and with every error at every position; the existing emoji and CJK inputs reach the new runs and windows, and a mutation of the four- and 21-character paths fails them.

## Dropped

- Widening with `zip` against zero and volatile `str` stores (zips run): LLVM sees a zero extension and makes `ushll` again unless the stores are volatile, and unpaired `str` moves 16 bytes a cycle where `stp` moves more (Latin-1 to UTF-32 0.89 of `1476ab0`; `tbl` with `stp` 1.04).
- Windows for every non-ASCII block (windows run): CJK and emoji gained, two-byte text, Korean, and Hindi lost 15–20% (UTF-8 to UTF-16 0.97). Kept only for blocks with four-byte characters.
- `anyTrue` on UTF-32 to UTF-16's bool selects and UTF-32 to UTF-8's range checks (tbl run: UTF-32 to UTF-16 0.83): reverted to `@reduce` (swap run: 1.03).
- `ushll` for the first 64-byte ASCII block, to keep the `tbl` tables off short inputs: no gain, LLVM hoists the tables anyway.

## Left

- 16–256-byte rows: Latin-1 to UTF-16 and UTF-32, UTF-16 to UTF-32 at 16 units, the valid byte swap at 64 bytes, and valid UTF-8 to UTF-32 at 16 bytes, 0.74–0.90 of simdutf. Their paths run few instructions; the 16-byte Latin-1 path's code is the same as `1476ab0`'s, and its 0.97 of `base` is code placement. Plan wave 5 found the harness's Zig loop costs more per call than its C++ loop.
- Valid UTF-8 to UTF-16 at 64 ASCII bytes, 0.95 of `1476ab0`: two `tbl` tables loaded before the first block.
- Chinese and Japanese UTF-8 to UTF-16 and UTF-32, 0.92–0.97 of simdutf: blocks that are not one run decode through `utf8DecodeBlock`; Russian UTF-16 to UTF-8 0.91.
