# Changelog

All notable changes to utf are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- `utf` builds with Zig 0.16 and 0.17. `minimum_zig_version` stays `0.16.0`,
  and CI tests both versions.

### Added

- Runtime kernel selection on x86-64: a build for a generic x86-64 CPU (`-Dcpu=baseline`, `x86_64_v2`, `x86_64_v3`, or a cross target with no CPU given) now runs the AVX-512, AVX2, or SSE kernels the CPU has, for every `validate` function, `base64.encode`, and `base64.decode`. The `-Ddispatch` build option (`.dispatch` in `b.dependency` arguments) turns it on or off; a native or named CPU still selects at compile time.
- `base64.encode`, `base64.decode`, `base64.encodedLen`, and `base64.maxDecodedLen`: SIMD base64 with the standard and URL-safe alphabets, optional padding, ASCII whitespace skipped on decode, the `loose`, `strict`, and `stop_before_partial` last-chunk rules, and simdutf's error kinds and positions, with AVX-512 VBMI, AVX2, SSSE3, and NEON kernels.
- `validate.utf8`, `validate.ascii`, `validate.utf16le`, `validate.utf16be`, and `validate.utf32`, SIMD validators returning `bool`, each with a `WithErrors` form returning a `Result` with the error kind and position.
- `scalar.validateAscii`, `scalar.validateUtf16le`, `scalar.validateUtf16be`, and `scalar.validateUtf32`, the reference validators.
- `convert` and `length`: SIMD conversion between UTF-8, UTF-16LE, UTF-16BE, UTF-32, and Latin-1, each checked (a `Result` with simdutf's error kind and position) or assuming valid input, with output sizes and code-point counts.

### Changed

- On aarch64, `base64.encode` is 1.7× faster (2.1× from 4 KiB) and `base64.decode` 1.3× (1.4–1.5× from 4 KiB, and 1.3× on MIME line-wrapped input).
- On aarch64, `validate.utf8` and `utf8WithErrors` are 1.7× faster (1.7× on non-ASCII text, up to 2.5× on ASCII), `validate.ascii` and `asciiWithErrors` 1.35–1.45×, the UTF-16 validators 1.2–1.35× (1.7–1.8× on emoji, 1.65× on 16 units), and the UTF-32 validators 1.13×.
- On aarch64, the `convert` functions from UTF-8 to UTF-32 are 1.3–1.5× faster (2.6–4.7× on emoji), UTF-8 to UTF-16 1.2–1.3× (1.9–2.9× on emoji), UTF-16 to UTF-32 1.35–1.45×, UTF-16 and UTF-32 to UTF-8 1.2× (1.6× on Chinese UTF-16), and Latin-1 to UTF-16 1.1× (1.3× at 4–64 KiB).
- On aarch64, the `length` functions are 1.3× faster on geomean: `utf8FromUtf16le` and `utf8FromUtf16be` 1.65×, `countUtf16le` and `countUtf16be` 1.4×, and `countUtf8`, `utf16FromUtf8`, and `utf8FromLatin1` 1.4–1.5× at 16 bytes and 2.5–2.7× at 64.
- On aarch64, the `convert` functions from UTF-8 to UTF-16 are 1.1× faster on non-ASCII text, and `validate.utf16le` 1.3× on emoji.
- `convert` functions with AVX-512 in generic x86-64 builds are 1.05× faster on 16-unit inputs (UTF-32 to UTF-16 and UTF-8 1.25×, UTF-8 to UTF-16, UTF-32, and Latin-1 1.1–1.15×): their short path no longer saves registers for the long one.
- `convert.latin1ToUtf8` and `validLatin1ToUtf8` with AVX-512 are 1.1–1.3× faster on 256 bytes.
- `base64.decode` with AVX-512 is 1.2× faster on inputs under 64 characters.
- `validate.utf8` and `utf8WithErrors` in generic x86-64 builds are 1.2–1.3× faster per call on inputs under 64 bytes.
- `base64.decode` with AVX2 or SSSE3 is 1.1–1.2× faster when the input's last block holds up to 32 characters, as 16–64-byte payloads' do.
- `validate.utf32WithErrors` is 1.5–2.2× faster on 33–64 values, and `validate.asciiWithErrors` with AVX-512 about 10% faster per call on exactly 64 bytes.
- `base64.encode` with AVX-512 is 1.3× faster per call on 16-byte input, and `base64.decode` of unpadded input a multiple of 64 characters long skips an empty last block.
- On Apple Silicon, `convert.utf8ToUtf32` is 1.35× faster on CJK text from 4 KiB, 1.5–1.75× on emoji from 64 bytes, and 1.05–2.75× on other non-ASCII text of 64–256 bytes, and UTF-8 to UTF-16 1.35× on CJK and 2.05–2.15× on emoji from 256 bytes; ASCII calls of 1–8 bytes take up to 1 ns longer.
- On aarch64, `base64.decode` is 2.8× faster on 64 characters, 1.8× on 256, and 1.08–1.13× from 4 KiB (measured on Apple M4), when `dst` is `maxDecodedLen(src.len)` bytes.
- The `length` functions with AVX-512 are 1.1–1.4× faster on inputs of up to 64 bytes.
- Generic x86-64 builds call each dispatched function through a pointer of its own: dispatch costs 0.9 ns a call, from 1.5 ns (simdutf's costs 2.6), and 16–64-byte inputs run 1.07× faster on geomean.
- `base64.decode` on line-wrapped input (MIME and PEM: lines of one length, a multiple of four and at least 64 characters, each followed by the same 1–4 whitespace characters) is 1.3× faster from 4 KiB with AVX-512, 1.9× with AVX2, and 1.5× with SSSE3; with AVX-512 also 15% faster on inputs under 64 characters.
- `base64.encode` with AVX-512 is 1.1–1.5× faster on 64 bytes to 4 KiB.
- The `validate` `WithErrors` functions are 1.1–1.9× faster on inputs of up to 128 bytes that contain an error, and `utf8WithErrors` up to 1.16× on non-ASCII text under 64 bytes.
- `convert` and `length` select their kernels at runtime too in generic x86-64 builds, as `validate.utf8` does; the length functions that only return the input length do not dispatch.
- `convert` and `length` run AVX-512 kernels on CPUs with AVX-512 VBMI2 (Ice Lake and later, Zen 4 and later): from 4 KiB, UTF-8 to UTF-16 is 1.8–3.6× faster on non-Latin text than with the AVX2 kernels, UTF-16 and UTF-32 to UTF-8 1.4–1.7×, UTF-8 to Latin-1 on Latin-1 text 8×, and the checked UTF-16 byte swap on emoji 7×.
- `convert` on AVX2 and SSE: UTF-16 to UTF-8 is 1.4–2.0× faster on CJK, Korean, and Hindi text, and UTF-8 to UTF-16 on non-Latin text 1.4–2.1× on AVX2.
- Functions returning a `Result` (the `validate` `WithErrors` forms, checked `convert` functions, `base64.decode`) are 1.2–2.4× faster on 16–64 byte inputs in generic x86-64 builds, and `validate.asciiWithErrors`, `utf8WithErrors`, and `utf32WithErrors` up to 2.4× in native builds: the result no longer goes through a stack copy.
- `convert.utf16leToLatin1`, `utf16beToLatin1`, and their `valid` forms on AVX2 and SSE: the last 1–31 code units of inputs from 16 units on no longer go through scalar code: 2.1–2.4× faster at 16 units on AVX2 (1.3× for the `valid` forms).
- `convert` on AVX2: UTF-16 to UTF-8 is 1.3× faster on Korean and Hindi text and 1.35–1.45× on Cyrillic and Hebrew, UTF-32 to UTF-8 1.1–1.3×, and Latin-1 to UTF-8 1.2×; on SSE, UTF-16 and UTF-32 to UTF-8 1.1× and Latin-1 to UTF-8 1.1×.
- `convert.utf16leToUtf16be` and `utf16beToUtf16le` are 1.3× faster on AVX2 and SSE and 1.1× on AVX-512, and 0.7–0.9× as fast on emoji, where every block holds a surrogate pair.
- `convert` on AVX-512: UTF-16 to UTF-8 on two-byte scripts and CJK 1.1–1.35× faster, UTF-32 to UTF-16 1.06–1.23×, UTF-32 and UTF-16 to Latin-1 from inputs not aligned to 16 bytes up to 1.5×, and the UTF-8 decoders and Latin-1 to UTF-8 on short ASCII inputs (up to 32 or 64 bytes) 1.1–1.6×.
- `length.utf8FromUtf16le`, `utf8FromUtf16be`, and `utf8FromUtf32` are 1.1–1.2× faster on AVX2 and SSE.
- `convert` on AVX-512: `validUtf16leToUtf16be` and `validUtf16beToUtf16le` are 1.3× faster at 256 bytes and 1.7× at 4 KiB, the checked byte swaps 1.2–1.5× on text without surrogate pairs, `utf8ToLatin1` and `validUtf8ToLatin1` 1.1–1.4× on Latin-1 text, and `latin1ToUtf8` and `validLatin1ToUtf8` 1.2× on Latin-1 text from 4 KiB and on inputs up to 64 bytes.
- `convert` on AVX2: UTF-8 to UTF-16, UTF-32, and Latin-1, and UTF-16 to UTF-32, are 1.2–1.6× faster on ASCII runs of a few KiB; on SSE, UTF-8 to Latin-1 1.3–1.5× on them, and Latin-1 to UTF-16 1.1× (1.4× at 4 KiB).

### Fixed

- With Zig 0.17, builds for a generic x86-64 CPU (`-Dcpu=baseline`, an x86-64 level, or a cross target with no CPU given) failed to compile their SSE, AVX2, and AVX-512 kernels, and builds with AVX-512 VBMI2 failed in LLVM's verifier; on x86-64 Windows (`x86_64-windows-gnu` and `x86_64-windows-msvc`) every build with those kernels failed with "Intrinsic has incorrect argument type!". They now build.
- Generic x86-64 builds, which select kernels at runtime, linked the AVX-512, AVX2, and SSE kernels of every function and, in ReleaseFast and ReleaseSmall, std's panic handler, whatever the program called; they now link only the kernels of the functions it calls (in every mode but Debug). A shared library calling `convert.utf8ToUtf32`, `length.countUtf8`, and `base64.decode` is 351 KB stripped in ReleaseFast, from 937 KB.
- `base64.decode` in place (`dst` starting at `src.ptr`) returned wrong bytes or a spurious error on input with ASCII whitespace, such as base64 wrapped at 76 columns; it now returns what decoding into a separate buffer does, and its documentation says `dst` may start where `src` does.
- On AVX-512, the `validate` functions took about 100–140 ns on inputs under 64 bytes that end within 63 bytes of a page followed by an unmapped or never-written page; they take 4–7 ns, as elsewhere.
