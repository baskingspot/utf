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
  a checked form (`utf8ToUtf16le(src, dst) ConvertResult`: validates while
  it converts, and reports the error kind and position, and the output
  written, which on failure holds the input before the error, as simdutf's
  `full_result` does) and a valid form (`validUtf8ToUtf16le(src, dst)
usize`: assumes valid input, fastest).
- `length`: the output size each conversion needs (`utf16FromUtf8(src)`, and so
  on) and `countUtf8`/`countUtf16le`/`countUtf16be` for code points.
- `base64`: `encode(dst, src, options) usize`, `encodedLen(n, options)`,
  `decode(dst, src, options) Result`, `maxDecodedLen(n)`. Options: alphabet
  (standard, URL-safe), padding on encode, and the last-chunk rule on decode
  (loose, strict, stop before a partial chunk), with ASCII whitespace ignored
  as WHATWG's forgiving-base64 does and simdutf does. `decode` may run in
  place (`dst` starting at `src.ptr`), as simdutf's does: any path that
  reads `src` again after writing `dst` checks first that its stores end
  before what it reads (`untouched` in `src/base64.zig`).
- `Result`, `ConvertResult`, and `Error` (`src/result.zig`): simdutf's error
  kinds and positions, so simdutf is a differential oracle.

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
     wired public function, which would make another indirect call.
   - Arguments: slices, pointers, integers, enums, bools, packed structs,
     and structs of those whose fields fit in one word (such as
     `base64.DecodeOptions`) travel as words, other types by pointer, up to
     six words (a slice is two). Results: `void`, `bool`,
     `usize`, enums, structs of up to two scalar fields, such as `Result`,
     and structs of an enum of a byte and two `usize` that are equal when
     the enum is `none`, such as `ConvertResult`, which cross in two words:
     zero and `count` on success, as a `Result` does, else the enum with
     `written` in the 56 bits above it and `count`
     ([convert-written-20261102.md](results/convert-written-20261102.md)).
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
   - Size: each tier's object exports every wired function, built with
     function and data sections, so the linker's `--gc-sections` (Zig's in
     every mode but Debug) keeps only the exports the main build's slots
     reference: the functions the program calls. The main build exports
     the panic entry the objects forward to only where
     `std.debug.runtime_safety`; exported always, it linked std's panic
     handler into every ReleaseFast program
     ([dispatch-size-20261101.md](results/dispatch-size-20261101.md)).
2. **Block size.** 64 bytes per iteration on every ISA (four 16-byte vectors,
   two 32-byte, one 64-byte), so the algorithm's carries are the same code and
   only the vector width changes. **Measure** 32 vs 64 on AVX2. Validation
   writes each block as one `@Vector(64, u8)` and lets LLVM split it; the
   generated loops are tight on every x86 level. Load blocks with
   `simd.load`: coercing an array to a vector compiled to a load per lane
   (4× slower). For UTF-8, the bytes one to three back come from unaligned
   loads on AVX2 and SSE (+10%, +17%) and NEON (+9%) and from shifts on
   AVX-512, where the loads lost 11%. **Decided for validation: 64 on AVX2**
   ([validate-wave2-20261031.md](results/validate-wave2-20261031.md)):
   against 32-byte blocks on `x86_64_v3`, 64 is 14% faster on UTF-8 at
   4 KiB and 4–5% at 64 KiB, 12–49% on UTF-16, and 16% on ASCII at 4 KiB;
   32 wins only below one block (22–43% at 16 bytes), which the short paths
   take anyway. What moved long inputs was where blocks load: past four
   blocks for ASCII, from 4 KiB for UTF-8 that is not ASCII, and from eight
   blocks for UTF-16 and UTF-32, the first block loads unaligned and the
   rest from the next 64-byte boundary, so no load splits a cache line
   (ASCII at 64 KiB 52 to 146 GB/s), with one test per group of four
   blocks (eight for UTF-16).
