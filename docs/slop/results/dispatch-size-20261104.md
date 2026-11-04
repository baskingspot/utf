# Constants of dispatching builds, 2026-11-04

A program built for a generic x86-64 CPU links utf's tier objects, one per ISA above its own (`src/dispatch.zig`, `addDispatch` in build.zig). baskingspot/encoding's repin to v0.2.0 (encoding's utf-repin-20261104.md) found that dispatch costs a one-encoding single-byte program 34–56 KB in ReleaseSmall, most of it constants. [bmp-converters-20261104.md](bmp-converters-20261104.md) named two causes: the AVX-512 object's single `.rodata` section (26.4 KB), and the BMP shuffle tables copied into both the SSE and the AVX2 object (25.6 KB). Both are fixed here.

## Takeaways

- **The AVX-512 constants were LLVM constant pools, not data.** The tier objects were already built with `-ffunction-sections -fdata-sections`, and every named table had a section of its own. The 26,434-byte `.rodata` holds no symbols: it is 445 pool entries for the functions in the object, each used by one function. They are 64-byte AVX-512 vectors and 1- and 2-byte broadcast sources, which fit none of ELF's mergeable `.rodata.cst4/8/16/32` sections. LLVM puts all such entries in one `.rodata` per object, whatever `-fdata-sections` says, and the linker keeps the section whole once any kernel uses one entry. Zig passes no LLVM option that changes this.
- **Fix 1: each function's pool in a section of its own.** build.zig now has LLVM emit each tier object as assembly. A small host tool, `build/pools.zig`, renames each `.section .rodata,"a",@progbits` (one per function's pool) to a unique `.rodata.utf_poolN`, and Zig assembles the result into the object. `--gc-sections` then keeps a function's pool only with the function. This is done for ELF only; COFF and Mach-O tier objects are built as before and were not measured. A program that calls both BMP converters at baseline has 18,350 bytes of `.rodata` instead of 57,710.
- **Fix 2: one copy of the BMP tables.** `dispatch.shared(name, value)` makes a table that kernels in more than one tier read. The main object exports it under the build's symbol prefix and the table's name, and the tier objects reference that name (weakly, so that Debug builds, which keep unreached tier kernels, still link). `pack_narrow`, `pack_quads`, and `pack_units` (12.5 KB) are now in a program once.
- **Sizes, ReleaseSmall, a program calling both BMP converters:** baseline with dispatch 78,197 → 38,861 bytes, x86-64-v2 71,001 → 31,909, x86-64-v3 52,158 → 26,318. Builds without dispatch, native, and aarch64 are the same size as before. One general converter (`convert.utf8ToUtf16le`) at baseline: 96,603 → 71,155. Its SSE and AVX2 objects still each carry 24 KB of the general converters' tables, which this change does not share (decision 1).
- **Sizes in encoding's `bench/comptime`, ReleaseSmall:**
  - `DecoderFor(&.{.windows_1252})` for x86-64-v3 47,177 → 20,745 bytes, -v2 58,925 → 23,285, baseline 62,364 → 26,480.
  - `EncoderFor` for x86-64-v3 45,546 → 19,786, -v2 54,272 → 23,876, baseline 58,343 → 27,979.
  - The full `Decoder` and `Encoder` are 23.6–32.5 KB smaller.
  - What dispatch still costs a one-encoding program is 7.6–20 KB, down from 34–56 KB: the higher tiers' kernels (AVX-512 at -v3; AVX2 too at -v2; SSE too at baseline), their constants, and `dispatch.init`.
- **Speed is level, with one exception that comes from table placement.** An interleaved A/B of before (origin/main `fab8ea5`) against after, 10 rounds on CPU 3, covered the BMP converters (70 rows) and six general converters (92 rows). It ran at baseline with dispatch, at baseline with dispatch pinned to the AVX2 and to the SSE tier (which read the shared tables), at x86-64-v3 with dispatch, and natively. Every operation's geomean is between 0.992 and 1.015. One row is slower on a rerun: 16-byte Hindi to UTF-16 in the AVX2 tier, +4.6%. Its kernel is unchanged, but its table now sits differently against cache lines ([General converters](#general-converters)).
- **The assembler needs the CPU.** The first after-build was 3–5% slower on 16-byte conversions in the AVX2 tier, because Zig assembles `.s` files with no `-mcpu` and LLVM then pads loops with 10-byte NOPs instead of 15-byte ones. build.zig passes `-march` to the assembler, and the general kernels' instructions are again identical to before.

