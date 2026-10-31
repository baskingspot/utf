# Plan

simdutf's job as a Zig package: validate and transcode UTF-8, UTF-16 (LE and
BE), UTF-32, and Latin-1, and encode and decode base64, with SIMD, no C, and
no allocation, at simdutf's speed or better. This file is the API, the
algorithms, the decisions to measure, and who owns what. Update it when a
decision lands.

## API

Modeled on simdutf's, in Zig's terms. Callers own every buffer; nothing
allocates. UTF-16 is `[]const u16`/`[]u16` and LE/BE names the byte order in
memory, as simdutf's `char16_t` functions do. UTF-32 is `[]const u32`.

- `validate`: `utf8(bytes) bool` and `utf8WithErrors(bytes) Result`; the same
  pair for `ascii`, `utf16le`, `utf16be`, `utf32`.
- `convert`, for each pair of UTF-8, UTF-16LE, UTF-16BE, UTF-32, and Latin-1:
  a checked form (`utf8ToUtf16le(src, dst) Result`: validates while it
  converts, and reports the error kind and position) and a valid form
  (`validUtf8ToUtf16le(src, dst) usize`: assumes valid input, fastest).
- `length`: the output size each conversion needs (`utf16FromUtf8(src)`, and so
  on) and `countUtf8`/`countUtf16le`/`countUtf16be` for code points.
- `base64`: `encode(dst, src, options) usize`, `encodedLen(n, options)`,
  `decode(dst, src, options) Result`, `maxDecodedLen(n)`. Options: alphabet
  (standard, URL-safe), padding on encode, and the last-chunk rule on decode
  (loose, strict, stop before a partial chunk), with ASCII whitespace ignored
  as WHATWG's forgiving-base64 does and simdutf does.
- `Result` and `Error` (`src/result.zig`): simdutf's error kinds and positions,
  so simdutf is a differential oracle.

## Algorithms

From the papers simdutf is built on; implement from the papers and the
standard, not from simdutf's source.

- UTF-8 validation: Keiser and Lemire, "Validating UTF-8 In Less Than One
  Instruction Per Byte" (2021): three nibble lookups classify each byte pair,
  a check for missing and extra continuations, an ASCII fast path that skips
  whole blocks. Errors are found per block; the position comes from rerunning
  the scalar validator from the last good boundary.
- Transcoding: Lemire and Muła, "Transcoding Billions of Unicode Characters
  per Second with SIMD Instructions" (2022): UTF-8 to UTF-16 with shuffle
  tables keyed by the end-of-character mask, UTF-16 to UTF-8 by expanding and
  compressing lanes, ASCII and two-byte fast paths. Shuffle tables are
  generated at comptime.
- Base64: Muła and Lemire, "Faster Base64 Encoding and Decoding Using AVX2
  Instructions" (2018), and "Base64 encoding and decoding at almost the speed
  of a memory copy" (2020) for AVX-512 VBMI. Whitespace-forgiving decode
  compresses out spaces before decoding each block.

## Decisions, and how each gets decided

