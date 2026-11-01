# Transcoding wave 4: the rows under simdutf after the harness fix, 2026-10-31

Wave 4 of `src/convert.zig`: the conversion rows the final baseline ([baseline-final-20261031.md](baseline-final-20261031.md)) put under simdutf 9.2.1 at the matching ISA, on `66fa49c`. No change to `src/simd.zig`, `src/dispatch.zig`, or `src/scalar_convert.zig`; no `@setRuntimeSafety(false)`.

- Machine: Amp orb, KVM guest, Intel Xeon @ 2.60GHz (Ice Lake server, AVX-512 with VBMI2), 2 cores × 2 threads; every timed process pinned to CPU 3, builds pinned to CPUs 0-1, nothing built while anything was timed.
- Zig 0.16.0 ReleaseFast. `native` runs the AVX-512 kernels, `x86_64_v3` with `dispatch=false` AVX2, `x86_64_v2` with `dispatch=false` SSE; simdutf's arm is forced to `icelake`, `haswell`, and `westmere`.
- Interleaved A/B: [ab.sh](convert-wave4-20261031/ab.sh) is the harness's method with any arms: every arm a `bench-utf serve` (or `bench-simdutf serve`) process on CPU 3, each row timed on every arm back to back in an order that rotates by row and round, fresh processes each round, round 0 sizing the loops and discarded, then `bench/summary.awk` (median per-round ratio, 95% interval, `~` where the interval holds 1). The arms are the harness's own `bench-utf` built by [hb.sh](convert-wave4-20261031/hb.sh) from `66fa49c` (`old`) and from this branch (`new`), with simdutf's arm as the third; buffers placed as the harness places them (input at a page, output 2 KiB past one). `ROUNDS` 5 native, 3 elsewhere. Ratios are utf ÷ arm; above 1 we are faster.
- Before and after per op come from the same runs: `old` ÷ simdutf and `new` ÷ simdutf, each the geomean of the op's rows ([table.py](convert-wave4-20261031/table.py)). Raw per-round GB/s (gzipped), summaries, and every row in [convert-wave4-20261031/](convert-wave4-20261031/).

## Takeaways

- **Every conversion op is at or above simdutf at every ISA**, geomean over its rows: lowest op `Latin1ToUtf8` native at 0.99 (was 0.92), every other op 1.00 or more native, 1.03 or more on AVX2 and 1.02 or more on SSE. Over the 40 ops, native 1.22 → 1.23 of `icelake`, AVX2 1.46 → 1.47 of `haswell`, SSE 1.37 → 1.40 of `westmere`. Rows under simdutf outside the noise: 55 → 35 native, 26 → 23 AVX2, 35 → 24 SSE; the ones left are below, with reasons.
- **The valid byte swap's gap was code layout of a five-instruction loop**, not buffer placement: one block a step is five instructions, which run in one cycle where they lie in one 64-byte line of code and in about 1.6 where they straddle two, as the function's address in each binary decides. Four blocks a step and a straight-line tail: 1.27× `old` at 256 B, 1.74-1.78× at 4 KiB native, level with or above `icelake` at every size from 256 B.
- **AVX-512 Latin-1 to UTF-8 on Latin-1 text is at `icelake`'s speed from 4 KiB** (0.72-0.82 in the baseline, 0.99-1.02 now), with simdutf's layout: one `vpermb` puts byte `i` and `32 + i` in 16-bit lane `i`, and `vpshldw`, a masked add, and a ternary-logic blend make both halves, against two `vpermt2b` before. Short and ASCII inputs gained too: 16 B 1.20-1.27×, 64 B of Latin-1 1.15-1.23×, 4 KiB of ASCII 1.09-1.13× (1.36-1.38 of `icelake`).
- **AVX-512 UTF-8 to Latin-1** 1.13-1.14× `old` over the op (0.95-0.99 of `icelake` to 1.09-1.11; no row under): full blocks, then one masked partial block, one load per step.
- **AVX2 and SSE ASCII runs** in loops of their own with one bound: UTF-8 to UTF-16 and UTF-32 at 4 KiB of ASCII 1.19-1.38× on AVX2, UTF-16 to UTF-32 1.38-1.40×, UTF-8 to Latin-1 1.45-1.64× (AVX2) and 1.34-1.46× (SSE) at 4 KiB. SSE Latin-1 to UTF-16 1.11-1.14× over the op (0.98-1.04 of `westmere` to 1.12-1.16).
- **Memory**: no allocation anywhere; peak RSS of one pass over each op's inputs is the same as `old` to ±0.1 MiB (below).
- **Correctness**: a new test runs every conversion on 699,075 code points of ASCII, Latin-1, and mixed text, valid and with an error in the last 100 units, at every level; every gate passes; `just oracle` 0 mismatches.

