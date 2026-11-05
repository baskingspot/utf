# UTF-8 to UTF-32 with U+FFFD in one call, 2026-11-05

`convert.utf8ToUtf32Replacing(src, dst) usize` writes U+FFFD for each maximal subpart of an ill-formed sequence (Unicode chapter 3, Table 3-8; WHATWG; ICU) and goes on, in one call. Ghostty's terminal input decoder (`src/simd/vt.zig`) gets the same output today by looping over `convert.utf8ToUtf32`: at each error it writes U+FFFD, skips the maximal subpart with its own helper, and calls again on the rest. This measures the new function against that loop and against the loop Ghostty had over simdutf.

- Package: `utf8-replacing`, origin/main `026ba6b` with `8bc7ac2`, `eb10f9c`, and `7d9f4b5` from `zig-0.17` cherry-picked (`233eaf8`, `53b5ec7`, `62f9ebb`), plus this change.
- x86: Amp orb, KVM guest, Intel Xeon @ 2.60GHz (Ice Lake server, AVX-512 with VBMI2), 4 vCPUs ([lscpu.txt](replacing-20261105/raw/lscpu.txt)); every timed process pinned to CPU 3, nothing built while anything was timed. Zig 0.17.0, ReleaseFast.
- Apple: Amp macOS satellite, Apple M4 Pro (Virtual), 6 vCPUs, macOS 27; the harness at user-interactive QoS, no pinning (macOS has none). Zig 0.17.0 (Homebrew), ReleaseFast, `native` (the Apple-core paths).
- simdutf: 9.0.0, Ghostty's vendored amalgamation (Ghostty `e95bed63`, `pkg/simdutf/vendor/`), built into the harness by Zig's `c++` in ReleaseFast. Not committed; copy `simdutf.cpp` and `simdutf.h` into `harness/` to rebuild.

## Method

[harness/](replacing-20261105/harness/) is one program with three arms, each a C-ABI function `(input, count, output) -> code points written`, the shape of Ghostty's `decodeUtf8`:

- `simdutf`: Ghostty's loop over `convert_utf8_to_utf32_with_errors`, `count_utf8`, and its `MaximalSubpart`, verbatim (`src/simd/vt.cpp` before the switch).
- `loop`: Ghostty's current loop over `utf.convert.utf8ToUtf32`, verbatim, with its `maximalSubpart` ([shim.zig](replacing-20261105/harness/shim.zig)).
- `replacing`: one call to `utf.convert.utf8ToUtf32Replacing`.