## Setup

- Machine: Amp orb, KVM guest, Intel Xeon @ 2.60GHz (Ice Lake server, family 6 model 106, AVX-512 with VBMI2), 4 vCPUs, TSC at 2.6 GHz. Zig 0.16.0, LLD for the links. Every timed process ran on CPU 3 (`taskset`), and nothing was built while anything was timed.
- utf sizes: `bmpb/` (from [bmp-converters-20261104](bmp-converters-20261104/bmpb/), plus a `gen-from8` program calling `convert.utf8ToUtf16le`) and `sizes.sh`. Each program reads stdin, converts, and writes; the figure is `.rodata` + `.text` net of a copy-only program, ReleaseSmall and stripped. `before` is a worktree of origin/main `fab8ea5`, and `after` is this branch.
- encoding sizes: encoding origin/main `3d03586`, `bench/comptime`'s `zig build sizes -Doptimize=ReleaseSmall` for each target, net of `size-none`. `before` is its pinned utf v0.2.0. `after` is the same build with `--fork=` this checkout ([encsizes.sh](dispatch-size-20261104/encsizes.sh)).
- Speed: [arms.sh](dispatch-size-20261104/arms.sh) builds each side's `bmpb` and `bench-utf` (bench/) at baseline with dispatch, at x86-64-v3 with dispatch, and natively. It also builds baseline with dispatch pinned to the AVX2 or SSE tier, by patching `best` in `src/dispatch.zig` to take only that tier; on this CPU, dispatch otherwise always picks AVX-512. [bench.sh](dispatch-size-20261104/bench.sh) times them with [serve-ab.py](bmp-converters-20261104/serve-ab.py): every arm is a server on CPU 3, every row is timed by every arm back to back in a rotating order, and each round starts fresh processes. Round 0 sizes the loops; then come 10 rounds. Then `summary.py` (geomean of per-row median ratios; [gensummary.py](dispatch-size-20261104/gensummary.py) for `bench-utf`'s row names) and benchstat.
- The scripts name the paths they ran with: `/tmp/old.sh` puts the `zig-old` shell's tools on PATH, `/tmp/utf-before` is a worktree of `fab8ea5`, `/tmp/bmpb` is `bmpb/` with its `build.zig.zon` pointing at the checkout, and `/tmp/encoding` is the encoding checkout.

## The constant pools

`readelf -S` on the AVX-512 object from a baseline ReleaseSmall build (`utf-avx512.o`, before):

```
  [ 3] .rodata.cst4      PROGBITS        0000000000000000 000048 000068 04  AM  0   0  4
  [ 4] .rodata           PROGBITS        0000000000000000 0000c0 006742 00   A  0   0 64
  [22] .rodata.cst8      PROGBITS        0000000000000000 009288 000038 08  AM  0   0  8
  [23] .rodata.cst32     PROGBITS        0000000000000000 0092c0 000080 20  AM  0   0 32
  [24] .rodata.cst16     PROGBITS        0000000000000000 009340 0000a0 10  AM  0   0 16
  [212] .rodata..L__anon_24409 PROGBITS        0000000000000000 022fec 001000 00   A  0   0  4
  [213] .rodata..L__anon_25585 PROGBITS        0000000000000000 023fec 001000 00   A  0   0  4
  [214] .rodata..L__anon_23085 PROGBITS        0000000000000000 024fec 000100 00   A  0   0  1
  [215] .rodata..L__anon_24481 PROGBITS        0000000000000000 0250ec 000100 00   A  0   0  1
  [216] .rodata..Lsimd.narrow_bytes PROGBITS        0000000000000000 025200 000080 00   A  0   0 64
```

Section 4 is 26,434 bytes and holds no symbol.

The emitted assembly switches to `.section .rodata,"a",@progbits` 89 times, once per function with a pool. Relocations from `.text` into `.rodata` come from 89 functions and point at 445 distinct offsets, none of them reached from two functions. Spacing of those offsets (alignment padding included): 187 of 64 bytes, 40 of 128, 100 of 2, 43 of 1, and the rest 54–384. Before the change, a program that called both BMP converters at baseline linked all of it. [attr.py](dispatch-size-20261104/attr.py), which finds each object section's bytes in the program's `.rodata`, found all 26,434 bytes there.

