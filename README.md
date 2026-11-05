<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/static/logo-dark.svg">
    <img src="docs/static/logo.svg" alt="utf" height="48">
  </picture>
</h1>

SIMD Unicode validation and transcoding, plus base64, in Zig with no C.

simdutf is the C++ library for this job, and it earned its place. This package
does the same job in Zig: validate UTF-8, ASCII, UTF-16LE/BE, and UTF-32;
convert between any two of UTF-8, UTF-16LE/BE, UTF-32, and Latin-1; size the
output; and encode or decode base64. Nothing allocates. You pass the destination, and
a length function says how big it must be.

On a generic x86-64 build the AVX-512, AVX2, and SSE kernels are picked at run
time. A native or named CPU picks at compile time, and aarch64 gets the NEON
kernels.

```zig
const units = utf.length.utf16FromUtf8(input);
const buffer = try gpa.alloc(u16, units);
defer gpa.free(buffer);

const result = utf.convert.utf8ToUtf16le(input, buffer);
if (result.err != .none) return error.InvalidUtf8;
```

Releases are tagged, from v0.1.0. Before 1.0 a minor release can change the API; the changelog says what to change.

## What is in it

- [Validating text](https://baskingspot.dev/utf/#validating-text): `validate.utf8`, `validate.ascii`, `validate.utf16le`, `validate.utf16be`, and `validate.utf32` return a `bool`; the `WithErrors` forms return a `Result` with the error kind and its position.
- [Transcoding](https://baskingspot.dev/utf/#transcoding): `convert` has a checked form that validates as it writes and a `valid` form for input already known to be well-formed, for every pair of UTF-8, UTF-16LE/BE, UTF-32, and Latin-1; `bmpToUtf8` and `utf8ToBmp` convert UTF-16 that holds only characters below U+10000, for text staged through UTF-16.
- [Counting and sizing](https://baskingspot.dev/utf/#counting-and-sizing): `length` gives the output size each conversion needs and the code points in an input, without writing anything.
- [Base64](https://baskingspot.dev/utf/#base64): `base64.encode` and `decode` with the standard or URL alphabet, optional padding, three last-chunk rules, and ASCII whitespace skipped on decode.

Not implemented:

- Streaming: every function takes a whole buffer, and there is no incremental validator or transcoder.
- A C ABI: `utf` is a Zig module, with no exported C symbols.
- UTF-32BE: UTF-32 is native order, and a big-endian stream needs a byte swap first.
- In-place conversion: only `base64.decode` documents overlapping buffers.
- A no-whitespace base64 decoder: `decode` always skips ASCII whitespace, with no option to reject it.
- Windows-1252: conversion to Latin-1 fails above U+00FF, with no code-page mode.

## Install

```sh
zig fetch --save https://baskingspot.dev/utf/v0.2.2.tar.gz
```

Add the module in `build.zig`:

```zig
const utf = b.dependency("utf", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("utf", utf.module("utf"));
```

`utf` builds with Zig 0.16 and 0.17.

## Documentation

- The [guide](https://baskingspot.dev/utf/) covers the validators, the conversions, the length functions, base64, and the limits.
- The [API reference](https://baskingspot.dev/utf/api/) documents every public symbol.
- [`docs/examples/`](docs/examples/) is the code the guide shows, compiled by `just test`.
- [`CHANGELOG.md`](CHANGELOG.md) records the changes since the last tag.
- [`AGENTS.md`](AGENTS.md) has the working notes for the repository.

## Work on it

```sh
just ci
```

`nix develop` provides the toolchain and the site tools. `just` lists the
recipes, and `just ci` runs what CI runs: the tests, lint, and the site build.
`just check-dispatch` adds CI's x86-64 job: the tests and the simdutf oracle
built for the baseline CPU, which picks its kernels at run time.
`just guide` serves the guide with live reload, and `just doc` builds the whole
site into `zig-out/site/utf/`.

The benchmark harness is `just bench-corpus` once, then `just bench-compare`.
It builds every arm, pins them to one core, and writes a table. [`bench/README.md`](bench/README.md)
has the flags and says what each arm does. `just oracle` compares a random run
with simdutf.

## License

MIT. See [`LICENSE`](LICENSE). The logo files in `docs/static/` are
baskingspot marks and are not covered by it. See
[`docs/static/LICENSE`](docs/static/LICENSE).

## How it's made

Built with LLM assistance. [How, in detail](https://github.com/baskingspot/.github/blob/main/docs/AI.md).

<a href="https://github.com/baskingspot"><img src="https://raw.githubusercontent.com/baskingspot/.github/main/brand/assets/badge.svg" alt="baskingspot" height="24"></a>