Both utf arms call utf `never_inline`, as a dispatched build does; inlined, the same kernel moved 16-byte rows by up to 40% with the code around it. Inputs follow Ghostty's synthetic UTF-8 generator (`src/synthetic/Utf8.zig`): each sequence is one of Ghostty's nine malformed sequences with probability 0, 0.1, 1, or 5%, else a code point of 1 to 4 bytes with equal weight (`mixed`, the generator's default) or printable ASCII (`ascii`), at 16 B to 1 MiB. Each row has 8 MiB of input (at least 16 chunks) and every call takes the next chunk: with one chunk repeated, the branch predictor learned the errors' places and 4 KiB rows read 1.5-2x faster. Each round times every row on every arm back to back for 20 ms each, in an order that rotates by row and round; 10 rounds after a sizing pass. Columns are each arm's median GB/s of input, and the median per-round ratio of the other arm's time to `replacing`'s with its min and max: above 1, `replacing` is faster. `python3 harness/summary.py raw/<file>.txt [md]` makes the tables.

Builds (in `harness/`, inside `nix develop`): x86 AVX-512, `zig build -Dcpu=baseline -p out-base`, utf dispatching at run time (to AVX-512 VBMI2 here) and simdutf picking `icelake`; AVX2, `zig build -Dcpu=x86_64_v3 -Ddispatch=false -p out-v3` with `SIMDUTF_FORCE_IMPLEMENTATION=haswell`; SSE, `zig build -Dcpu=x86_64_v2 -Ddispatch=false -p out-v2` with `westmere`; Apple, `zig build`. Then `taskset -c 3 ./out-X/bin/ab run 10` (Apple: `./zig-out/bin/ab run 10`). `ab test` first runs 300 000 random inputs (all rates up to 100% malformed, random bytes on top, up to 5000 bytes) through all three and requires the utf arms to agree; it printed 0 disagreements on every build.

## Takeaways

Geomean over the six sizes of `replacing` against each arm (time ratio, above 1 faster):

| error rate | Apple vs loop | vs simdutf | AVX-512 vs loop | vs simdutf | AVX2 vs loop | vs simdutf | SSE vs loop | vs simdutf |
| ---------- | ------------: | ---------: | --------------: | ---------: | -----------: | ---------: | ----------: | ---------: |
| 0%         |          1.05 |       1.65 |            1.10 |       1.63 |         1.06 |       1.84 |        1.06 |       1.65 |
| 0.1%       |          1.05 |       1.73 |            1.24 |       1.86 |         1.07 |       2.03 |        1.06 |       1.80 |
| 1%         |          1.18 |       1.89 |            1.67 |       2.67 |         1.20 |       2.09 |        1.17 |       1.91 |
| 5%         |          1.55 |       1.97 |            1.78 |       2.52 |         1.39 |       2.31 |        1.37 |       2.16 |

- **At Ghostty's 5% rate, from 256 B, one call is 1.8-2.3x the loop on Apple (mixed text), 2.5-2.8x on AVX-512, 1.6-2.0x on AVX2, and 1.5-1.8x on SSE, and 2.7-3.8x simdutf's loop on mixed text everywhere.** ASCII with 5% malformed: 1.4x the loop on Apple, 1.4-1.5x on AVX-512, 1.25-1.3x on AVX2 and SSE.
- **Valid input costs nothing**: the 0% rows match the loop (which then is one `utf8ToUtf32` call) within the noise, and the 16-64 B ones are ahead (ASCII 16 B 1.23-1.39x), one call with no result to inspect.
- **How**: the kernels are `utf8ToUtf32`'s, with `checked: bool` turned into a three-way mode. A block that fails validation no longer ends the block loop. Its error vector (the same three-lookup check, kept per byte) gives the first byte where an error shows; everything before the last lead before that byte is valid, so the block decodes up to that lead as usual (ASCII before it is widened and stored), and a scalar decoder writes the rest one character or maximal subpart at a time until past the error byte; the next block starts there. On AVX-512 that happens inline in the block loop. Elsewhere the block loops call `utf8ReplaceBlocks` out of line, which keeps going while blocks fail, and the 16-byte window loop replaces a failing window inline. Inputs under 80 bytes and the tail take the scalar decoder.
- **Slower rows**: ASCII at 0.1% malformed, 4 KiB, reads 0.92 [0.83, 0.98] of the loop on AVX2, 0.87 [0.80, 1.24] on SSE, and 0.93 [0.89, 1.04] on Apple: four or so errors in 4 KiB of ASCII. Likely the loop's restart after each error lands back on the ASCII fast path sooner than the block-wise replacement, which decodes from the last lead before each error to past it one character at a time and then leaves `utf8ReplaceBlocks` at the next valid block; not measured apart. Apple ASCII 0.1% at 64 KiB and 1 MiB reads 0.97-0.98 (noise). On AVX-512, ASCII at 0.1% from 64 KiB reads 0.77-0.87 of simdutf, but the loop over `utf8ToUtf32` reads the same there (0.76-0.80 of simdutf), so it is the AVX-512 kernel's and not this change's; `replacing` is 1.04-1.14x the loop on those rows.
- **simdutf's loop gives wrong output on AVX-512.** `convert_utf8_to_utf32_with_errors` on simdutf's `icelake` kernel (9.0.0 as Ghostty vendors it, and 9.2.1 from nixpkgs) does not leave the conversion of the input before the error in the output when it fails: on a 192-byte input of ASCII, é, and 世 with 0xFF at byte 188, unit 0 came back U+00E9 where the input has `f`. simdutf documents only the error and position in that case. Ghostty's loop advances by `count_utf8` and keeps whatever is there, so on AVX-512 machines it garbled the text before each error: `ab test` found 77 904 of 300 000 random inputs differ from the utf arms on `icelake`, and 0 on `haswell`, `westmere`, and `arm64`. The utf loop and `replacing` are unaffected: `ConvertResult.written` covers output that is the conversion of the input before the error.
- **Memory**: nothing allocates; `dst` needs `src.len` units, as Ghostty sizes it now.

## Rejected

- **Windows**: replacing by 16-byte windows, each failing window one character at a time. Text with 1-5% malformed ran 0.55-0.65x the loop on AVX2, for the branches the scalar decoder mispredicts.
- **One error, back to the block loop**: replace the first error of a block and return to the block loop for the next. ASCII with 5% malformed took 1.5x as long on Apple, where the next block usually fails too; `utf8ReplaceBlocks` stays while blocks fail.
- **The 16-byte loop calling out**: a call for a failing window spilled the loop's constants on entry and made 16-byte ASCII on Apple 1.6x slower; it is inlined.
- **A `continue` to an outer loop**, and a split of short and long inputs with the long path `never_inline`: LLVM hoisted constants or added a call, and 64-256 B rows lost up to 15% on AVX2.

## Correctness

- `scalar_convert.utf8ToUtf32Replacing` is the reference: Unicode's Table 3-8 example and cases from Tables 3-8 to 3-11, and 200 000 random inputs against `std.unicode.fmtUtf8`, an independent WHATWG implementation.
- `convert.zig`'s tests hold every kernel tier against it on exact output, with a canary past the `src.len` units: every UTF-8 pattern (truncated sequences, surrogates, overlongs, values above U+10FFFF, stray continuations, bytes F5-FF) at every position in five mixes of text up to past a block, every truncation length at the end, dense random corruption, and inputs over 1 MiB with errors, through `dispatch.forEachLevel`. An off-by-one in `utf8FirstError` fails them.
- The oracle's new op `utf8_to_utf32_replacing` is Ghostty's loop over simdutf with the prefix before each error converted again as valid input (`convert_valid_utf8_to_utf32`), since `icelake` leaves other values there. `just oracle` (native AVX-512, simdutf `icelake` and `fallback`) and `just cpu=baseline oracle` (dispatched): 1 638 976 comparisons each, 0 mismatches ([oracle-native.txt](replacing-20261105/raw/oracle-native.txt), [oracle-baseline.txt](replacing-20261105/raw/oracle-baseline.txt)).
- `just check` passes under Zig 0.16 and 0.17; the tests also pass on the Mac (Debug, ReleaseSafe, ReleaseFast).

## Apple M4 Pro

[raw/apple-m4pro.txt](replacing-20261105/raw/apple-m4pro.txt), simdutf `arm64`.

| row                | simdutf GB/s | loop GB/s | replacing GB/s | vs simdutf        | vs loop           |
| ------------------ | ------------ | --------- | -------------- | ----------------- | ----------------- |
| mixed-0%-16        | 0.31         | 0.36      | 0.40           | 1.27 [1.18, 1.34] | 1.11 [1.07, 1.15] |
| mixed-0%-64        | 0.44         | 0.94      | 1.04           | 2.30 [2.17, 2.63] | 1.11 [0.97, 1.17] |
| mixed-0%-256       | 1.05         | 3.29      | 3.10           | 2.98 [2.55, 3.18] | 1.01 [0.75, 1.10] |
| mixed-0%-4096      | 1.80         | 3.58      | 3.63           | 2.09 [1.75, 2.29] | 1.00 [0.97, 1.04] |
| mixed-0%-65536     | 1.87         | 3.89      | 3.89           | 2.10 [2.07, 2.44] | 1.00 [0.98, 1.05] |
| mixed-0%-1048576   | 1.93         | 3.97      | 3.93           | 2.08 [1.66, 2.24] | 1.00 [0.78, 1.03] |
| mixed-0.1%-16      | 0.33         | 0.37      | 0.42           | 1.28 [1.25, 1.31] | 1.15 [1.11, 1.19] |
| mixed-0.1%-64      | 0.46         | 0.92      | 0.98           | 2.21 [2.10, 2.30] | 1.09 [0.95, 1.15] |
| mixed-0.1%-256     | 1.10         | 3.04      | 3.37           | 3.07 [2.89, 3.30] | 1.05 [0.95, 1.16] |
| mixed-0.1%-4096    | 1.73         | 3.69      | 3.70           | 2.14 [2.04, 2.33] | 1.00 [0.98, 1.07] |
| mixed-0.1%-65536   | 1.77         | 3.67      | 3.59           | 2.09 [1.81, 2.29] | 1.02 [0.83, 1.06] |
| mixed-0.1%-1048576 | 1.65         | 3.43      | 3.44           | 2.12 [1.93, 2.52] | 1.00 [0.91, 1.24] |
| mixed-1%-16        | 0.33         | 0.39      | 0.44           | 1.32 [1.07, 1.51] | 1.18 [0.88, 1.24] |
| mixed-1%-64        | 0.41         | 0.79      | 0.84           | 2.05 [1.93, 2.08] | 1.09 [0.99, 1.17] |
| mixed-1%-256       | 0.77         | 1.58      | 2.28           | 3.04 [2.88, 3.18] | 1.42 [1.24, 1.60] |
| mixed-1%-4096      | 1.01         | 2.26      | 2.78           | 2.78 [2.53, 2.99] | 1.24 [1.17, 1.49] |
| mixed-1%-65536     | 1.04         | 1.99      | 2.76           | 2.68 [2.37, 2.77] | 1.34 [1.14, 1.50] |
| mixed-1%-1048576   | 1.06         | 1.94      | 2.77           | 2.57 [2.45, 2.80] | 1.39 [1.26, 1.53] |
| mixed-5%-16        | 0.29         | 0.32      | 0.39           | 1.37 [1.19, 1.44] | 1.21 [1.09, 1.26] |
| mixed-5%-64        | 0.32         | 0.50      | 0.54           | 1.70 [1.67, 1.81] | 1.09 [1.07, 1.15] |
| mixed-5%-256       | 0.39         | 0.58      | 1.06           | 2.73 [2.56, 3.03] | 1.81 [1.64, 1.95] |
| mixed-5%-4096      | 0.44         | 0.64      | 1.38           | 3.28 [3.00, 3.58] | 2.28 [2.01, 2.63] |
| mixed-5%-65536     | 0.45         | 0.65      | 1.47           | 3.32 [3.01, 3.54] | 2.28 [2.02, 2.50] |
| mixed-5%-1048576   | 0.48         | 0.66      | 1.37           | 3.02 [2.43, 3.24] | 2.22 [1.82, 2.40] |
| ascii-0%-16        | 1.80         | 2.96      | 3.94           | 2.10 [1.96, 2.52] | 1.28 [1.24, 1.49] |
| ascii-0%-64        | 4.68         | 7.40      | 8.13           | 1.82 [1.45, 1.90] | 1.15 [0.92, 1.16] |
| ascii-0%-256       | 12.88        | 18.28     | 18.78          | 1.47 [1.41, 1.54] | 1.04 [0.98, 1.08] |
| ascii-0%-4096      | 25.44        | 25.39     | 25.50          | 1.00 [0.97, 1.04] | 1.00 [0.97, 1.02] |
| ascii-0%-65536     | 17.84        | 17.26     | 16.51          | 0.94 [0.89, 0.97] | 0.99 [0.94, 1.01] |
| ascii-0%-1048576   | 16.89        | 16.05     | 16.06          | 0.94 [0.93, 1.01] | 1.00 [0.97, 1.08] |
| ascii-0.1%-16      | 1.39         | 2.60      | 3.27           | 2.30 [2.18, 2.39] | 1.25 [1.21, 1.30] |
| ascii-0.1%-64      | 3.94         | 5.73      | 6.76           | 1.75 [1.67, 1.81] | 1.19 [1.15, 1.21] |
| ascii-0.1%-256     | 8.61         | 12.52     | 13.06          | 1.51 [1.49, 1.57] | 1.06 [0.95, 1.09] |
| ascii-0.1%-4096    | 13.29        | 15.91     | 15.02          | 1.13 [1.08, 1.16] | 0.93 [0.89, 1.04] |
| ascii-0.1%-65536   | 10.71        | 12.29     | 12.72          | 1.13 [1.10, 1.45] | 0.98 [0.92, 1.05] |
| ascii-0.1%-1048576 | 11.16        | 13.09     | 12.04          | 1.11 [1.04, 1.19] | 0.97 [0.86, 1.05] |
| ascii-1%-16        | 1.15         | 1.66      | 2.07           | 1.82 [1.47, 1.98] | 1.25 [1.15, 1.38] |
| ascii-1%-64        | 1.90         | 2.36      | 2.86           | 1.67 [1.42, 1.97] | 1.33 [1.00, 1.67] |
| ascii-1%-256       | 2.08         | 2.90      | 2.75           | 1.51 [1.10, 2.17] | 0.98 [0.84, 1.94] |
| ascii-1%-4096      | 2.45         | 2.73      | 3.33           | 1.51 [1.16, 1.73] | 1.08 [0.99, 1.56] |
| ascii-1%-65536     | 2.48         | 3.16      | 3.02           | 1.40 [1.14, 2.08] | 0.98 [0.83, 1.47] |
| ascii-1%-1048576   | 2.51         | 2.80      | 2.89           | 1.36 [1.09, 1.76] | 1.01 [0.80, 1.64] |
| ascii-5%-16        | 0.50         | 0.64      | 0.86           | 1.74 [1.69, 1.79] | 1.31 [1.26, 1.41] |
| ascii-5%-64        | 0.57         | 0.74      | 0.98           | 1.80 [1.54, 1.92] | 1.34 [1.25, 1.43] |
| ascii-5%-256       | 0.53         | 0.62      | 0.86           | 1.56 [1.52, 1.88] | 1.39 [1.35, 1.50] |
| ascii-5%-4096      | 0.58         | 0.62      | 0.84           | 1.56 [1.27, 1.66] | 1.42 [1.21, 1.55] |
| ascii-5%-65536     | 0.59         | 0.62      | 0.91           | 1.50 [1.33, 1.54] | 1.42 [1.11, 1.57] |
| ascii-5%-1048576   | 0.59         | 0.64      | 0.83           | 1.46 [1.34, 1.61] | 1.41 [1.19, 1.48] |

## x86 AVX-512, dispatched

[raw/x86-avx512-dispatch.txt](replacing-20261105/raw/x86-avx512-dispatch.txt), utf built for baseline x86-64 and dispatching to AVX-512 VBMI2, simdutf `icelake` (whose output before errors is wrong, above; its times stand).

| row                | simdutf GB/s | loop GB/s | replacing GB/s | vs simdutf          | vs loop           |
| ------------------ | ------------ | --------- | -------------- | ------------------- | ----------------- |
| mixed-0%-16        | 0.18         | 0.65      | 0.73           | 4.14 [2.98, 6.39]   | 1.15 [0.82, 1.80] |
| mixed-0%-64        | 0.26         | 2.57      | 2.89           | 10.71 [8.63, 12.36] | 1.10 [1.02, 1.59] |
| mixed-0%-256       | 0.95         | 2.93      | 3.25           | 3.40 [3.14, 3.62]   | 1.09 [1.00, 1.16] |
| mixed-0%-4096      | 4.23         | 3.93      | 4.11           | 0.98 [0.79, 1.11]   | 1.03 [0.88, 1.14] |
| mixed-0%-65536     | 4.71         | 4.08      | 4.32           | 0.92 [0.81, 1.03]   | 1.04 [0.97, 1.14] |
| mixed-0%-1048576   | 4.70         | 4.03      | 4.16           | 0.89 [0.75, 0.94]   | 1.03 [0.95, 1.10] |
| mixed-0.1%-16      | 0.18         | 0.63      | 0.70           | 3.95 [3.13, 4.47]   | 1.10 [0.91, 1.28] |
| mixed-0.1%-64      | 0.26         | 2.21      | 2.81           | 10.56 [9.55, 12.63] | 1.25 [1.13, 1.36] |
| mixed-0.1%-256     | 0.82         | 2.59      | 2.96           | 3.42 [2.83, 3.85]   | 1.17 [0.83, 1.34] |
| mixed-0.1%-4096    | 3.23         | 3.32      | 4.08           | 1.24 [1.18, 1.50]   | 1.24 [1.12, 1.42] |
| mixed-0.1%-65536   | 3.63         | 3.40      | 4.03           | 1.11 [1.02, 1.21]   | 1.19 [1.08, 1.34] |
| mixed-0.1%-1048576 | 3.68         | 3.37      | 4.08           | 1.08 [1.02, 1.22]   | 1.21 [1.12, 1.33] |
| mixed-1%-16        | 0.19         | 0.56      | 0.72           | 3.82 [3.37, 4.01]   | 1.28 [1.21, 1.37] |
| mixed-1%-64        | 0.24         | 0.95      | 1.92           | 7.77 [7.29, 8.44]   | 2.01 [1.82, 2.10] |
| mixed-1%-256       | 0.59         | 1.02      | 2.15           | 3.75 [3.47, 4.13]   | 2.16 [2.03, 2.30] |
| mixed-1%-4096      | 0.95         | 1.15      | 2.48           | 2.64 [2.44, 2.81]   | 2.14 [1.89, 2.40] |
| mixed-1%-65536     | 0.99         | 1.16      | 2.55           | 2.57 [2.10, 2.96]   | 2.22 [1.93, 2.33] |
| mixed-1%-1048576   | 0.97         | 1.14      | 2.43           | 2.52 [2.40, 2.90]   | 2.16 [1.93, 2.62] |
| mixed-5%-16        | 0.15         | 0.31      | 0.44           | 2.80 [2.64, 3.10]   | 1.39 [1.27, 1.46] |
| mixed-5%-64        | 0.19         | 0.35      | 0.75           | 3.93 [3.60, 4.16]   | 2.14 [2.02, 2.39] |
| mixed-5%-256       | 0.27         | 0.35      | 0.88           | 3.31 [3.10, 3.54]   | 2.54 [2.44, 2.67] |
| mixed-5%-4096      | 0.29         | 0.36      | 0.97           | 3.35 [2.93, 3.56]   | 2.75 [2.53, 3.03] |
| mixed-5%-65536     | 0.30         | 0.36      | 0.99           | 3.30 [2.84, 3.53]   | 2.74 [2.69, 2.96] |
| mixed-5%-1048576   | 0.30         | 0.36      | 0.97           | 3.15 [2.99, 3.67]   | 2.69 [2.45, 2.86] |
| ascii-0%-16        | 1.39         | 2.28      | 3.05           | 2.18 [1.98, 2.40]   | 1.30 [1.21, 1.53] |
| ascii-0%-64        | 7.86         | 6.84      | 8.31           | 1.06 [0.87, 1.39]   | 1.20 [1.12, 1.40] |
| ascii-0%-256       | 17.26        | 17.13     | 20.41          | 1.18 [1.02, 1.36]   | 1.20 [1.03, 1.27] |
| ascii-0%-4096      | 26.40        | 25.17     | 25.80          | 0.99 [0.87, 1.07]   | 1.01 [0.95, 1.09] |
| ascii-0%-65536     | 11.95        | 12.01     | 12.15          | 1.05 [0.98, 1.13]   | 1.05 [0.95, 1.21] |
| ascii-0%-1048576   | 5.73         | 5.79      | 5.79           | 1.01 [0.92, 1.11]   | 1.01 [0.92, 1.10] |
| ascii-0.1%-16      | 1.20         | 1.89      | 2.40           | 1.97 [1.84, 2.36]   | 1.27 [1.13, 1.53] |
| ascii-0.1%-64      | 4.35         | 4.82      | 6.07           | 1.40 [1.20, 1.61]   | 1.28 [1.07, 1.37] |
| ascii-0.1%-256     | 6.14         | 7.84      | 12.74          | 2.08 [1.91, 2.27]   | 1.61 [1.37, 1.77] |
| ascii-0.1%-4096    | 7.88         | 10.50     | 16.02          | 2.05 [1.39, 2.30]   | 1.51 [1.14, 1.68] |
| ascii-0.1%-65536   | 7.13         | 5.44      | 6.17           | 0.87 [0.76, 0.90]   | 1.14 [1.07, 1.28] |
| ascii-0.1%-1048576 | 4.61         | 3.43      | 3.59           | 0.77 [0.74, 0.81]   | 1.04 [0.94, 1.17] |
| ascii-1%-16        | 0.65         | 0.95      | 1.15           | 1.79 [1.52, 2.07]   | 1.22 [1.09, 1.46] |
| ascii-1%-64        | 0.88         | 1.19      | 1.54           | 1.73 [1.56, 1.93]   | 1.30 [1.19, 1.42] |
| ascii-1%-256       | 0.90         | 1.31      | 1.88           | 2.06 [1.89, 2.45]   | 1.45 [1.34, 1.51] |
| ascii-1%-4096      | 1.05         | 1.48      | 2.35           | 2.20 [2.00, 2.71]   | 1.59 [1.44, 1.88] |
| ascii-1%-65536     | 1.05         | 1.50      | 2.25           | 2.16 [2.05, 2.49]   | 1.50 [1.42, 1.76] |
| ascii-1%-1048576   | 1.03         | 1.43      | 2.34           | 2.29 [1.96, 2.86]   | 1.55 [1.44, 2.08] |
| ascii-5%-16        | 0.21         | 0.32      | 0.35           | 1.57 [1.32, 1.82]   | 1.12 [1.01, 1.28] |
| ascii-5%-64        | 0.25         | 0.37      | 0.46           | 1.85 [1.61, 1.94]   | 1.19 [1.09, 1.33] |
| ascii-5%-256       | 0.28         | 0.40      | 0.59           | 1.99 [1.96, 2.28]   | 1.43 [1.32, 1.58] |
| ascii-5%-4096      | 0.31         | 0.43      | 0.64           | 2.06 [1.82, 2.27]   | 1.48 [1.26, 1.74] |
| ascii-5%-65536     | 0.31         | 0.40      | 0.65           | 2.05 [1.71, 2.33]   | 1.53 [1.44, 1.67] |
| ascii-5%-1048576   | 0.31         | 0.43      | 0.66           | 2.12 [1.95, 2.26]   | 1.54 [1.48, 1.72] |

## x86 AVX2

[raw/x86-avx2.txt](replacing-20261105/raw/x86-avx2.txt), `x86_64_v3` without dispatch, simdutf `haswell`.

| row                | simdutf GB/s | loop GB/s | replacing GB/s | vs simdutf        | vs loop           |
| ------------------ | ------------ | --------- | -------------- | ----------------- | ----------------- |
| mixed-0%-16        | 0.16         | 0.19      | 0.21           | 1.29 [1.15, 1.38] | 1.08 [0.94, 1.12] |
| mixed-0%-64        | 0.22         | 0.48      | 0.50           | 2.26 [1.94, 2.61] | 1.03 [0.89, 1.20] |
| mixed-0%-256       | 0.59         | 1.19      | 1.22           | 2.08 [1.96, 2.17] | 1.02 [0.90, 1.08] |
| mixed-0%-4096      | 1.00         | 2.28      | 2.28           | 2.29 [2.20, 2.49] | 1.01 [0.83, 1.04] |
| mixed-0%-65536     | 1.06         | 2.29      | 2.31           | 2.18 [2.14, 2.32] | 1.00 [0.89, 1.13] |
| mixed-0%-1048576   | 1.03         | 2.40      | 2.26           | 2.24 [2.16, 2.37] | 0.95 [0.92, 1.04] |
| mixed-0.1%-16      | 0.16         | 0.19      | 0.21           | 1.35 [1.20, 1.60] | 1.12 [1.04, 1.22] |
| mixed-0.1%-64      | 0.22         | 0.46      | 0.48           | 2.16 [2.00, 2.21] | 1.03 [0.95, 1.09] |
| mixed-0.1%-256     | 0.52         | 1.15      | 1.16           | 2.13 [2.04, 2.49] | 1.01 [0.92, 1.15] |
| mixed-0.1%-4096    | 0.94         | 2.14      | 2.27           | 2.44 [2.27, 2.66] | 1.06 [1.01, 1.19] |
| mixed-0.1%-65536   | 0.96         | 2.22      | 2.34           | 2.42 [2.22, 2.73] | 1.05 [0.94, 1.19] |
| mixed-0.1%-1048576 | 0.92         | 2.18      | 2.30           | 2.43 [2.14, 2.91] | 1.04 [0.99, 1.25] |
| mixed-1%-16        | 0.16         | 0.20      | 0.22           | 1.40 [1.26, 1.70] | 1.09 [1.00, 1.24] |
| mixed-1%-64        | 0.21         | 0.42      | 0.44           | 2.12 [1.90, 2.26] | 1.03 [0.89, 1.14] |
| mixed-1%-256       | 0.39         | 0.81      | 0.98           | 2.51 [2.38, 2.58] | 1.21 [1.15, 1.29] |
| mixed-1%-4096      | 0.54         | 1.13      | 1.55           | 2.88 [2.63, 3.18] | 1.37 [1.33, 1.61] |
| mixed-1%-65536     | 0.56         | 1.16      | 1.61           | 2.86 [2.47, 3.01] | 1.38 [1.27, 1.50] |
| mixed-1%-1048576   | 0.56         | 1.16      | 1.58           | 2.77 [2.59, 2.90] | 1.38 [1.18, 1.44] |
| mixed-5%-16        | 0.14         | 0.19      | 0.22           | 1.52 [1.39, 1.63] | 1.15 [1.04, 1.24] |
| mixed-5%-64        | 0.17         | 0.31      | 0.33           | 1.95 [1.71, 2.27] | 1.02 [0.97, 1.17] |
| mixed-5%-256       | 0.21         | 0.39      | 0.60           | 2.87 [2.58, 3.37] | 1.56 [1.45, 1.75] |
| mixed-5%-4096      | 0.23         | 0.43      | 0.82           | 3.81 [3.26, 4.10] | 1.95 [1.58, 2.13] |
| mixed-5%-65536     | 0.23         | 0.44      | 0.83           | 3.59 [3.16, 3.81] | 1.88 [1.81, 2.06] |
| mixed-5%-1048576   | 0.25         | 0.44      | 0.82           | 3.28 [3.07, 3.65] | 1.90 [1.83, 2.04] |
| ascii-0%-16        | 1.08         | 2.23      | 2.74           | 2.45 [2.31, 2.58] | 1.23 [1.03, 1.37] |
| ascii-0%-64        | 2.97         | 7.64      | 10.24          | 3.39 [3.11, 3.89] | 1.34 [1.24, 1.48] |
| ascii-0%-256       | 8.85         | 16.93     | 18.45          | 2.09 [1.98, 2.33] | 1.10 [0.94, 1.19] |
| ascii-0%-4096      | 18.17        | 22.86     | 23.28          | 1.29 [1.21, 1.43] | 1.01 [0.90, 1.18] |
| ascii-0%-65536     | 11.85        | 11.92     | 11.96          | 1.00 [0.92, 1.07] | 1.00 [0.96, 1.08] |
| ascii-0%-1048576   | 5.76         | 5.83      | 6.00           | 1.02 [0.94, 1.10] | 1.02 [0.93, 1.16] |
| ascii-0.1%-16      | 0.91         | 1.81      | 2.34           | 2.57 [2.33, 2.75] | 1.29 [1.10, 1.39] |
| ascii-0.1%-64      | 2.40         | 5.24      | 6.86           | 2.85 [2.54, 3.06] | 1.31 [1.15, 1.54] |
| ascii-0.1%-256     | 4.64         | 9.39      | 10.54          | 2.28 [2.19, 2.60] | 1.11 [1.04, 1.29] |
| ascii-0.1%-4096    | 6.40         | 12.96     | 12.09          | 1.87 [1.70, 2.10] | 0.92 [0.83, 0.98] |
| ascii-0.1%-65536   | 6.02         | 9.33      | 8.90           | 1.48 [1.34, 1.63] | 0.96 [0.86, 1.04] |
| ascii-0.1%-1048576 | 4.40         | 5.15      | 5.09           | 1.17 [1.12, 1.23] | 1.00 [0.93, 1.14] |
| ascii-1%-16        | 0.59         | 1.02      | 1.27           | 2.13 [1.90, 2.41] | 1.24 [1.09, 1.30] |
| ascii-1%-64        | 0.85         | 1.30      | 1.55           | 1.86 [1.56, 2.03] | 1.21 [1.08, 1.30] |
| ascii-1%-256       | 0.84         | 1.32      | 1.51           | 1.81 [1.67, 2.05] | 1.15 [1.05, 1.24] |
| ascii-1%-4096      | 0.92         | 1.46      | 1.69           | 1.80 [1.53, 2.04] | 1.12 [1.04, 1.19] |
| ascii-1%-65536     | 0.95         | 1.52      | 1.70           | 1.80 [1.54, 1.89] | 1.10 [1.00, 1.28] |
| ascii-1%-1048576   | 0.96         | 1.45      | 1.66           | 1.79 [1.63, 2.04] | 1.14 [1.04, 1.21] |
| ascii-5%-16        | 0.24         | 0.37      | 0.45           | 1.88 [1.82, 1.99] | 1.28 [1.18, 1.37] |
| ascii-5%-64        | 0.25         | 0.42      | 0.53           | 2.08 [1.99, 2.40] | 1.31 [1.19, 1.46] |
| ascii-5%-256       | 0.24         | 0.41      | 0.52           | 2.16 [1.82, 2.49] | 1.25 [1.17, 1.41] |
| ascii-5%-4096      | 0.28         | 0.43      | 0.55           | 1.96 [1.79, 2.09] | 1.26 [1.21, 1.39] |
| ascii-5%-65536     | 0.29         | 0.44      | 0.55           | 1.92 [1.78, 2.10] | 1.27 [1.17, 1.35] |
| ascii-5%-1048576   | 0.29         | 0.43      | 0.54           | 1.90 [1.66, 2.21] | 1.24 [1.17, 1.47] |

## x86 SSE

[raw/x86-sse.txt](replacing-20261105/raw/x86-sse.txt), `x86_64_v2` without dispatch, simdutf `westmere`.

| row                | simdutf GB/s | loop GB/s | replacing GB/s | vs simdutf        | vs loop           |
| ------------------ | ------------ | --------- | -------------- | ----------------- | ----------------- |
| mixed-0%-16        | 0.16         | 0.19      | 0.21           | 1.31 [1.17, 1.43] | 1.12 [0.99, 1.17] |
| mixed-0%-64        | 0.23         | 0.47      | 0.50           | 2.22 [2.02, 2.42] | 1.06 [0.95, 1.17] |
| mixed-0%-256       | 0.58         | 1.03      | 1.08           | 1.88 [1.68, 2.00] | 1.04 [0.86, 1.19] |
| mixed-0%-4096      | 0.99         | 1.65      | 1.68           | 1.72 [1.55, 1.87] | 1.01 [0.94, 1.10] |
| mixed-0%-65536     | 1.02         | 1.92      | 1.82           | 1.78 [1.62, 1.95] | 0.95 [0.92, 1.09] |
| mixed-0%-1048576   | 1.01         | 1.86      | 1.82           | 1.78 [1.59, 1.94] | 0.93 [0.84, 1.05] |
| mixed-0.1%-16      | 0.15         | 0.19      | 0.21           | 1.35 [1.01, 1.49] | 1.09 [1.00, 1.21] |
| mixed-0.1%-64      | 0.22         | 0.46      | 0.48           | 2.15 [2.00, 2.32] | 1.03 [0.90, 1.11] |
| mixed-0.1%-256     | 0.55         | 0.99      | 1.05           | 1.95 [1.73, 2.27] | 1.09 [0.93, 1.20] |
| mixed-0.1%-4096    | 0.88         | 1.58      | 1.65           | 1.83 [1.70, 1.92] | 1.02 [0.88, 1.11] |
| mixed-0.1%-65536   | 0.92         | 1.77      | 1.77           | 1.90 [1.82, 2.17] | 1.01 [0.96, 1.19] |
| mixed-0.1%-1048576 | 0.92         | 1.71      | 1.73           | 1.87 [1.72, 2.02] | 1.02 [0.92, 1.19] |
| mixed-1%-16        | 0.16         | 0.20      | 0.23           | 1.37 [1.20, 1.46] | 1.12 [0.97, 1.25] |
| mixed-1%-64        | 0.21         | 0.42      | 0.44           | 2.07 [1.96, 2.26] | 1.05 [0.99, 1.17] |
| mixed-1%-256       | 0.38         | 0.75      | 0.88           | 2.24 [2.04, 2.53] | 1.16 [1.06, 1.25] |
| mixed-1%-4096      | 0.53         | 0.98      | 1.22           | 2.32 [1.95, 2.47] | 1.27 [1.13, 1.43] |
| mixed-1%-65536     | 0.56         | 1.02      | 1.32           | 2.35 [2.09, 2.48] | 1.28 [1.15, 1.36] |
| mixed-1%-1048576   | 0.55         | 1.00      | 1.29           | 2.40 [2.10, 2.70] | 1.30 [1.20, 1.46] |
| mixed-5%-16        | 0.15         | 0.19      | 0.22           | 1.49 [1.22, 1.62] | 1.16 [0.94, 1.27] |
| mixed-5%-64        | 0.17         | 0.31      | 0.32           | 1.90 [1.69, 2.02] | 1.05 [0.92, 1.16] |
| mixed-5%-256       | 0.20         | 0.36      | 0.55           | 2.69 [2.36, 3.09] | 1.51 [1.30, 1.59] |
| mixed-5%-4096      | 0.23         | 0.40      | 0.69           | 3.08 [3.03, 3.38] | 1.72 [1.60, 1.84] |
| mixed-5%-65536     | 0.23         | 0.41      | 0.72           | 3.09 [2.75, 3.46] | 1.77 [1.55, 1.84] |
| mixed-5%-1048576   | 0.24         | 0.41      | 0.71           | 2.90 [2.62, 3.11] | 1.73 [1.59, 1.90] |
| ascii-0%-16        | 1.07         | 2.06      | 2.83           | 2.70 [2.53, 3.09] | 1.39 [1.27, 1.47] |
| ascii-0%-64        | 2.98         | 6.64      | 8.36           | 2.81 [2.51, 3.07] | 1.26 [1.22, 1.36] |
| ascii-0%-256       | 7.67         | 11.93     | 12.92          | 1.73 [1.50, 1.83] | 1.09 [0.90, 1.19] |
| ascii-0%-4096      | 14.23        | 14.36     | 14.53          | 1.01 [0.87, 1.07] | 0.99 [0.87, 1.07] |
| ascii-0%-65536     | 10.90        | 11.01     | 10.23          | 0.99 [0.77, 1.07] | 0.95 [0.83, 1.07] |
| ascii-0%-1048576   | 5.67         | 5.64      | 5.63           | 1.02 [0.92, 1.05] | 0.99 [0.92, 1.12] |
| ascii-0.1%-16      | 0.90         | 1.81      | 2.38           | 2.64 [2.45, 2.76] | 1.34 [1.16, 1.46] |
| ascii-0.1%-64      | 2.40         | 4.74      | 5.96           | 2.51 [2.33, 2.87] | 1.23 [1.17, 1.45] |
| ascii-0.1%-256     | 4.21         | 7.35      | 7.69           | 1.82 [1.60, 1.89] | 1.06 [0.95, 1.10] |
| ascii-0.1%-4096    | 5.62         | 9.65      | 8.10           | 1.47 [1.32, 1.62] | 0.87 [0.80, 1.24] |
| ascii-0.1%-65536   | 5.15         | 7.74      | 7.27           | 1.42 [1.30, 1.52] | 0.96 [0.85, 1.10] |
| ascii-0.1%-1048576 | 4.09         | 5.10      | 5.23           | 1.22 [1.11, 1.34] | 1.03 [0.93, 1.06] |
| ascii-1%-16        | 0.57         | 1.00      | 1.28           | 2.20 [1.98, 2.38] | 1.29 [1.15, 1.43] |
| ascii-1%-64        | 0.82         | 1.27      | 1.50           | 1.79 [1.65, 1.93] | 1.18 [1.09, 1.26] |
| ascii-1%-256       | 0.83         | 1.23      | 1.34           | 1.65 [1.52, 1.77] | 1.09 [1.01, 1.17] |
| ascii-1%-4096      | 0.92         | 1.37      | 1.47           | 1.66 [1.46, 1.77] | 1.08 [1.00, 1.24] |
| ascii-1%-65536     | 0.93         | 1.39      | 1.51           | 1.62 [1.53, 1.89] | 1.09 [1.03, 1.19] |
| ascii-1%-1048576   | 0.93         | 1.33      | 1.50           | 1.66 [1.43, 1.77] | 1.12 [1.07, 1.18] |
| ascii-5%-16        | 0.23         | 0.35      | 0.46           | 1.98 [1.80, 2.16] | 1.29 [1.11, 1.43] |
| ascii-5%-64        | 0.25         | 0.41      | 0.52           | 2.10 [1.79, 2.30] | 1.27 [1.18, 1.55] |
| ascii-5%-256       | 0.25         | 0.38      | 0.47           | 1.90 [1.70, 2.04] | 1.24 [1.12, 1.41] |
| ascii-5%-4096      | 0.27         | 0.38      | 0.51           | 1.88 [1.76, 2.05] | 1.32 [1.14, 1.45] |
| ascii-5%-65536     | 0.28         | 0.39      | 0.49           | 1.78 [1.56, 1.89] | 1.30 [1.21, 1.43] |
| ascii-5%-1048576   | 0.28         | 0.38      | 0.51           | 1.80 [1.61, 1.88] | 1.31 [1.18, 1.41] |