Before any build change, I renamed the AVX-512 object's 89 `.section .rodata` lines by hand to `.rodata.cpN`, assembled the result, and relinked that program by hand from the same objects. Its `.rodata` went from 58,030 bytes to 32,206, and its output on the Thai and windows-1252 corpora did not change. That confirmed the cause. `build/pools.zig` does the same renaming for every tier object. With it and the shared tables, the program built normally has 18,350 bytes of `.rodata`, against 57,710 before.

The cost: the tier objects are compiled to assembly and assembled, and a dispatching build compiles `build/pools.zig` once for the host.

### The assembler needs the CPU

The first after-build was 3–5% slower than before on 16-byte general conversions in the AVX2 tier. A rerun of eight rows over 20 rounds, both arms pinned to AVX2, confirmed it: `Latin1ToUtf8/ascii-16` +4.86%, `Utf8ToUtf16le/hindi-16` +4.59%, `Utf32ToUtf8/ascii-16` +4.50%, all p=0.000 ([run-focus-nopfix/](dispatch-size-20261104/run-focus-nopfix/)). The kernels' instructions and placement modulo 64 were the same. Only the loop alignment padding was different: one 15-byte NOP (`data16 ×5 cs nopw`) had become two, a 10-byte `cs nopw` and a `nopl`. Zig runs `clang -c utf-avx2.s` with no `-mcpu`, so LLVM's assembler uses generic tuning, whose longest NOP is 10 bytes. The direct object had the tier model's `fast-15bytenop`. build.zig now passes `-march=<the tier's model>` (`x86-64-v2`, `-v3`, `-v4`) to the assembler. Afterwards, [samecode.py](dispatch-size-20261104/samecode.py), which compares disassembly with addresses masked, found all 183 tier kernels of `bench-utf` at baseline with the same instructions as before (61 of 61 at x86-64-v3); before the fix, 123 of the 183 had differed. In `bmpb`, the four SSE and AVX2 BMP kernels differ, because they now load the shared tables' address from the extern and their registers are allocated around it. The other eight tier kernels match. Every speed figure below is from builds made after this fix.

## Sizes ([sizes-before.txt](dispatch-size-20261104/sizes-before.txt), [sizes-after.txt](dispatch-size-20261104/sizes-after.txt))

Bytes, ReleaseSmall, stripped, `.rodata` + `.text` net of the copy program; `nd` is `-Dutf-dispatch=false`.

| build               | BMP, both: before |  after | `utf8ToUtf16le`: before |  after |
| ------------------- | ----------------: | -----: | ----------------------: | -----: |
| baseline, dispatch  |            78,197 | 38,861 |                  96,603 | 71,155 |
| x86-64-v2, dispatch |            71,001 | 31,909 |                  95,081 | 69,633 |
| x86-64-v3, dispatch |            52,158 | 26,318 |                  64,071 | 39,119 |
| baseline, nd        |             7,346 |  7,346 |                   1,389 |  1,389 |
| x86-64-v2, nd       |            17,958 | 17,958 |                  30,209 | 30,209 |
| x86-64-v3, nd       |            16,160 | 16,160 |                  28,021 | 28,021 |
| native (AVX-512)    |             3,272 |  3,272 |                   4,006 |  4,006 |
| aarch64             |            16,624 | 16,624 |                  28,216 | 28,216 |

What dispatch still costs at baseline, for both BMP converters (31.5 KB over the build without it), is the one copy of the BMP tables (12,544 bytes), the three tiers' BMP kernels and their pools, and `dispatch.init`. For `utf8ToUtf16le`, the SSE and AVX2 objects each carry `utf8_windows` (11,536 bytes), an 8 KB table, `compress_words` (4 KB), and `utf16_pairs`: 24 KB twice.

## Sizes in encoding ([encsizes.txt](dispatch-size-20261104/encsizes.txt))

Bytes, ReleaseSmall, `.rodata` + `.text` net of `size-none`; "off" is `-Ddispatch=false`.

| program                             | target    | utf v0.2.0 | this branch |  change |
| ----------------------------------- | --------- | ---------: | ----------: | ------: |
| `DecoderFor(&.{.windows_1252})`     | x86-64-v3 |     47,177 |      20,745 | −26,432 |
|                                     | x86-64-v2 |     58,925 |      23,285 | −35,640 |
|                                     | baseline  |     62,364 |      26,480 | −35,884 |
| `EncoderFor(&.{.windows_1252})`     | x86-64-v3 |     45,546 |      19,786 | −25,760 |
|                                     | x86-64-v2 |     54,272 |      23,876 | −30,396 |
|                                     | baseline  |     58,343 |      27,979 | −30,364 |
| `DecoderFor` UTF-8 and windows-1252 | x86-64-v3 |     64,121 |      38,873 | −25,248 |
|                                     | x86-64-v2 |     81,570 |      47,162 | −34,408 |
|                                     | baseline  |     86,509 |      51,809 | −34,700 |
| `Decoder`, any label                | x86-64-v3 |    302,157 |     278,557 | −23,600 |
|                                     | x86-64-v2 |    349,353 |     316,849 | −32,504 |
|                                     | baseline  |    349,326 |     316,834 | −32,492 |
| `Encoder`, any label                | x86-64-v3 |    227,902 |     203,358 | −24,544 |
|                                     | x86-64-v2 |    242,277 |     213,161 | −29,116 |
|                                     | baseline  |    249,027 |     219,863 | −29,164 |

The host, and every target with `-Ddispatch=false`, are the same size as before. The windows-1252 decoder with dispatch is now 7.6 KB (x86-64-v3), 9.2 KB (-v2), and 20.0 KB (baseline) over the same build without it, where it was 34.0, 44.8, and 55.8 KB.

## Speed

### BMP converters ([run-bmp/](dispatch-size-20261104/run-bmp/))

After against before; above 1, after is faster. Geomean over 35 rows each, and the extreme rows.

| arm                          | to UTF-8 | range       | from UTF-8 | range       |
| ---------------------------- | -------: | ----------- | ---------: | ----------- |
| baseline, dispatch (AVX-512) |    1.003 | 0.977–1.054 |      1.000 | 0.955–1.026 |
| baseline, pinned to AVX2     |    1.002 | 0.960–1.040 |      1.015 | 0.976–1.062 |
| baseline, pinned to SSE      |    1.002 | 0.978–1.029 |      0.992 | 0.963–1.010 |
| x86-64-v3, dispatch          |    0.998 | 0.948–1.032 |      0.999 | 0.981–1.021 |
| native                       |    1.002 | 0.981–1.029 |      0.998 | 0.977–1.031 |

The native arms' kernels are the same code on both sides, so their spread, 0.977–1.031, is this machine's noise. The pinned arms read the shared tables through the weak references. The pins took: the AVX2 arm takes 0.76× (from UTF-8) and 0.79× (to UTF-8) the time of the SSE arm, and the AVX-512 arm 0.60× and 0.72× the time of the AVX2 arm (geomeans, after side). The lowest size-group geomean is 0.985, the SSE arm from UTF-8 at 4,096 bytes.

### General converters

After against before, geomean by operation over [run-gen/](dispatch-size-20261104/run-gen/) (`bench-utf serve`, 92 rows: six texts at 16 bytes, ASCII from 16 bytes to 64 KiB, and whole corpora). In the last two columns, "p<0.05" counts rows that benchstat calls slower or faster at p<0.05, each a separate test of 10 samples.

| arm                          | validate | 8→16le | 8→latin1 | 16le→8 |  32→8 | latin1→8 |   all | range       | p<0.05 slower / faster |
| ---------------------------- | -------: | -----: | -------: | -----: | ----: | -------: | ----: | ----------- | ---------------------: |
| baseline, dispatch (AVX-512) |    0.999 |  0.999 |    0.996 |  0.998 | 1.001 |    0.996 | 0.998 | 0.973–1.031 |                  0 / 2 |
| baseline, pinned to AVX2     |    1.000 |  0.995 |    1.000 |  0.997 | 1.001 |    0.995 | 0.998 | 0.953–1.053 |                  4 / 2 |
| baseline, pinned to SSE      |    0.995 |  0.998 |    0.998 |  1.014 | 1.007 |    1.001 | 1.002 | 0.960–1.117 |                  2 / 5 |
| x86-64-v3, dispatch          |    1.000 |  0.999 |    1.004 |  0.998 | 1.003 |    1.000 | 1.001 | 0.977–1.026 |                  1 / 0 |
| native                       |    0.999 |  0.999 |    1.001 |  1.001 | 1.001 |    1.012 | 1.001 | 0.973–1.059 |                  0 / 0 |

For the BMP run, the same counts are 0/2, 2/18, 5/3, 0/0 and 0/0.

One row is slower and stays slower on a rerun: `Utf8ToUtf16le/hindi-16` with the AVX2 tier, 13.20 → 13.80 ns (+4.6%, p=0.000 over 20 rounds, [run-focus2/](dispatch-size-20261104/run-focus2/)). Of the other three AVX2 rows benchstat flagged, `ValidateUtf8/korean` was level in that rerun and `Latin1ToUtf8/latin1-4096` was +2.3% (p=0.021); `Utf8ToLatin1/latin1-64` (+1.1%) was not rerun. The Hindi row's kernel is the same code before and after, at the same address modulo 64. What moved is its table: the AVX2 object's copy of `convert.utf8_windows` (209 16-byte shuffles and an index, alignment 1) starts at 34 mod 64 before and 26 after. A different set of shuffles now straddles a cache line, and 16-byte Hindi uses one of them. Rebuilding the after arm with `utf8_windows` aligned to 16 made the row level (13.10 → 13.17 ns, p=0.62). It also left the other 20 `Utf8ToUtf16le` rows level ([run-focus3/](dispatch-size-20261104/run-focus3/), arm `aligned`). So the slowdown comes from where the linker happened to put a table, which any change to what precedes it in `.rodata` can move. It does not come from the shared-table mechanism.

That alignment is not in this branch. Aligning all eight 16-byte shuffle tables in `convert.zig` instead (`utf8_windows`, `utf16_pairs`, `compress_words`, `compress8`, `compress32`, `utf8_pack2/3/4`) fixed the Hindi row and made unrelated ASCII rows slower in the AVX2 arm. `Latin1ToUtf8/ascii-256` was +26.6%, `Utf8ToLatin1/latin1-16` +12.7%, and `ValidateUtf8/ascii-64` +8.6%, all p=0.000 ([run-focus4/](dispatch-size-20261104/run-focus4/), arms `aligned`, against `noalign`, which is this branch). `ValidateUtf8` reads none of those tables. So those are placement effects too, of code or of other constants, and larger ones. This machine moves short-input rows by 5–25% on layout alone. Making the kernels robust to placement is its own piece of work (decision 3).

## Decisions

1. **Share the general converters' tables too.** `utf8_windows`, `utf8_pack2/3/4`, `compress_words`, `compress8/32`, and `utf16_pairs` are in both the SSE and AVX2 objects. They are 24 KB twice in a program that calls `utf8ToUtf16le` at baseline or -v2, and encoding's `Decoder` and `Encoder` link them. `dispatch.shared` does it. The cost is a `_ = table` naming, in each converter's kernel, of every table its SSE and AVX2 versions read, so the main object exports them. A missed name fails only at run time, on a CPU that takes that tier: the weak reference is null and `.?` traps in safe builds. Recommendation: do it in a follow-up with a test that links one program per wired function at baseline and runs it with each tier pinned.
2. **Mach-O and COFF.** macOS and Windows x86-64 builds still link their tier objects as before. Whether their linkers keep a whole object's constants, as LLD did for ELF, was not measured. Recommendation: leave them unless a consumer ships a dispatching build there. If one does, rerun `bmpb/sizes.sh` for that target first.
3. **Placement.** Short-input rows on this machine move by 5% (the Hindi row) to 27% (`Latin1ToUtf8/ascii-256`, with tables aligned) when tables or code shift, with no change to the code. Any change to what a program links can shift them, and so can a consumer's own code. Aligning the 16-byte shuffle tables is the obvious start, but in the one build tried it traded one slow row for three worse ones. Recommendation: accept the one row for v0.2.1. Separately, find what moves the ASCII rows (code alignment of the kernels' loops, or the 64-byte constants) and what makes them robust to it, on more than one CPU.