## Against simdutf, before and after

Geomean utf ÷ simdutf per op: `old` (`66fa49c`) and this branch from the same interleaved runs (`fin-nat`, `fin-v3`, `fin-v2`), `×old` the op's geomean of `new` ÷ `old`, and the rows under simdutf outside the noise before → after.

| op                    | `icelake` before | after | ×old | under | `haswell` before | after | ×old | under | `westmere` before | after | ×old | under |
| --------------------- | ---------------- | ----- | ---- | ----- | ---------------- | ----- | ---- | ----- | ----------------- | ----- | ---- | ----- |
| Utf8ToUtf16le         | 1.25             | 1.29  | 1.03 | 0→0   | 1.72             | 1.75  | 1.01 | 0→0   | 1.57              | 1.58  | 0.99 | 0→0   |
| ValidUtf8ToUtf16le    | 1.28             | 1.29  | 1.00 | 2→2   | 1.48             | 1.49  | 1.00 | 2→1   | 1.44              | 1.43  | 1.00 | 1→0   |
| Utf8ToUtf16be         | 1.32             | 1.35  | 1.02 | 0→0   | 1.80             | 1.82  | 1.01 | 0→0   | 1.53              | 1.53  | 1.01 | 0→1   |
| ValidUtf8ToUtf16be    | 1.32             | 1.33  | 1.00 | 2→1   | 1.49             | 1.49  | 0.99 | 1→1   | 1.39              | 1.40  | 1.02 | 1→0   |
| Utf8ToUtf32           | 1.45             | 1.46  | 1.01 | 1→0   | 1.60             | 1.62  | 1.01 | 0→0   | 1.41              | 1.42  | 1.01 | 0→0   |
| ValidUtf8ToUtf32      | 1.10             | 1.11  | 1.01 | 2→0   | 1.44             | 1.44  | 1.00 | 1→0   | 1.31              | 1.33  | 1.02 | 1→1   |
| Utf8ToLatin1          | 0.99             | 1.11  | 1.13 | 4→0   | 2.34             | 2.53  | 1.07 | 1→0   | 1.71              | 1.78  | 1.04 | 0→0   |
| ValidUtf8ToLatin1     | 0.95             | 1.09  | 1.14 | 5→0   | 1.54             | 1.59  | 1.03 | 1→2   | 1.57              | 1.65  | 1.06 | 3→0   |
| Utf16leToUtf8         | 1.38             | 1.36  | 0.98 | 0→0   | 1.42             | 1.45  | 1.01 | 1→1   | 1.39              | 1.36  | 0.98 | 0→1   |
| ValidUtf16leToUtf8    | 1.38             | 1.39  | 1.00 | 0→0   | 1.42             | 1.45  | 1.00 | 0→0   | 1.34              | 1.36  | 1.01 | 3→2   |
| Utf16leToUtf16be      | 1.36             | 1.43  | 1.04 | 0→0   | 2.65             | 2.81  | 1.05 | 0→0   | 1.51              | 1.70  | 1.12 | 0→0   |
| ValidUtf16leToUtf16be | 0.95             | 1.00  | 1.05 | 3→2   | 1.01             | 1.03  | 1.01 | 5→4   | 1.03              | 1.03  | 1.01 | 1→2   |
| Utf16leToUtf32        | 1.10             | 1.09  | 0.99 | 0→1   | 1.09             | 1.14  | 1.04 | 2→0   | 1.34              | 1.32  | 0.99 | 1→1   |
| ValidUtf16leToUtf32   | 1.09             | 1.08  | 0.99 | 1→3   | 1.23             | 1.28  | 1.04 | 2→1   | 1.42              | 1.41  | 1.00 | 0→0   |
| Utf16leToLatin1       | 1.02             | 1.07  | 1.04 | 2→2   | 1.79             | 1.80  | 1.01 | 0→0   | 1.68              | 1.72  | 1.01 | 0→0   |
| ValidUtf16leToLatin1  | 1.21             | 1.21  | 1.01 | 3→4   | 1.28             | 1.28  | 0.99 | 0→1   | 2.15              | 2.16  | 1.01 | 0→0   |
| Utf16beToUtf8         | 1.35             | 1.34  | 0.99 | 0→0   | 1.48             | 1.47  | 0.98 | 0→0   | 1.39              | 1.41  | 1.01 | 1→1   |
| ValidUtf16beToUtf8    | 1.37             | 1.37  | 1.00 | 0→0   | 1.45             | 1.44  | 0.99 | 0→0   | 1.36              | 1.35  | 1.01 | 3→1   |
| Utf16beToUtf16le      | 1.38             | 1.46  | 1.06 | 0→0   | 2.83             | 2.95  | 1.04 | 0→0   | 1.52              | 1.66  | 1.08 | 0→0   |
| ValidUtf16beToUtf16le | 0.95             | 1.01  | 1.06 | 2→0   | 1.01             | 1.04  | 1.02 | 3→4   | 1.03              | 1.02  | 1.00 | 1→1   |
| Utf16beToUtf32        | 1.10             | 1.10  | 1.00 | 2→0   | 1.08             | 1.10  | 1.00 | 1→1   | 1.33              | 1.36  | 1.02 | 0→0   |
| ValidUtf16beToUtf32   | 1.09             | 1.11  | 1.01 | 2→1   | 1.13             | 1.12  | 0.99 | 0→3   | 1.33              | 1.38  | 1.03 | 0→0   |
| Utf16beToLatin1       | 1.05             | 1.04  | 0.99 | 2→2   | 1.69             | 1.67  | 0.99 | 0→0   | 1.57              | 1.56  | 0.99 | 0→0   |
| ValidUtf16beToLatin1  | 1.30             | 1.29  | 0.99 | 2→1   | 1.42             | 1.44  | 1.02 | 1→0   | 2.19              | 2.14  | 0.98 | 0→0   |
| Utf32ToUtf8           | 1.95             | 1.95  | 0.99 | 1→0   | 1.27             | 1.29  | 1.01 | 0→0   | 1.41              | 1.44  | 1.03 | 0→0   |
| ValidUtf32ToUtf8      | 2.07             | 2.04  | 0.98 | 0→0   | 1.38             | 1.35  | 0.99 | 0→0   | 1.47              | 1.47  | 1.01 | 0→0   |
| Utf32ToUtf16le        | 1.20             | 1.21  | 1.00 | 0→1   | 1.33             | 1.31  | 1.00 | 0→0   | 1.13              | 1.15  | 1.01 | 1→2   |
| ValidUtf32ToUtf16le   | 1.37             | 1.37  | 1.00 | 1→2   | 1.99             | 1.96  | 0.99 | 1→1   | 1.70              | 1.74  | 1.03 | 1→1   |
| Utf32ToUtf16be        | 1.36             | 1.35  | 1.00 | 1→1   | 1.45             | 1.44  | 1.01 | 0→0   | 1.02              | 1.02  | 1.00 | 6→5   |
| ValidUtf32ToUtf16be   | 1.51             | 1.51  | 1.00 | 1→1   | 1.99             | 1.99  | 1.00 | 0→0   | 1.67              | 1.69  | 1.01 | 0→1   |
| Utf32ToLatin1         | 1.17             | 1.17  | 1.01 | 0→0   | 1.28             | 1.28  | 1.00 | 0→1   | 1.14              | 1.14  | 1.01 | 0→0   |
| ValidUtf32ToLatin1    | 1.29             | 1.28  | 1.00 | 0→0   | 1.46             | 1.44  | 0.99 | 0→1   | 1.40              | 1.39  | 1.00 | 2→2   |
| Latin1ToUtf8          | 0.92             | 0.99  | 1.07 | 8→2   | 1.76             | 1.71  | 0.97 | 0→0   | 1.47              | 1.44  | 0.98 | 0→0   |
| ValidLatin1ToUtf8     | 0.94             | 1.02  | 1.08 | 6→3   | 1.73             | 1.68  | 0.96 | 0→0   | 1.48              | 1.51  | 1.02 | 0→0   |
| Latin1ToUtf16le       | 1.05             | 1.00  | 0.95 | 0→2   | 1.14             | 1.17  | 1.03 | 2→1   | 0.98              | 1.12  | 1.14 | 4→0   |
| ValidLatin1ToUtf16le  | 1.06             | 1.02  | 0.97 | 1→2   | 1.19             | 1.22  | 1.01 | 0→0   | 1.04              | 1.16  | 1.11 | 3→0   |
| Latin1ToUtf16be       | 1.09             | 1.08  | 0.99 | 0→2   | 1.09             | 1.11  | 1.01 | 1→0   | 1.12              | 1.15  | 1.02 | 1→2   |
| ValidLatin1ToUtf16be  | 1.11             | 1.09  | 0.98 | 0→0   | 1.16             | 1.14  | 0.99 | 1→0   | 1.20              | 1.22  | 1.00 | 0→0   |
| Latin1ToUtf32         | 1.15             | 1.13  | 0.99 | 0→0   | 1.18             | 1.16  | 1.00 | 0→0   | 1.06              | 1.07  | 1.00 | 0→0   |
| ValidLatin1ToUtf32    | 1.17             | 1.17  | 1.00 | 1→0   | 1.19             | 1.18  | 0.99 | 0→0   | 1.11              | 1.12  | 1.00 | 1→0   |
| all                   | 1.22             | 1.23  | 1.01 | 55→35 | 1.46             | 1.47  | 1.01 | 26→23 | 1.37              | 1.40  | 1.02 | 35→24 |