3. **Short inputs.** Below one block, the scalar path, unless a measured
   masked or overlapping-load path beats it. Landed for validation: an ASCII
   check on overlapping loads, then one zero-padded block built in registers
   (`simd.loadPartial`), which beats the scalar validator on non-ASCII text
   from 16 bytes. Building the padded block in a stack buffer stalls
   store-to-load forwarding and was half as fast. Wave 2: on AVX-512 one
   masked load (`llvm.masked.load`, LLVM backend only) builds the padded
   block for UTF-8, UTF-16, and UTF-32, 1.2–1.9× `loadPartial` at 7–45
   bytes; ASCII keeps overlapping loads, now up to 64 bytes (+15% at 64),
   where the masked load lost. Wave 3: it is `simd.loadShort`, shared with
   transcoding's tails; where the masked-off bytes would reach another
   page it loads the 64 bytes that end where the input does instead.
4. **Valid vs checked.** The checked conversion validates in the same pass;
   it must not cost more than validating and converting separately.
   Measured for transcoding ([convert-20261030.md](results/convert-20261030.md)):
   from 4 KiB the checked form is level with or ahead of simdutf's validator
   followed by our valid form on every corpus (UTF-16 to UTF-8 Latin 16.2
   vs 8.8 GB/s), and 10–12% behind it only on non-ASCII UTF-8 at 64 bytes.
   It costs 10–25% over the valid form on non-ASCII UTF-8 and about 2× on
   UTF-32 to UTF-16, whose valid loop is only a narrowing store.
5. **ReleaseSafe.** **Decided by the owner: ReleaseSafe keeps its safety
   checks.** No `@setRuntimeSafety(false)`, and no other way around the
   checks, to win rows. A safe build ran 0.97 of simdutf on
   `d2d515e` ([baseline-final-20261031.md](results/baseline-final-20261031.md));
   what the checks cost there is the price of the mode, and a speedup counts
   only where it keeps every check.

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
  backend; Debug builds on x86_64 take a per-lane loop. Under Zig 0.17, do
  not `@bitCast` a vector to an array of scalars of another lane type: it
  becomes a loop that shifts the whole value once per element, which made
  the UTF-8 to UTF-32 decoder 11–15× slower on emoji
  ([bitcast-array-20261101.md](results/bitcast-array-20261101.md)). Cast to
  a vector of the lane type and coerce that to the array.
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
  and the [measurements](results/base64-20261030.md). Wave 2 took the
  rest; see below.
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

- **Harness**: `bench/`. Landed: rows for all 66 operations simdutf shares
  with the package (`bench/ops.tsv`, read by every arm), MIME base64,
  `optimize`, `cpu`, `dispatch`, and `kernel` variables for `just
bench-compare`, and a per-operation geomean summary. The baseline
  ([baseline-20261031.md](results/baseline-20261031.md)) is the gap list:
  0.81 of simdutf's `icelake` overall and 1.15 of `haswell`. Largest gaps
  against `icelake`: UTF-8 to Latin-1 on Latin-1 text (0.11–0.19), Latin-1
  to UTF-8 (0.22–0.30), UTF-16 to UTF-32 and the checked byte swap on emoji
  (0.22–0.28), UTF-16 and UTF-32 validation (0.47–0.72), and MIME base64
  (0.50). Against `haswell`: UTF-16 to UTF-8 on CJK (0.50), UTF-32 to
  Latin-1 (0.45–0.52), 16-byte Latin-1 and UTF-16-to-Latin-1 (0.44–0.50),
  and MIME base64 (0.77). Wave 3: the Zig arms build `Out` from scalars
  ([harness-wave3-20261031.md](results/harness-wave3-20261031.md)), and `just
oracle` compares every public function with simdutf: validation of every
  form with errors, every checked and valid conversion, every length
  function, and every base64 mode (no mismatches).
- **Base64**: `src/base64.zig` and `src/scalar_base64.zig`. Landed: the
  AVX-512 VBMI kernel (`Isa.avx512vbmi`, `vpcompressb` whitespace with
  VBMI2), the big-endian fix (lane bitcasts in encode and decode; NEON on
  aarch64_be), `simd.zig` helpers where they fit, runtime dispatch, AVX-512
  tails that neither read past the input nor mask stores onto another page,
  CR LF removed in one shift, and the
  [measurements](results/base64-20261031.md): harness geomeans 0.98 of
  `icelake`, 1.13 of `haswell`, 1.04 of `westmere`. Left: AVX2 and SSSE3
  whitespace from 4 KiB (LF 0.57–0.73 of `haswell`, CR LF 0.74–0.89), short
  decode against Rust in the harness (16 B 0.44–0.54), and short encode
  against `icelake` (0.80–0.91 at 16–256 B).
