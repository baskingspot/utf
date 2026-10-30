# Changelog

All notable changes to utf are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `base64.encode`, `base64.decode`, `base64.encodedLen`, and `base64.maxDecodedLen`: SIMD base64 with the standard and URL-safe alphabets, optional padding, ASCII whitespace skipped on decode, the `loose`, `strict`, and `stop_before_partial` last-chunk rules, and simdutf's error kinds and positions.
- `validate.utf8`, `validate.ascii`, `validate.utf16le`, `validate.utf16be`, and `validate.utf32`, SIMD validators returning `bool`, each with a `WithErrors` form returning a `Result` with the error kind and position.
- `scalar.validateAscii`, `scalar.validateUtf16le`, `scalar.validateUtf16be`, and `scalar.validateUtf32`, the reference validators.
- `convert` and `length`: SIMD conversion between UTF-8, UTF-16LE, UTF-16BE, UTF-32, and Latin-1, each checked (a `Result` with simdutf's error kind and position) or assuming valid input, with output sizes and code-point counts.