The `×old` column of an op whose code did not change reads 0.95-1.05: layout, as below.

## What changed

### The valid byte swap (`swapValid`)

The baseline had the valid swap at 0.93-0.94 of `icelake`, behind at every size from 16 B to 4 KiB in both byte orders. Wave 3 blamed buffer placement; the new harness places every arm's buffers alike and the gap stayed. The loop was one block a step: `vpshufb` from memory, the store, an add, a compare, a jump. In the old `bench-utf` that loop crossed a 64-byte code boundary and ran at about 1.6 cycles a block, where in the layout driver, a different binary, it sat in one 64-byte window and ran at 1 cycle, the rate simdutf's loop runs at. Nothing in Zig aligns a loop, so the fix takes the boundary out of the loop's cost: `swapValid` swaps four blocks a step (the first step aligned to the output), then the last one to four blocks with no loop, the last ending at the end of the input and rewriting a few units with the same values. Fewer than 32 units take one masked load and store (AVX-512), or the first and last 16, 8, or 4 units. Native (`fin-nat`): 4 KiB 1.74× (LE) and 1.78× (BE) `old`, 256 B 1.27-1.29×; over the op 1.05-1.06×, 0.95 to 1.00-1.01 of `icelake`. The rows under simdutf left are 16 B (0.93) and the `latin` row at 0.99.

