# UTF-8 to UTF-32 and base64 decoding on Apple Silicon, 2026-11-01

Ghostty is evaluating utf as a replacement for simdutf, and on Apple Silicon, its main platform, three of the operations it calls were behind simdutf's `arm64` kernel at `1f69e90` (`zig-0.17`): UTF-8 to UTF-32 on CJK text from 4 KiB (0.55 of simdutf), on emoji (0.87–0.91 at 64 B and from 4 KiB), and base64 decoding (0.72 at 64 characters, 0.90–0.94 from 4 KiB). This is the work that brings all three to or above simdutf, measured as Ghostty calls them. It was measured on `1f69e90` and as `57f0312`; `zig-0.17` was then rebased onto `e911921` (x86 dispatch linking, no aarch64 change), where `1f69e90` became `eb10f9c`, and this series applies unchanged.

- Machine: Apple M4 Max (MacBook Pro, `Mac16,6`), macOS 26.6.2, on AC power. Zig 0.17.0 ReleaseFast for `aarch64-macos` with the native CPU (`apple_m4`); simdutf 9.0.0, the copy Ghostty vendors (`kernel arm64`), compiled by `zig c++` in the same build.
- Harness: [harness/](neon-apple-20261101/harness/), one process holding simdutf and three builds of utf (`base`, `new`, `alt`), each a shim of Ghostty's two call sites: `src/simd/vt.cpp`'s `DecodeUTF8` (convert, and on an error count the valid prefix, emit U+FFFD, skip the maximal subpart, and go on), whose output buffer holds one code point per input byte, and `src/simd/base64.cpp`'s decode into `maxDecodedLen` bytes. Each round times every row on every arm back to back, rotating the order by row and round; round 0 sizes the loops. macOS cannot pin a thread to a core: the process runs at user-interactive QoS, and only one benchmark ran at a time. `ratio.py` gives each row's median over rounds of the per-round ratio simdutf ÷ arm (above 1: the arm is faster), with the range; the per-round pairing cancels most of the drift a laptop has, which plain benchstat shows as ±3–10%. To rebuild it, put Ghostty's `simdutf.cpp` and `simdutf.h` beside it and utf checkouts at the paths `build.zig.zon` names.
- Inputs: the corpora of the measuring thread, repeated to 128 KiB and cut on a character boundary at 16, 64, 256, 4096, and 65536 bytes: `box` (box drawing and blocks), `latin` (French and German), `cjk` (Chinese, Japanese, and Korean with a space every 37 characters), `cjk3` (the same without the space), `korean`, `japanese` (with some ASCII), `cyrillic`, and `emoji` (four-byte emoji, a ✅, and ASCII spaces); `ascii-1` and `ascii-8`; base64 of random bytes, padded, at 64 to 4 MiB characters. The UTF-16 rows convert the same text with `utf8ToUtf16le`; the vendored simdutf is built without UTF-16, so those rows compare with `base`.
- Correctness: `ab test`, 300 000 random inputs per build through the `new` arm against simdutf, for each operation (valid text, runs of one length, and corruption), 0 mismatches at every step; the package's tests in Debug, ReleaseSafe, and ReleaseFast natively and with `-Dcpu=generic` (the NEON paths other cores take).

## Final (12 rounds, 20 ms samples)

`base` is `1f69e90`, `new` this series, `alt` this series with the Apple-only paths turned off (what other NEON cores run). simdutf ÷ arm, and GB/s:

