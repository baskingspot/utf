# Changelog

All notable changes to utf are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `base64.encode`, `base64.decode`, `base64.encodedLen`, and `base64.maxDecodedLen`: SIMD base64 with the standard and URL-safe alphabets, optional padding, ASCII whitespace skipped on decode, the `loose`, `strict`, and `stop_before_partial` last-chunk rules, and simdutf's error kinds and positions.