- **Validation**: `src/validate.zig` and `src/scalar.zig`. Landed: every
  public validator dispatches at runtime; long inputs load from 64-byte
  boundaries in groups of four or eight blocks, AVX-512 short inputs take
  one masked load, error positions come from lane masks for ASCII, UTF-16,
  and UTF-32 (no scalar rerun), and the
  [measurements](results/validate-wave2-20261031.md): harness geomean 1.28
  of `icelake` and 2.45 of `haswell` over the ten validation operations
  before the harness's out-of-line calls; on `d3cd9ab`, 1.22 as committed
  and 1.32 once the harness row stops copying the 16-byte result back
  whole, when ASCII and UTF-8 lead Rust at 16–256 B. Left: that copy (the
  harness's) and `dispatch.call`'s `Result` copy (dispatch's), error inputs
  of 64–256 B, and UTF-8 on non-ASCII text under 64 B (0.82–0.88 of
  `icelake` in the suite).
- **Dispatch**: `src/dispatch.zig`, `src/simd.zig`, and `build.zig`.
  Landed: decision 1's runtime dispatch, and `simd.bitmask` for vectors of
  fewer than 8 lanes on the self-hosted backends, so `convert.zig`'s `mask4`
  can call it directly.
- **Transcoding**: `src/convert.zig`, `src/length.zig`, and
  `src/scalar_convert.zig`. Landed: every public conversion and length
  function dispatched (the four that return the input length are not:
  nothing to select), `mask4` replaced by `simd.bitmask`, the big-endian
  test fixes (the tests read native UTF-16 units as little-endian, and
  U+0800 is not the same in both byte orders), and the
  [measurements](results/convert-20261031.md): harness geomeans 1.14 of
  `icelake` (wave 1: 0.85), 1.33 of `haswell` (1.09), 1.27 of `westmere`.
  AVX-512 kernels (`v512`: VBMI, VBMI2, BMI2) follow Clausecker and Lemire:
  UTF-8 decodes 64 bytes at a time by compressing lanes at character ends,
  UTF-16 and UTF-32 encode with `vpmultishiftqb`, `vpermb`, and compress,
  UTF-8 to Latin-1 decodes at every continuation byte from a load one byte
  back (no loop-carried shift), Latin-1 to UTF-8 interleaves lead and
  continuation bytes with `vpermt2b`, and the byte swap checks pairs a
  64-byte block at a time. Tails use masked loads and stores only when the
  64 bytes stay in one page, else a stack buffer out of line (inline, its
  aligned frame cost every short call 1-2 ns). Long fixed-ratio loops
  (Latin-1 widening, narrowing to Latin-1, the byte swap) take a first step
  to the output's 64-byte boundary: 1.4-1.8× on Latin-1 to UTF-16/32 over
  16 buffer offsets. Stores of a whole register are volatile, or LLVM splits
  them. On AVX2 and SSE, UTF-16 and UTF-32 to UTF-8 encode BMP text in
  16-bit lanes (1.4-2.0× on CJK, Korean, Hindi); the length functions count
  with mask popcounts on AVX-512 and load aligned from 16 vectors on. Tried
  and dropped: steps of 256 or 1024 units on the generic path (neutral to
  −15%), accumulating counts in vectors instead of popcounts on AVX-512,
  and sending inputs under 64 bytes to the 16-byte paths (slower on every
  length not a multiple of 16). The generic checked forms are within ±10%
  of an out-of-line scalar call; wave 1's "25% under" compared an inlined
  one. Left: UTF-16 to UTF-8 on two-byte scripts (0.89-0.94 of `icelake`),
  Latin-1 to UTF-8 on Latin-1 text from 4 KiB (0.74-0.79 of `icelake` and
  `haswell`), the checked fixed-ratio conversions at 256 B (0.69-0.84), the
  valid byte swap at 256 B (0.53-0.63); against `haswell` UTF-16 to UTF-8 on
  Japanese, Korean, and Hindi (0.74-0.83) and UTF-32 to UTF-8 on Korean and
  Hindi (0.80-0.84); against `westmere` the UTF-8 length functions from
  UTF-16 and UTF-32 (0.83-0.96); the generic path's decode of non-ASCII
  text, 10-30% under the scalar code. Exact multiples of 16 ASCII bytes are
  2-4 ns slower than the wave-1 16-byte path, since the AVX-512 kernels load
  their constants up front. A `Result` chosen between two built ones was
  copied out with one 16-byte load after two narrower stores, stalling store
  forwarding for 6 ns in every checked conversion; build it from scalars.
  The harness's `written()` did the same with its `Out` union, which cost
  the checked forms' short rows about 4 ns; fixed in wave 3
  ([harness-wave3-20261031.md](results/harness-wave3-20261031.md)).

Wave 3: the shared helpers in `simd.zig`, the result copy, and the gaps the
wave-2 measurements left.

- **Dispatch**: `src/dispatch.zig` and `src/simd.zig`. Landed: `call` no
  longer copies a returned `Result` with one 16-byte load after two narrower
  stores ([dispatch-wave3-20261031.md](results/dispatch-wave3-20261031.md)).
  Two words travel as a `u128`, which LLVM keeps in registers, every path
  of `call` (each tier, in place, the first call) yields it, and the struct
  is built once after they join; the `.off` role rebuilds the kernel's
  result from its fields. `WithErrors` validation 2.0-2.2× at 16-64 bytes
  dispatched (`asciiWithErrors` 12.4 to 5.6 ns) and 1.7-2.4× native where
  the copy was, checked conversions 1.2-1.8× dispatched; dispatch now
  costs 0.1-3 ns over native on these rows. Kernels may return from as
  many places as they like: no result crosses `call` whole.
- **Shared helpers**: `src/simd.zig`, and `validate.zig`, `convert.zig`,
  and `base64.zig` moved onto them
  ([simd-wave3-20261031.md](results/simd-wave3-20261031.md)). One set
  replaces wave 2's private copies: `loadAligned`, `toBoundary`,
  `loadShort` (masked load), `loadTail` (the block ending at the input's
  end, moved down with `vpermb`), `storePartial` (masked store, else
  16-byte and integer stores), `loadVolatile`, `storeVolatile`, `lowBits`
  (`bzhi`), `compress`, `permute`, `permute2` (`vpermi2b/d`), `multishift`,
  `pext`, `pdep`, and `narrow` (`packusdw`/`packuswb`). A masked access
  stays masked only while its masked-off bytes are on the page of its last
  counted byte, tested first as "all 64 bytes on one page" (a masked load
  whose rest reaches an untouched or unreadable page costs about 240
  cycles, measured); otherwise it goes in
  as the end of the 64 bytes that end where the data does, which lie on
  that page, moved with `vpermi2b`/`vpermb`: no call, no saved registers,
  no stack buffer. `loadShort` takes up to a whole block and `storePartial`
  stores at most its lane count, as transcoding's tails need. Still
  private, as only one module uses them: base64's `pmaddubsw`/`pmaddwd`/
  `pmulhuw` and whitespace ring, transcoding's shuffle tables and
  `firstStep`, length's `alignHead` (0 when aligned, which its sums
  want, where `toBoundary` gives a whole block). Every module level in
  the harness (geomean native -0.2%, dispatched +2.8%, AVX2 -0.9%, where
  unchanged `length` code moves ±2.5% and single rows ±15% with layout);
  base64's driver 1.04-1.07× (short decode 1.2×); short validation next
  to an untouched page 98-142 ns to 4-7 ns, a wave-2 bug. Also: AVX2 and
  SSE UTF-16 to Latin-1 finish the last 1-31 units in two 16-unit
  vectors, 2.1-2.4× at 16 units.
- **Validation and base64**: `src/validate.zig` and `src/base64.zig`
  ([validate-base64-wave3-20261031.md](results/validate-base64-wave3-20261031.md)).
  Base64 decode takes regular lines (one length, a multiple of four and
  at least 64, the same 1-4 whitespace bytes after each, as MIME and PEM
  have) without the ring: the block ending a line decodes from `src`,
  overlapping what the line's earlier blocks wrote, and the gap is
  skipped; other whitespace goes to `noinline decodeStaged`, which keeps
  the ring. MIME 4 KiB 1.3× native, 1.9× AVX2, 1.5× SSE; harness MIME
  0.96 to 1.15 of `icelake`, 0.99 to 1.31 of `haswell`. AVX-512 encode
  steps 48 bytes from the 64 that end at the step's end, so one partial
  block finishes, with the index hidden from LLVM's unroller. The
  `WithErrors` validators up to two blocks take the error position from
  the masks of the blocks they test (inputs with an error 1.1-1.9×); on
  AVX-512 short UTF-8 tests ASCII on its masked load. Rejected, measured:
  a `vpermb` for the UTF-8 shift by two (0.82-0.88× at 7-45 bytes),
  masks before the pass test in short UTF-16/32 (0.47-0.75× on valid
  input), and inlining `decodeStaged`.
- **Transcoding**: `src/convert.zig`, `src/length.zig`, and two
  additions to `src/simd.zig`
  ([convert-wave3-20261031.md](results/convert-wave3-20261031.md)).
  Harness 1.25 to 1.29 of `icelake`, 1.38 to 1.55 of `haswell`, 1.32 to
  1.38 of `westmere`; rows under 1.0 139 to 114, 139 to 51, 194 to 112.
  AVX2 and SSE encode BMP UTF-16 and UTF-32 in simdutf's byte layout (the
  low byte twice, then lead and middle bytes, one `xor` for two-byte
  leads; no blends): Korean and Hindi 1.31× on AVX2. `simd.shuffleLanes`
  packs two groups per AVX2 `vpshufb`; `simd.narrow` uses `vpermt2b` on
  VBMI (UTF-32 to UTF-16 1.06-1.23×). The checked byte swap checks pairs
  only in blocks with a surrogate or a low surrogate after them (1.32× on
  AVX2 and SSE, emoji 0.69-0.93×). Fixed-ratio loops align to the input
  (the harness's 0.63-0.69 UTF-32 to Latin-1 rows were input alignment).
  AVX-512 kernels test a short ASCII input before loading their
  constants. Length without AVX-512: masked equalities and signed
  compares where unsigned ones take two operations, the base count
  added once per run of blocks, big-endian UTF-16 compared against
  swapped constants (1.05-1.22×). Left, with reasons in the results:
  AVX-512 Latin-1 to UTF-8 on Latin-1 text (0.77-0.88, shuffle-port
  bound), SSE Latin-1 to UTF-16 at 4-64 KiB (store-bound), 256-byte
  ASCII widening (0.73-0.82, not investigated), short `sumBlocks`
  reductions on AVX2; other rows under 1.0 move with layout and buffer
  offsets. Harness rows move up to ±50% between processes and ±15% with
  a function's address, so compare in one process or with a driver.

After wave 3: the harness and the final baseline
([baseline-final-20261031.md](results/baseline-final-20261031.md)).
`just bench-compare` runs every arm as a server pinned to one core and times
each row on every arm back to back, in a rotating order, with fresh processes
each round; a row's ratio is the median of the per-round ratios, with a 95%
interval, and the summary counts the rows it cannot call. Every arm places
each buffer in a mapping of its own (input at a page, output 2 KiB past one,
the slack written), and `cpu` builds std, Rust (without run-time detection
at an x86-64 level), and Go for the same ISA. Run to run, utf ÷ simdutf per
operation moved 25% (median) with the old harness and 1.5% with this one.
On `d2d515e`: 1.18 of `icelake`, 1.55 of `haswell`, 1.39 of `westmere`, 1.13
dispatching from baseline x86-64, 0.97 in ReleaseSafe; std 7.65-13.74×, Rust
2.25-3.12×, Go 7.02-12.34×. Code layout is still uncontrolled (±15%), so
compare rows under that gap with a driver.

Wave 4:

- **Transcoding**: `src/convert.zig`
  ([convert-wave4-20261031.md](results/convert-wave4-20261031.md)). Every
  conversion op but native `Latin1ToUtf8` (0.92 to 0.99) at or above
  simdutf at every ISA by its geomean; rows under simdutf outside the noise
  55 to 35 native, 26 to 23 AVX2, 35 to 24 SSE. The valid byte swap's gap
  was a five-instruction loop straddling a 64-byte code line in some links
  (1 against 1.6 cycles a block); it now swaps four blocks a step and ends
  without a loop (4 KiB 1.74-1.78×). Zig cannot align a loop, so a short
  hot loop is a layout risk: unroll it. AVX-512 Latin-1 to UTF-8 uses
  simdutf's `vpermb` and `vpshldw` layout (Latin-1 text level with
  `icelake` from 4 KiB) and a 64-byte short path; AVX-512 UTF-8 to Latin-1
  is full blocks then one masked block (1.13-1.14×). ASCII runs on AVX2 and
  SSE take loops of their own with one bound (UTF-8 decodes and UTF-16 to
  UTF-32 1.2-1.4× at 4 KiB). Keep `utf8BlockEnd`'s load volatile: LLVM
  otherwise extracts it from the block's register on the shuffle port
  (non-Latin UTF-8 decodes 0.7×). Left, with reasons in the results:
  native short calls at 16-64 B (0.80-0.96, 1-2 ns a call, unattributed), AVX-512
  Latin-1 to UTF-8 on Latin-1 text at 64-256 B (0.82-0.93, per-call
  constants), AVX2 UTF-16BE to UTF-32 at 4 KiB (0.89), and rows whose
  instructions match `old`'s but move with the link.