| row                    | simdutf GB/s | base | new  | new GB/s | alt  |
| ---------------------- | ------------ | ---- | ---- | -------- | ---- |
| UTF-32 `cjk-15`        | 0.87         | 1.52 | 1.43 | 1.22     | 1.44 |
| UTF-32 `cjk-63`        | 1.51         | 2.42 | 2.47 | 3.69     | 2.43 |
| UTF-32 `cjk-254`       | 3.97         | 1.20 | 1.82 | 7.29     | 1.50 |
| UTF-32 `cjk-4096`      | 7.47         | 0.55 | 1.07 | 7.98     | 0.79 |
| UTF-32 `cjk-65535`     | 7.90         | 0.51 | 1.00 | 7.91     | 0.74 |
| UTF-32 `cyrillic-255`  | 3.02         | 0.97 | 1.72 | 5.20     | 1.40 |
| UTF-32 `cyrillic-4095` | 3.28         | 0.96 | 1.60 | 5.24     | 1.62 |
| UTF-32 `emoji-16`      | 1.13         | 2.05 | 1.86 | 2.08     | 1.91 |
| UTF-32 `emoji-64`      | 1.91         | 0.90 | 1.93 | 3.70     | 0.90 |
| UTF-32 `emoji-254`     | 1.96         | 1.05 | 1.97 | 3.85     | 1.05 |
| UTF-32 `emoji-4095`    | 2.15         | 0.90 | 1.77 | 3.79     | 0.91 |
| UTF-32 `emoji-65536`   | 2.12         | 0.89 | 1.82 | 3.85     | 0.89 |
| base64 64              | 6.98         | 0.74 | 1.90 | 13.22    | 1.90 |
| base64 256             | 13.88        | 0.85 | 1.37 | 19.08    | 1.37 |
| base64 4096            | 18.61        | 0.94 | 1.05 | 19.58    | 1.05 |
| base64 262144          | 19.20        | 0.94 | 1.02 | 19.51    | 1.02 |
| base64 4194304         | 19.18        | 0.94 | 1.01 | 19.43    | 1.01 |

Before the move to Zig 0.17, `origin/main` built with Zig 0.16 read `cjk-4096` 0.80, `cjk-65535` 0.74, emoji 0.91–1.09 from 64 bytes, base64 0.72–0.97, and `box-14` 1.61 ([zig016-main.txt](neon-apple-20261101/steps/zig016-main.txt), a separate run, each build against the simdutf it compiled).

`cjk-65535` is level: 1.00, range 0.97–1.01 over the 12 rounds (benchstat: 8.29 µs both, p=0.80). Every other UTF-8 to UTF-32 row from 63 bytes is 1.07–3.27 of simdutf (`latin` 2.36–2.50, `box` 1.83–3.23, `korean` 1.70–3.27, `cyrillic` 1.60–2.82, `japanese` 1.33–2.41, `cjk3` 1.12–2.39). UTF-8 to UTF-16 from 254 bytes is 1.32–2.28 of `base` (CJK from 4 KiB 1.96–2.01, emoji 2.10–2.20). Geomean over all 87 rows in time, against simdutf's column (which for UTF-16 is `base`): `base` −9.8%, `new` −36.1%, `alt` −24.8%. Raw output in [final/](neon-apple-20261101/final/) (`benchstat -col /arm`, the ratios, the gzipped run).

Slower than `base`: calls of 1–16 bytes, by 0.7–1 ns (`ascii-1` 2.73 → 3.69 ns, `box-14` 9.9 → 10.8, `cjk-15` 11.3 → 12.3, `emoji-16` 6.9 → 7.7; still 1.16–2.5 of simdutf), and UTF-8 to UTF-16 at 64 bytes, 3–5% (`box-64`, `korean-64`). `alt` has the same costs ([short-no-apple.txt](neon-apple-20261101/steps/short-no-apple.txt)), so they come from step 1, whose register-wide stores and lookups need constants that LLVM loads once at function entry, before the length test, and spills: in Ghostty's decode loop, 25 more instructions before it, 7 of them vector loads and 6 stores to the stack (`alt`: 22, 6, and 3). Memory: no allocation.

## What changed, and what each step measured

