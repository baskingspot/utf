# Changelog

All notable changes to utf are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Runtime kernel selection on x86-64: a build for a generic x86-64 CPU (`-Dcpu=baseline`, `x86_64_v2`, `x86_64_v3`, or a cross target with no CPU given) now runs the AVX-512, AVX2, or SSE kernels the CPU has, for every `validate` function, `base64.encode`, and `base64.decode`. The `-Ddispatch` build option (`.dispatch` in `b.dependency` arguments) turns it on or off; a native or named CPU still selects at compile time.
- `base64.encode`, `base64.decode`, `base64.encodedLen`, and `base64.maxDecodedLen`: SIMD base64 with the standard and URL-safe alphabets, optional padding, ASCII whitespace skipped on decode, the `loose`, `strict`, and `stop_before_partial` last-chunk rules, and simdutf's error kinds and positions, with AVX-512 VBMI, AVX2, SSSE3, and NEON kernels.
- `validate.utf8`, `validate.ascii`, `validate.utf16le`, `validate.utf16be`, and `validate.utf32`, SIMD validators returning `bool`, each with a `WithErrors` form returning a `Result` with the error kind and position.
- `scalar.validateAscii`, `scalar.validateUtf16le`, `scalar.validateUtf16be`, and `scalar.validateUtf32`, the reference validators.
- `convert` and `length`: SIMD conversion between UTF-8, UTF-16LE, UTF-16BE, UTF-32, and Latin-1, each checked (a `Result` with simdutf's error kind and position) or assuming valid input, with output sizes and code-point counts.

### Changed

- `convert` and `length` select their kernels at runtime too in generic x86-64 builds, as `validate.utf8` does; the length functions that only return the input length do not dispatch.