### The checked byte swap

After a block without a surrogate, `swapBlocks` takes two blocks a step while neither holds one: one test for both, where a block a step was about ten instructions. Not after a block with one: in emoji every try fails, and an earlier version that tried after every block ran emoji at 0.61-0.64× (`n3`). With the condition, ASCII at 4 KiB 1.49-1.68× the version before it and emoji 0.97× (`n4`); over the op 1.04-1.06× `old` native, 1.04-1.05× AVX2, 1.08-1.12× SSE. The 64-unit rows read 0.77-0.84× `old` native (the first step and the end block, now with the inner loop's bound test between them) and stay 1.5-1.6 of `icelake`.

### AVX-512 Latin-1 to UTF-8

- `latin1Encode512Block` builds each half the way simdutf's `icelake` kernel does: one `vpermb` interleaves bytes `i` and `32 + i` into 16-bit lanes, `vpshldw` (`llvm.fshl.v32i16`) shifts 0xC2 in, a masked add of 0xC001 makes the lead and continuation for bytes at or above 0xC0, and a ternary-logic blend makes the upper half; `vpcompressb` packs each half by `pdep` of its high bits, the upper half's from `pext`, and its count from the whole block's popcount less the lower half's. Two `vpermt2b` and blends before; that and a byte-domain affine variant both ran 0.82-0.87 of `icelake` in the layout driver, this one 1.01-1.02 at 4-64 KiB. Harness (`fin-nat`): Latin-1 text at 4 KiB 1.19-1.20× `old` (0.99-1.02 of `icelake`).
- Up to 64 bytes go through `latin1ToUtf8Short`: one load, two 32-byte steps, before the main loop loads its dozen constants. 16 B 1.20-1.27× `old`, 64 B of Latin-1 1.15-1.23×. An out-of-line main loop, so the short path saved no registers, was 0.88× at 256 B for the call (`n3`, rejected).
- ASCII blocks first, two then one a step, in loops of their own before the main loop's constants: ASCII at 256 B 1.13-1.16× `old`, at 4 KiB 1.09-1.13× (1.36-1.38 of `icelake`).

### AVX-512 UTF-8 to Latin-1

`utf8ToLatin1Avx512` is full 64-byte blocks, then at most one masked partial block, each a copy of `utf8ToLatin1Step`, so the loop tests no length but its own; a step loads its block once, keeps bytes below 0xC0, and decodes with `select(before == 0xC3, v ^ 0x40, v)` from a load one byte back. Over the op 1.13× (checked) and 1.14× (valid) `old`; Latin-1 text 1.04-1.66×, ASCII at 4 KiB 1.08-1.10×.

### AVX-512 UTF-16 to Latin-1

The tail is one masked step that returns directly. Checked, 16 B 1.12-1.15× `old`.

### UTF-8 to UTF-16 and UTF-32

- AVX-512: an ASCII block at 64 bytes or more stores whole registers, not `storeWidened`, which tests each register's page for a masked store: UTF-32 on 256 B of ASCII 1.18× `old`.
- `utf8BlockEnd` reads the block's last four bytes with a volatile load. With `rem >= 64` in the block test LLVM took them from the block's register with `vextracti32x4` and `vpextrd`, on the shuffle port the decode saturates, and every non-Latin row ran at 0.66-0.77× `old` (`nat`); with the volatile load the ops are back at 1.00-1.03×.
- AVX2 and SSE: a run of ASCII goes through a loop of its own with one countdown bound, where as a branch of the main loop it took three jumps a block (`widenAscii`): AVX2 4 KiB of ASCII 1.26-1.38× to UTF-16, 1.19-1.24× to UTF-32 (`fin-v3`). On AVX2 the 16-byte loads are plain, folding into `vpmovzx` (widened from a register, each upper half takes a `vextracti128` on the same port); on SSE they are volatile, keeping one load and two `punpck`, where folded `pmovzx` loads take 8 or 4 bytes each.

### UTF-16 to UTF-32, AVX2

A countdown loop, and little-endian widens straight from 16-byte memory loads: 4 KiB of ASCII 1.38-1.40× `old`, 64 B 1.18-1.21×.

### UTF-8 to Latin-1, AVX2 and SSE

The ASCII run gets the same loop of its own: 4 KiB of ASCII 1.45-1.64× `old` on AVX2 (valid 0.80 of `haswell` to 1.39), 1.34-1.46× on SSE (`fin-v3`, `fin-v2`; `l1v3` and `l1v2` time it against the build before it).

### Latin-1 to UTF-16 and UTF-32, AVX2 and SSE

UTF-16 widens through `widenAscii` from 16-byte loads, volatile on SSE: SSE Latin-1 to UTF-16 1.11-1.14× over the op, 4 KiB 1.42-1.48×. UTF-32 keeps one 64-byte load (16-byte loads cost SSE 15% at 4 KiB, `v2a`). The checked form returns as soon as the vector loops finish, not after an empty scalar call.

## Rejected

- AVX-512 Latin-1 to UTF-8: two `vpermt2b` with `vpmovb2m` keep masks, and a byte-domain affine with two `vpermt2b`: 0.82-0.87 of `icelake`. The main loop out of line behind the short path: 256 B 0.88×.
- A masked swap of exactly 32 units: slower than a plain load and store.
- 16-byte loads for SSE Latin-1 to UTF-32: 0.82-0.86× at 4 KiB.
- The checked swap's two-block loop after every block: emoji 0.61-0.64×.

## Rows still under simdutf

From `fin-nat`, `fin-v3`, and `fin-v2`, outside the noise.

- **Code layout, not the code.** The function's instructions are identical to `old`'s on the hot path (objdump of the exported function from both trees, [asm-identical.txt](convert-wave4-20261031/asm-identical.txt)), and the row moves with the binary: native `Latin1ToUtf16le` at 64 B (0.89-0.94 of `icelake`, 0.80× `old` with the same instructions), `ValidUtf16leToUtf32` at 16-256 B (0.92-0.97), AVX2 `Latin1ToUtf8` (0.96-0.97× `old` over the op with identical instructions, still 1.68-1.71 of `haswell`). Loop alignment is one mechanism, measured for the swap above; Zig has no way to align a loop, so these move with every link.
- **Short calls, 16-64 B, native** (0.80-0.96): UTF-16 to Latin-1 at 16 B (0.80-0.92), Latin-1 to UTF-16 at 16-64 B (0.89-0.96), UTF-32 to UTF-16 and the valid swap at 16 B (0.86-0.94), UTF-16 to UTF-32 at 64 B (0.90). One to two nanoseconds a call, not attributed by measurement: candidates are the page tests in `simd.loadShort` and `simd.storePartial` and the callee-saved registers some kernels push on entry before their short path (the exported `validLatin1ToUtf8` pushes six before its 64-byte short path). Not closed here; the shared short-path helpers are another owner's.
- **AVX-512 Latin-1 to UTF-8 on Latin-1 text at 64-256 B** (0.82-0.93): the steady state is level from 4 KiB, so this is per-call cost. At 256 B we take 17.6 ns, about 46 cycles at 2.6 GHz, to simdutf's 14.6 ns: the main loop loads a dozen constants before its first block and tests the first block three times (the ASCII loops, then the loop's own test). Not closed.
- **AVX2 UTF-16BE to UTF-32 on 4 KiB of ASCII** (0.89; 0.87 in the baseline): big-endian units widen from the register they were swapped in, a byte shuffle and two widenings with a lane extract per 16 units, all on the shuffle port; not changed.
- **SSE UTF-16 to UTF-8 on Korean, Hindi, and Japanese** (0.87-0.98) and SSE UTF-32 to UTF-16 on CJK and Hindi (0.92-0.98): unchanged code, at 1.36-1.41 and 1.02-1.15 over the op.
- **64 KiB and 1 MiB rows** (0.89-0.99, all levels): out of L2 or memory-bound, where both arms run 5-25 GB/s; unchanged loops.