Only aarch64 code changed: the x86-64 assembly of every `convert`, `base64`, `validate`, and `length` function at `baseline`, `x86_64_v2`, `x86_64_v3`, `x86_64_v4`, and `x86_64_v4` with VBMI and VBMI2 (dispatch off, so each level's kernels are in the object) is identical to `1f69e90`'s after renumbering anonymous symbols (`zig build -Dtarget=x86_64-linux`, ReleaseFast, a table of every non-generic public function). So x86 was not benchmarked.

1. **Register-wide NEON stores and lookups, without Zig 0.17's array casts** ([zig017-base.txt](neon-apple-20261101/steps/zig017-base.txt), [zig016-main.txt](neon-apple-20261101/steps/zig016-main.txt), [zig017-lanes.txt](neon-apple-20261101/steps/zig017-lanes.txt)). UTF-8 to UTF-32 at 4 KiB was 1.6× slower under Zig 0.17 than `origin/main` under Zig 0.16 on two-byte and box text (`box` 1.12 vs 1.82 of simdutf, `latin` 1.39 vs 2.39, `cyrillic` 0.94 vs 1.64) and CJK 0.55 vs 0.80. [bitcast-sweep](bitcast-sweep-20261101.md) found no loop left on NEON in ReleaseFast, and there is none, but `storeWide` (a `@bitCast` of `[n]@Vector(16, T)` to `[16 * n]T`), `storeWideUnits`, and `simd.lookup16` (through `[n]u8`) became a `umov` or `mov.b` per lane on the decoder's paths. `storeWide` now stores each register, `storeWideUnits` splits with `simd.split`, and NEON's `lookup16` is `split`, a `tbl` per register, and `join`. After: `box` 1.78, `latin` 2.29, `cyrillic` 1.58, `cjk` 0.79 (957 → 668 ns at 4 KiB), level with Zig 0.16; 1–16-byte calls 0.5–1 ns slower, as above. `simd.split` gets a larger comptime branch quota for the 64-lane splits.
2. **Base64: the last block stored exactly** ([base64-exact-store.txt](neon-apple-20261101/steps/base64-exact-store.txt)). NEON's clean blocks are packed with `st3`, which writes 48 bytes and no more, but the loop still demanded room for the 4 bytes of slack the vector stores of other kernels write past them. With `dst` of `maxDecodedLen` bytes, as Ghostty passes, the last block never had it and went to `decodeStaged`, out of line, and a 64-character input was nothing but that block. `packClean` takes no slack on NEON (`clean_slack`): 64 characters 0.73 → 1.84 of simdutf, 256 0.89 → 1.35, 4 KiB 0.98 → 1.02.
3. **Base64: simdutf's classifier for clean blocks** ([base64-clz.txt](neon-apple-20261101/steps/base64-clz.txt)). `classify` makes the roll slot with a compare and an add (the high nibble, moved for the one character whose offset differs); simdutf's `arm64` kernel indexes the 5-bit `c >> 3` and the low nibble, so each class bit is a rectangle of the alphabet, and the class's leading zeros pick the offset: 8 operations a vector where we had 9, and the check is `class <= 1` (none, or whitespace), which LLVM reduces with `umin`. `classifyClean` uses it, with simdutf's tables for both alphabets, checked at comptime against every byte. 4 KiB 1.02 → 1.09, 256 KiB 1.00 → 1.05, 4 MiB 0.99 → 1.045 (this run; the final run reads 1.01–1.05). The ordered `classify`, which also gives whitespace and positions, is unchanged.
4. **UTF-8 in 64-byte blocks on Apple cores.** Apple's cores differ from Neoverse N2, where the earlier NEON work was measured ([neon-convert-20261101.md](neon-convert-20261101.md)): `utf8DecodeBlock` decodes emoji text at 1.75 of simdutf here where 12-byte windows reached 0.94 (on N2 windows won), and on CJK's blocks with a space in them windows beat it. Zig's default CPU for `aarch64-macos` is `apple_m1`, so a release build for macOS gets these paths; `convert.apple` gates them on the CPU model's `apple_` prefix, and other NEON cores keep the code from step 1. `utf8BlocksApple`, inline in `utf8ToUnits`, finds each non-ASCII block's end first (scalar loads: a next block's load that waited on a count from the block's lane mask, as a data-dependent advance does, cost 0.64×), then:
   - **Up to eight ASCII bytes and three-byte characters to the block's end, 32 bytes or more** (Chinese and Japanese between spaces): `utf8ThreeRun`, three groups of eight characters, each from two loads, two two-register `tbl`s, and two `sli`s in 16-bit lanes, checked on the decoded values (lead `1110____`, not overlong, not a surrogate) where block validation takes twice the operations; the shape comes from the lead mask.
   - **A run of at least eight such characters, then anything** (the block with CJK's space in it): validated window by window and decoded in 12-byte windows, four three-byte characters with `sli` and checked on their values ([window-checks.txt](neon-apple-20261101/steps/window-checks.txt): `cjk-4096` 1.02 → 1.06, `cjk-65535` 0.97 → 0.99, where the whole block had been validated first).
   - **Otherwise** validation, sixteen four-byte characters, or `utf8DecodeBlock`, with four-byte characters when the block has a byte from 0xF0.
   - **The last 64–79 bytes** as a block too, without the runs, which read past it, when the output has room for the eight units `utf8DecodeBlock` writes past its own ([last-block.txt](neon-apple-20261101/steps/last-block.txt)): those inputs had gone to windows and the scalar tail. `emoji-64` 0.90 → 2.05, `latin-64` 0.94 → 2.60, `cyrillic-64` 1.48 → 2.81, `box-64` 2.09 → 3.13, `emoji-254` 1.47 → 1.95.

   Against `alt` in the final run: `cjk-4096` 0.79 → 1.07, `cjk-65535` 0.74 → 1.00, `cjk-254` 1.50 → 1.82, emoji from 64 bytes 0.89–1.05 → 1.77–1.97, `japanese` 4 KiB 1.19 → 1.33, UTF-16 CJK 4 KiB 1.44 → 1.96 of `base`; `box`, `latin`, `korean`, and `cyrillic` from 4 KiB within 2% (0.98–1.03 of `alt`, ranges overlapping).

The package's tests reach both new checks (an error in the run decoder and in the window path; seen by making each failure branch panic); a `cjk_text` mix, three-byte runs with an ASCII character in 32 on average, puts every error kind at every position in that text too.

## Tried and dropped

Measured in this work, on the same harness; the raw output of the ones listed with a file is in [steps/](neon-apple-20261101/steps/):

- **Windows for every non-ASCII block**, as simdutf decodes: `box`, `latin`, `korean`, and `cyrillic` lost.
- **Advancing by a count from the lane mask**, in a segment loop or by decoding a prefix run and starting the next block where it ends: 0.64× (21 three-byte characters a block) and `cjk` 0.95; the next block's load waits on the vector work.
- **Branchless lead length in `utf8BlockEnd`**: slower; the branches break the dependency chain.
- **The block loop, or everything from 16 bytes, out of line** (`never_inline`): 16–64-byte rows 10–25% slower.
- **Two runs split by ASCII, decoded as runs**, three groups each (0.93 of the windows; 1.02 without checks), and two groups each for runs up to 16 ([dropped-two-runs.txt](neon-apple-20261101/steps/dropped-two-runs.txt): `cjk-4096` 1.05 → 0.97).
- **Windows for runs shorter than eight** when the block is three-byte characters and at most two ASCII ([dropped-windows-short-runs.txt](neon-apple-20261101/steps/dropped-windows-short-runs.txt)): `cjk-4096` level, `cjk-65535` 0.96 → 0.92.
- **Finishing the window path's block**, the last one to three three-byte characters as four ([dropped-finish-windows.txt](neon-apple-20261101/steps/dropped-finish-windows.txt)): `cjk-4096` 1.05 → 0.99; the next blocks' shapes move.
- **The last 16–63 bytes as a block**, the input's last 64 with the bytes before them made NULs ([dropped-overlapped-tail.txt](neon-apple-20261101/steps/dropped-overlapped-tail.txt)): within ±5% at 254 B to 4 KiB, both ways.
- **Storing only eight units of the ASCII before a run**, or only when there is any: `cjk3` slower.

Layout moves rows whose code did not change by up to 8% between builds (`cjk3-4095` read 1.17 and 1.28 in builds that differ only in the window path, which `cjk3` never takes), so each step above was judged on the rows it changes, against the build before it in the same run.

## Left

- `cjk-65535` is level with simdutf (1.00), and 4 KiB 1.07: the blocks that hold CJK's space take the window path, which by `cjk3`'s rate (no spaces, 1.12–1.21) costs about 1.6× a run block.
- Calls of 1–16 bytes are 0.7–1 ns slower than at `1f69e90`, from step 1's constants at function entry (above).
- Ghostty end to end at `57f0312` (same Mac, hyperfine, two passes, simdutf ÷ utf): emoji 1.11–1.13 (`1f69e90`: 0.98–0.99), Kitty graphics 1.02–1.03 (1.00), CJK 1.01–1.06, mixed 1.04–1.06, invalid 1.08–1.09, TUI 1.07, ASCII level; none slower than `1f69e90`. Its harness found one regression against `1f69e90`: invalid UTF-8 at 256 B–4 KiB 11–15% slower (256 B 332 → 370 ns, 4 KiB 5.0 → 5.8 µs), still 1.26–1.38 of simdutf; not yet explained (each error restarts the call, and the Apple block path does more work before a bad block breaks to windows).
- Not measured on Neoverse N2 or another non-Apple core: steps 1–3 apply to every NEON core (`bench.yml` on GitHub's aarch64 runner would show them), step 4 only to Apple's. Not measured end to end in Ghostty.