- **Per-call overhead**: `src/dispatch.zig`, `src/simd.zig`, and the
  short and entry paths of `validate.zig`, `length.zig`, and `base64.zig`
  ([calls-20261031.md](results/calls-20261031.md)). Each wired function
  calls through a slot of its own, a pointer to the best tier's export
  that starts at a cold `resolve` (one load and an indirect call; the
  cached tier, compare, jump table, and `Init` are gone): dispatch costs a
  median 0.87 ns a call, from 1.51, where simdutf's costs 2.57. Structs
  whose scalar fields fit in a word travel as one; tier objects omit the
  frame pointer. `dispatch.exported` says a build is a tier's object, where
  a kernel's long path goes out of line so its loops' saved registers do
  not cost short calls, and `dispatch.pack`/`unpack` carry a `Result` back
  from such a part in registers (returned whole it went through memory and
  stalled, 7 ns). UTF-8 validation uses them; `base64.decode` and most
  AVX-512 conversions still save 3-6 registers on every call. Short paths:
  AVX-512 length functions count up to a block in one masked load, AVX-512
  encode tails are one masked load, `utf32WithErrors` tests up to four
  blocks at once, `asciiWithErrors` takes 64 bytes in one load, and base64
  decode's last block of up to 32 characters is classified and packed from
  half the block on AVX2, SSE, and NEON. Measured and dropped: keeping
  `loadShort`'s and `storePartial`'s page-end constants out of loop
  preheaders (neutral on transcoding's short rows). utf ÷ simdutf by operation, `origin/main` to
  here: native 1.13 to 1.13 (16-64 B 1.15 to 1.18), dispatched 1.07 to 1.10
  (16-64 B 0.96 to 1.04), AVX2 1.52 to 1.53, SSE 16-64 B 1.43 to 1.48.
  Left: native base64 decode at 16-256 B 0.92-0.94 of `origin/main`
  (unexplained, layout suspected), 16-byte AVX-512 encode (0.88 of
  `icelake`), and std's inline UTF-8 loop at baseline (0.72-0.85).

Wave 5 ([short-20261101.md](results/short-20261101.md)):

- **Short calls.** Every AVX-512 conversion that saved three or more
  registers before its length test (18 on `39088d1`) now runs its short path
  first and its long path through `longPath` in `convert.zig`: out of line
  in the tier objects, its `Result` back through `dispatch.pack`, inline in
  native builds (split there, 64-256 B lost 9-12%). Kernels that saved 0-2
  stay whole (the call costs about 3 ticks). Dispatched 16-unit conversions
  1.05x, 64-4096 level. `base64.decode` keeps its long path inline (out of
  line cost 88-344 characters 7-12 ticks a call) and takes inputs under 64
  characters with one `loadShort` (16 B 1.20x); the native regression since
  `66fa49c` was codegen and is gone. AVX-512 Latin-1 to UTF-8's block loop
  is inline (LLVM had kept the shared function out of line: two prologues
  and a result through memory) and tests each block once: 256 B 1.08-1.28x.
  Its constants before the loop were not the cost.
- **The harness's Zig loop costs more than its C++ loop** on a real kernel:
  the same dispatched `latin1ToUtf8` is 9.0 ns a call in the harness and
  5.8 in the per-call loop at 16 B (simdutf 8.9 and 9.0). testingx's
  `b.loop()` is an out-of-line call per iteration (seven saved registers, a
  counter in memory, a `!bool` through the stack), part of it. Fix the loop
  before reading 16-256 B rows against simdutf as the kernels'.
- Identical code still moves up to 23% with the link; AVX2 and SSE short
  calls are unmeasurable here (no tier override, and the host picks
  AVX-512).
- **Baseline** ([baseline-wave5-20261101.md](results/baseline-wave5-20261101.md)),
  utf ÷ simdutf against baseline-final: icelake 1.18 → 1.15, haswell 1.55 →
  1.59, westmere 1.39 → 1.44, baseline 1.13 → 1.11, ReleaseSafe 0.97 →
  0.98; RSS unchanged. Without the length functions 1.20 and 1.16 on
  AVX-512: on this orb's host their `popBlocks` loop runs at about half
  speed in any build (`66fa49c`'s reads the same), cause unexplained. Under
  simdutf natively: the length functions and 16-256 B rows of Latin-1 to
  UTF-16 and UTF-32, the valid byte swap, and UTF-16LE to Latin-1 (harness
  loop); no operation on AVX2, one 64 B row group on SSE.

aarch64 ([neon-20261101.md](results/neon-20261101.md)):

- **CI and numbers.** `.github/ci.yaml` runs `test` on `ubuntu-26.04-arm`
  (blocking) and `macos-26` (not); `.github/workflows/bench.yml` runs
  `bench-compare` on a hosted aarch64 runner, and `just base=<rev>` adds a
  revision's `bench-utf` as an arm for an A/B in one run. No orb is aarch64.
- **First read** (Neoverse N2, ten operations, 3 rounds): 1.20 of simdutf's
  `arm64`. Under: UTF-8 validation 0.73, base64 encode 0.61, decode 0.89,
  CJK UTF-16 to UTF-8 0.75, 64-byte `countUtf8` 0.40.
- **`simd.bitmask`** builds NEON masks of 32 and 64 lanes with `addp`
  (UTF-8 to UTF-16 1.07, 1.11-1.14 on non-ASCII text). Build a mask from
  one compare: a bool vector joined from two (`@bitCast([2]@Vector(16,
bool){...})`) is materialized as an integer, and the NEON path took it
  apart lane by lane (UTF-16 to UTF-8 on Korean 0.45 until split).
- **Base64** ([neon-base64-20261101.md](results/neon-base64-20261101.md)):
  NEON encodes with `ld3`, a four-register `tbl`, and `st4`, and decodes
  clean blocks with `ld4` and `st3`, classifying the de-interleaved
  characters as they are; LLVM makes the structured accesses from whole
  loads and stores and strided `@shuffle`s. Use `sli` (an intrinsic) where
  LLVM would make `usra` from shifts and adds. Encode 1.03 of simdutf
  (0.61), decode 1.08–1.25 (0.83–0.94); MIME 256 B 0.93 is left.
- **Validation** ([neon-validate-20261101.md](results/neon-validate-20261101.md)):
  every validation operation at or above simdutf's `arm64` on every row
  (UTF-8 0.74 to 1.21, ASCII 0.93 to 1.31, UTF-16 emoji 0.52 to 1.15;
  1.13-1.66 of `1476ab0`), x86 machine code unchanged. Reduce with a byte
  max or min (`@reduce(.Max, v) < 0x80`), not `@reduce(.Or, <bools>)`:
  LLVM lowers the latter through a bit mask, four `addv` for 64 lanes,
  which UTF-8 paid twice a block. UTF-16 groups with a surrogate check the
  pairs on the units' high bytes (`uzp2`) in vectors; the UTF-8 bytes
  before a block come from loads (`prev_by_load`, 1.09 on non-ASCII text).
- **Transcoding** ([neon-convert-20261101.md](results/neon-convert-20261101.md)):
  0.97 to 1.20 of simdutf's `arm64` over 24 operations (1.20 of
  `1476ab0`; rows under 216 to 85), the other 14 conversions 1.00-1.19 of
  `1476ab0`, x86 machine code unchanged. Neoverse N2 shifts by an
  immediate on one vector pipe and permutes on both, and counts bits only
  in vector registers: widen with `tbl` and plain stores (paired to `stp`),
  not `ushll`; reduce with `orr` and one `umaxp`; count with one `cnt`, not
  a `@popCount` per mask. Valid UTF-8 decodes runs of 21 or 16 three-byte
  or 16 four-byte characters before finding a block's end, and other blocks
  with four-byte characters in 12-byte windows (windows everywhere cost
  two-byte text 15-20%). Left: 16-256 B rows (0.74-0.90), CJK UTF-8 to
  UTF-16/32 (0.92-0.97).
- **Length** ([neon-length-20261101.md](results/neon-length-20261101.md)):
  every length operation's short rows at or above simdutf's `arm64` but
  `utf8FromLatin1` at 16 and 64 B (0.82, 0.97); 1.01-1.67 of `1476ab0`
  by operation, x86 machine code unchanged. On NEON the sums keep one
  accumulator to the end and widen once (8-bit lanes had been widened to
  64 bits, 60 instructions, per call at 64 B), mask the last vector with
  a window of a table, and take up to four 16-byte or two 64-byte vectors
  without a loop. The UTF-16 kernels count in byte lanes from the units'
  high bytes (`uzp2`, `tbl` of 32 entries); load them volatile where the
  high byte is the load's only use, or LLVM makes `ld2`, slower on N2.
  UTF-16BE had been 0.88 of LE: masked equalities, where LE got `cmhi`.
- **Apple Silicon** ([neon-apple-20261101.md](results/neon-apple-20261101.md),
  M4 Max, Ghostty's two call sites against its vendored simdutf 9.0.0):
  UTF-8 to UTF-32 on CJK 1.00-1.07 of simdutf from 4 KiB (0.51-0.55), on
  emoji 1.77-1.97 from 64 B (0.89-1.05), and base64 decode 1.01-1.90
  (0.74-0.94). Under Zig 0.17, `storeWide`, `storeWideUnits`, and NEON's
  `lookup16` went through arrays and a lane move each (decode 1.6x slower);
  store and look up whole registers. `convert.apple` (the CPU model's
  `apple_` prefix; Zig's default for macOS is `apple_m1`) gates
  `utf8BlocksApple`: three-byte runs after up to eight ASCII bytes decoded
  in 16-bit lanes and checked on their values, a long run then anything in
  windows checked per window, the rest through `utf8DecodeBlock` (emoji
  1.75 of simdutf, where windows gave 0.94: N2's choice reversed), and the
  last 64-79 bytes as a block. Base64's NEON `st3` store takes no slack, so
  a block that fills `dst` stays in the loop (64 characters 0.73 to 1.84),
  and clean blocks classify as simdutf's do (`clz` of the class picks the
  offset, +5% from 4 KiB). Costs: calls of 1-16 bytes 0.7-1 ns slower,
  constants LLVM loads at entry. Left: `cjk-65535` only level; N2 not
  measured. `main`, on Zig 0.16, has all but the Zig 0.17 workaround: CJK
  1.01-1.08 from 4 KiB (0.74-0.79), emoji 1.43-1.63 (0.92-1.06), base64
  1.04-1.97 (0.71-0.95); ASCII calls of 1-8 bytes 0.75-0.95 ns slower.

In-place base64 decode ([base64-in-place-20261101.md](results/base64-in-place-20261101.md)):

- **`decode` in place returned wrong bytes on input with whitespace**: the
  regular-lines path reloads `src` after writing `dst` (the block ending a
  run, `decodeLines`' last block on AVX-512, and the restart at a line
  `decodeLines` stops at). Now the run's end decodes from the block already
  classified, with an exact store, while the reload would read overwritten
  bytes, and `decodeLines` waits until a whole line's stores end before its
  start (MIME: from the fifth line). Separate buffers: within noise on
  every kernel (AVX2 MIME 256 B 0.96). In place against a separate buffer:
  MIME 256 B 1.5–1.75× the time, 4 KiB 1.1–1.15×, level from 64 KiB. Left:
  AVX-512 `loadTail` loads the 64 bytes ending at the input's end, which in
  place overlap the last block's stores, about 12 ns a call from 64
  characters (before the fix too).