## Memory

Peak RSS (`/usr/bin/time -f %M` of `bench-utf check OP`, the harness's measure, [rss.sh](convert-wave4-20261031/rss.sh)) for `old` and this branch, native, over every conversion op ([rss.txt](convert-wave4-20261031/rss.txt)): equal on 36 ops, 0.1 MiB more on 4 (`utf8-to-utf32`, `utf16be-to-latin1` and its valid form, `valid-latin1-to-utf8`), the binary's larger text. Against std, where std has the op, as in the baseline (`utf8-to-utf16le` 4.9 against 4.7).

## Correctness

`largeCases` in `src/convert.zig`: every conversion on 32 × 21845 + 35 = 699,075 code points, so at least that many units in every format, past the 699,040 units where wave 3 found a bug, of ASCII, Latin-1, and mixed text, checked and valid against the scalar reference with the whole output compared, and checked with an error in the last 100 units, at every level `dispatch.forEachLevel` runs.

Gates on the final tree ([gates.txt](convert-wave4-20261031/gates.txt)): ReleaseSafe at `-Dcpu=native`, `x86_64_v3` with and without dispatch, `x86_64_v2` without, and `baseline` with and without; baseline Debug; ReleaseSafe and Debug on `aarch64-linux-musl` and ReleaseSafe on `aarch64_be-linux-musl` under qemu-user 11.1.2 (two skipped there, the x86 tier tests); `just oracle`, 0 mismatches under `icelake` and `fallback`; `just ci`.

## Files

[convert-wave4-20261031/](convert-wave4-20261031/): `hb.sh`, `ab.sh`, `table.py`, `rowcmp.py`, `gates.sh`, `rss.sh`, `asm/`; `gates.txt`; `asm-identical.txt`; `rss.txt`; and one directory per A/B with `summary.txt`, `rows.txt`, and the arms' per-round GB/s, gzipped. `fin-nat`, `fin-v3`, `fin-v2` are the final runs (`fin-nat` timed a build whose `.text` is byte-identical to the final tree's native build) (`before-summary.txt` and `after-summary.txt` are `old` and `new` against simdutf); `nat` is the native run that found the UTF-8 decode regression; `n2`-`n5` the Latin-1 to UTF-8 and checked swap steps (arms named in each summary: `w4a` the tree at `nat`, `na` the out-of-line main loop, `nb` inline, `nc` the ASCII prefix and the swap condition, `nd` the two-block ASCII prefix); `v2a`, `v2b` SSE widening; `v3a` the AVX2 loops; `l1v3`, `l1v2` AVX2 and SSE UTF-8 to Latin-1.
