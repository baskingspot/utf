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
2. **Block size.** 64 bytes per iteration on every ISA (four 16-byte vectors,
   two 32-byte, one 64-byte), so the algorithm's carries are the same code and
   only the vector width changes. **Measure** 32 vs 64 on AVX2.
3. **Short inputs.** Below one block, the scalar path, unless a measured
   masked or overlapping-load path beats it.
4. **Valid vs checked.** The checked conversion validates in the same pass;
   it must not cost more than validating and converting separately.

## Order of work

Files have one owner at a time. Work that needs another's file asks for the
change instead of editing it; a private helper is fine until the merge.

Wave 1, in parallel:

- **Validation**: `src/validate.zig`, `src/simd.zig` (the shared vector
  helpers and ISA selection; the others may keep private helpers until it
  lands), and the scalar validators for ASCII, UTF-16, and UTF-32 in
  `src/scalar.zig`.
- **Transcoding**: `src/convert.zig`, `src/length.zig`, and the scalar
  transcoders in `src/scalar_convert.zig`.
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
