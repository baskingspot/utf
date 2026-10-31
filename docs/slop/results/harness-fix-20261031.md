# Harness: out-of-line calls and written output buffers, 2026-10-31

Two harness effects the base64 orb reported, fixed in every arm, and how much the rows moved:

1. **First touch.** The Zig arms mapped a fresh output buffer for each row and timed it unwritten. A masked AVX-512 store whose masked-off lanes overhang into a page nothing has written never faults the page in, so it takes a microcode assist on every call; the base64 orb's driver saw simdutf's 4 KiB decode fall from 44 to 21 GB/s. Now every arm writes its whole output buffer before it times a row (`memset`, `@memset`, `fill(1)`, `clear`). `check` still leaves it unwritten, so RSS counts only the pages written.
2. **Inlining.** The Zig arms called the function directly in the timing loop, so LLVM inlined it and kept its constants in registers across iterations, and Rust's loop was generic over the function, with LTO, to the same effect. A caller of a library pays the call and the constant loads every time, as the C++ arm does calling into libsimdutf. Now the Zig loops call with `@call(.never_inline, ...)` and Rust calls through a `black_box`ed function pointer; Go already called through a function value.

- Machine: Amp orb, KVM guest, Intel Xeon @ 2.60GHz (Ice Lake server, AVX-512 with VBMI2), pinned to CPU 3. Package at `fcdef96` (base64 wave 2 merged). simdutf 9.2.1, Zig 0.16.0 ReleaseFast, Rust 1.99.0, Go 1.26.10.
- Method: [buildset.sh](harness-fix-20261031/buildset.sh) built every arm from the old harness (`fcdef96`) and from the fixed one, `utf` in three builds: native, `x86_64_v3` with `dispatch=false`, and `baseline` with runtime dispatch. [ab.sh](harness-fix-20261031/ab.sh) ran old and new of each arm back to back, in an order that rotates and alternates each round, 6 rounds of `validate-utf8 base64-encode base64-decode base64-decode-mime` at `BENCHTIME_MS=100`; simdutf ran under its own pick (`icelake`) and `haswell`. Tables: [benchstat.txt](harness-fix-20261031/benchstat.txt), raw GB/s in `old-*.txt` and `new-*.txt`.
- Equivalence: with the fix, `utf` 877, std 156, Rust 248, and Go 141 rows match simdutf's checksums.

## What moved

- **First touch: nothing in this harness.** simdutf's rows are unchanged under both kernels (geomean +0.29% `icelake`, −0.02% `haswell`; 4 KiB decode 38.64 to 38.79 GB/s), and no `utf` row at 4 KiB or above moved by more than 5%. The arms' buffers are `n * out + 64` bytes, and no corpus size puts an overhanging store's masked lanes on a page beyond the written bytes. The fix keeps it that way for any size.
- **Inlining: the short rows of `utf` and Rust were overstated.** Out of line, `utf`'s UTF-8 validation of 16 bytes of ASCII is 1.54 GB/s, not 3.09 (−50%), 64 bytes −41 to −43%, 256 bytes −30 to −38%, 4 KiB −4%, in the native and AVX2 builds alike; the dispatching baseline build, which already called through a function pointer, did not move. Base64 at 16 bytes lost 5–24% (encode −13% native, −18% AVX2, −24% baseline), at 64 bytes up to 27%, at 4 KiB at most 5% either way. Rust's `simdutf8` lost 42–55% from 16 to 256 bytes and `base64-simd` 4–24% at 16 bytes; its 256-byte to 4 KiB decode gained 10–13%. Zig std's 16-byte validation gained 45% and its 64–4096-byte rows lost 8–23%. Go did not move. Rows of 64 KiB and up did not move in any arm (within ±3%).
- **Spread.** The old `utf` 16-byte rows were tight within a run (±1%), but inlining is a per-build decision, which is how they moved between the base64 orb's builds. The new short rows spread more: ±1–6% for `utf`'s validation, up to ±23% for some of its base64 rows, and up to ±31% for Rust, on this shared guest.

## What it changes in the gaps

Against simdutf, from the same rounds (`utf` ÷ simdutf, old → new):

| Row                        | native ÷ `icelake` | AVX2 ÷ `haswell` |
| -------------------------- | ------------------ | ---------------- |
| ValidateUtf8/ascii-16      | 1.12 → 0.56        | 2.62 → 1.31      |
| ValidateUtf8/ascii-64      | 1.10 → 0.64        | 1.46 → 0.83      |
| ValidateUtf8/ascii-256     | 1.52 → 1.05        | 1.59 → 0.98      |
| ValidateUtf8/ascii-4096    | 1.58 → 1.51        | 1.80 → 1.73      |
| Base64Encode/random-16     | 0.86 → 0.75        | 1.69 → 1.38      |
| Base64Decode/random-16     | 1.09 → 1.02        | 1.45 → 1.22      |
| Base64Decode/random-64     | 1.25 → 1.14        | 1.49 → 1.31      |
| Base64DecodeMime/random-16 | 1.13 → 1.07        | 1.45 → 1.22      |

So short UTF-8 validation, which the baseline had ahead of simdutf, is behind it at 16 and 64 bytes on AVX-512: 10.4 ns a call for 16 bytes against simdutf's 5.8, std's 10.1, and Rust's 9.5. That is the cost of entering the kernel, its constants and the AVX-512 setup, which inlining had hidden; it is now validate.zig's short-input gap. The other baseline ratios ([baseline-20261031.md](baseline-20261031.md)) hold from 4 KiB; its 16–256-byte `utf` and Rust rows read high by the amounts above.