1. **ISA selection.** Start with comptime selection from `builtin.cpu`:
   AVX-512 (with VBMI/VBMI2 where a path needs them), AVX2, SSE4.2/SSSE3,
   NEON, and a generic `@Vector(16, u8)` path for everything else, chosen per
   function. Zig has no per-function target attribute, so runtime dispatch
   (simdutf's default, which matters for binaries built for a baseline CPU,
   like distribution packages) needs per-ISA objects or a build option.
   **Measure** a baseline x86-64 build against an x86-64-v3 build first, then
   decide whether runtime dispatch is worth its complexity. Base64 found:
   `pshufb`, `pmaddubsw`, and NEON `tbl` come from LLVM intrinsics
   (`extern fn @"llvm.x86.ssse3.pshuf.b.128"`), which only the LLVM backend
   lowers, so x86 Debug builds (the self-hosted backend) get the generic
   kernel and the ISA kernels are tested in ReleaseSafe. Each kernel is a
   comptime parameter, so one test build runs every kernel the CPU has. LLVM
   narrows partly used vector loads and merges overlapping vector stores into
   extra shuffles; volatile loads and stores keep them whole, worth 30–40% on
   the base64 loops ([results](results/base64-20261030.md)).
   Validation's `src/simd.zig` landed: `isa` is `.avx512` with AVX-512BW,
   `.avx2`, `.sse` with SSSE3 (the floor for `pshufb`), `.neon` on aarch64,
   else `.generic`, so x86-64 baseline is generic. Measured for UTF-8 validation
   ([validate-20261031.md](results/validate-20261031.md)): non-ASCII text at
   21 GiB/s on AVX-512, 14 on AVX2, 9 on SSE, and 1.3 on baseline, where the
   scalar validator runs past the ASCII prefix; ASCII is 80–130 GiB/s on all
   four. **Decided: runtime dispatch on x86-64**
   ([dispatch-20261031.md](results/dispatch-20261031.md)). build.zig compiles
   the package once more per tier above the target's own ISA, as objects for
   `x86_64_v2` (`.sse`), `x86_64_v3` (`.avx2`), and `x86_64_v4` plus VBMI,
   VBMI2, BITALG, VPOPCNTDQ, and GFNI (`.avx512`), and links them into the
   `utf` module, so `b.dependency("utf", ...).module("utf")` carries them.
   `src/dispatch.zig` picks the best tier once with `cpuid` and XCR0. It is
   on by default for a generic x86-64 CPU (baseline, `x86_64_v2`,
   `x86_64_v3`, a cross target with no CPU) and off for a native or named
   one, where `simd.isa` chooses at comptime as before; `-Ddispatch` (or
   `.dispatch` in the dependency's arguments) overrides; aarch64 is always
   comptime. A baseline build runs the AVX-512 kernels within 0–3.4% of a
   build for the CPU from 1 KiB (8–19× the generic path on non-ASCII text);
   each call costs 1.0–1.7 ns, 11–24% of `utf8` at 8–32 bytes. GFNI is in the
   AVX-512 tier because LLVM shifts bytes with it (4–10% from 1 KiB). Wired:
   `validate.utf8` and `validate.utf8WithErrors`. To wire another public
   function:
   - Move its body into a private function (`fooKernel`) and make the public
     one `return dispatch.call(@src(), fooKernel, .{ a, b });`, with
     `const dispatch = @import("dispatch.zig");`. `@src()` names the
     exported symbol, so each public function calls `dispatch.call` itself,
     never through a shared helper, and only non-generic functions can be
     wired (wire the public wrappers of a generic one).
   - Inside kernels, call other kernels directly (`barKernel`), not the
     wired public function, which would check the tier again.
   - Arguments: slices, pointers, integers, enums, bools, and packed structs
     travel as words, other types (such as `base64.DecodeOptions`) by
     pointer, up to six words (a slice is two). Results: `void`, `bool`,
     `usize`, enums, and structs of up to two scalar fields, such as `Result`.
     Anything else is a compile error in `dispatch.zig`; ask its owner.
   - Comptime choices inside the kernels keep working unchanged: each object
     is compiled for its tier, so `simd.isa`, `simd.has_vbmi`, and
     `builtin.cpu` features (base64's `native`) see that tier's CPU.
   - Tests: this repository's test builds pin every call to the `-Dcpu`
     level, so the tests at each `-Dcpu` still check that level's kernels.
     Wrap a differential test's body in `dispatch.forEachLevel(f, args)` to
     run it once per tier the CPU has, through the path consumers call; at
     `-Dcpu=baseline` on an AVX-512 machine that is all four.
   - Benchmarks: a `-Dcpu=baseline` build now dispatches; pass
     `.dispatch = false` to `b.dependency("utf", ...)` for the generic path.
2. **Block size.** 64 bytes per iteration on every ISA (four 16-byte vectors,
   two 32-byte, one 64-byte), so the algorithm's carries are the same code and
   only the vector width changes. **Measure** 32 vs 64 on AVX2. Validation
   writes each block as one `@Vector(64, u8)` and lets LLVM split it; the
   generated loops are tight on every x86 level. Load blocks with
   `simd.load`: coercing an array to a vector compiled to a load per lane
   (4× slower). For UTF-8, the bytes one to three back come from unaligned
   loads on AVX2 and SSE (+10%, +17%) and from shifts on AVX-512, where the
   loads lost 11%.
3. **Short inputs.** Below one block, the scalar path, unless a measured
   masked or overlapping-load path beats it. Landed for validation: an ASCII
   check on overlapping loads, then one zero-padded block built in registers
   (`simd.loadPartial`), which beats the scalar validator on non-ASCII text
   from 16 bytes. Building the padded block in a stack buffer stalls
   store-to-load forwarding and was half as fast.
4. **Valid vs checked.** The checked conversion validates in the same pass;
   it must not cost more than validating and converting separately.
   Measured for transcoding ([convert-20261030.md](results/convert-20261030.md)):
   from 4 KiB the checked form is level with or ahead of simdutf's validator
   followed by our valid form on every corpus (UTF-16 to UTF-8 Latin 16.2
   vs 8.8 GB/s), and 10–12% behind it only on non-ASCII UTF-8 at 64 bytes.
   It costs 10–25% over the valid form on non-ASCII UTF-8 and about 2× on
   UTF-32 to UTF-16, whose valid loop is only a narrowing store.

## Order of work

Files have one owner at a time. Work that needs another's file asks for the
change instead of editing it; a private helper is fine until the merge.

Wave 1, in parallel:

- **Validation**: `src/validate.zig`, `src/simd.zig` (the shared vector
  helpers and ISA selection; the others may keep private helpers until it
  lands), and the scalar validators for ASCII, UTF-16, and UTF-32 in
  `src/scalar.zig`. Landed: `simd.zig` has `isa`, `width`, `Block(T)`,
  `load`, `load16`, `loadPartial`, `lookup16` (`pshufb`/`tbl`), `prev`, and
  `bitmask`. Use `bitmask`, not `@bitCast`, for a lane mask: on aarch64_be
  a bool-vector `@bitCast` orders bits differently depending on how the
  vector was made. `lookup16` uses the instruction only under the LLVM
  backend; Debug builds on x86_64 take a per-lane loop.
- **Transcoding**: `src/convert.zig`, `src/length.zig`, and the scalar
  transcoders in `src/scalar_convert.zig`. Landed: every conversion among
  UTF-8, UTF-16LE/BE, UTF-32, and Latin-1, checked and valid, the length
  functions and code-point counts, and the
  [measurements](results/convert-20261030.md). UTF-8 decodes in Lemire and
  Muła's 12-byte windows (comptime tables: 209 shuffles, a 4096-entry index)
  after Keiser–Lemire validation of each 64-byte block; UTF-16 and UTF-32
  encode by expanding to 32-bit lanes and packing with `lookup16`. Byte
  shuffles go through `simd.lookup16`; where it has no instruction (generic,
  and Debug on x86_64) only the ASCII paths stay vectorized and other
  blocks go to the scalar code in steps of 16 units, doubling to 64 while
  blocks keep failing, called between SIMD loops and never inlined, since
  LLVM otherwise spills the loop's constants or splits its ASCII stores. Table entries and windows load volatile, as in
  base64. The length functions handle 16–63 bytes with 16-byte vectors and
  an overlapping masked last one. Left for wave 2: AVX-512 kernels (simdutf's
  `icelake` is 1.6–2.8× ours on non-Latin text), Cyrillic and CJK UTF-8 to
  UTF-16 against `haswell` (82–85%), UTF-16 and UTF-32 to UTF-8 for CJK
  (55%, 68%), the generic path's valid CJK UTF-8 decode, and SSE UTF-16 to
  UTF-8 on emoji.
- **Base64**: `src/base64.zig`, scalar reference included. Landed: AVX2,
  SSSE3, NEON, and generic kernels, the reference in `src/scalar_base64.zig`,
  and the [measurements](results/base64-20261030.md). Left for wave 2: an
  AVX-512 VBMI kernel (simdutf's `icelake` is 1.5–2.6× ours at 4–64 KiB),
  short padded decode (std and Rust lead at 16 bytes), and whitespace (70%
  of simdutf's AVX2 kernel).
- **Harness**: `bench/` with a Zig driver and arms for simdutf (C++, from
  nixpkgs), Rust (`simdutf8`, `base64-simd`), Go (`unicode/utf8`,
  `encoding/base64`), and Zig's std; the corpus (simdutf's benchmark texts
  across scripts, fetched and pinned by hash, plus generated sizes); `just
bench-compare`; and an oracle tool that runs inputs through simdutf so tests
  and fuzzers can compare error kinds and positions. Landed: `just
bench-compare`, `just oracle`, and the layout and contract in
  [harness.md](harness.md).

Wave 2: the measured decisions above, AVX-512 paths where wave 1 did AVX2,
and a performance pass against simdutf on every operation and corpus.

- **Dispatch**: `src/dispatch.zig`, `src/simd.zig`, and `build.zig`.
  Landed: decision 1's runtime dispatch, and `simd.bitmask` for vectors of
  fewer than 8 lanes on the self-hosted backends, so `convert.zig`'s `mask4`
  can call it directly.
