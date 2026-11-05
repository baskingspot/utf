+++
title = "utf"
+++

SIMD Unicode validation and transcoding, plus base64, in Zig with no C.

simdutf is the C++ library for this job, and it earned its place. This package
does the same job in Zig: validate UTF-8, ASCII, UTF-16LE/BE, and UTF-32;
convert between any two of UTF-8, UTF-16LE/BE, UTF-32, and Latin-1; size the
output; and encode or decode base64. Nothing allocates. Every function takes the
buffers it needs, and a length function says how big the output must be.

On a generic x86-64 build the AVX-512, AVX2, and SSE kernels are picked at run
time. A native or named CPU picks at compile time. On aarch64 the NEON kernels
are picked at compile time.

- [Validating text](#validating-text): `validate.utf8`, `ascii`, `utf16le`, `utf16be`, and `utf32` return a `bool`, and each `WithErrors` form returns a `Result` with the error kind and its position.
- [Transcoding](#transcoding): `convert` has a checked form that validates as it writes and a `valid` form for input already known to be well-formed, for every pair of UTF-8, UTF-16LE/BE, UTF-32, and Latin-1.
- [Counting and sizing](#counting-and-sizing): `length` gives the output size each conversion needs and the code points in an input, without writing anything.
- [Base64](#base64): `base64.encode` and `decode` with the standard or URL alphabet, optional padding, three last-chunk rules, and ASCII whitespace skipped on decode.
- [Limits](#limits): whole buffers, no C ABI, native-order UTF-32, and the base64 behaviors that are deliberate.

The [API reference](api/) documents every public symbol.

# Getting started

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

## Import it

```zig
const utf = @import("utf");
```

`utf` does not collide with a std namespace. `std.unicode` keeps its name.

## Read the examples

[`docs/examples/root.zig`](https://github.com/baskingspot/utf/blob/main/docs/examples/root.zig)
is the code this guide shows, compiled against the public module and run by
`just test`.

## How it picks a kernel

A build for a generic x86-64 CPU (`-Dcpu=baseline`, `x86_64_v2`, `x86_64_v3`,
or a cross target with no CPU given) compiles the package once per ISA tier
above the target and picks the best one on the first call with `cpuid` and XCR0. A native or named CPU selects at compile time instead. `-Ddispatch=false`,
or `.dispatch = false` in the dependency's arguments, turns dispatch off.

On aarch64, NEON has no runtime choice to make.

# Validating text

One validator per encoding. Each takes a slice and returns a `bool`.

| Function           | Input         | Accepts                                   |
| ------------------ | ------------- | ----------------------------------------- |
| `validate.utf8`    | `[]const u8`  | well-formed UTF-8                         |
| `validate.ascii`   | `[]const u8`  | every byte below `0x80`                   |
| `validate.utf16le` | `[]const u16` | well-formed UTF-16 in little-endian bytes |
| `validate.utf16be` | `[]const u16` | well-formed UTF-16 in big-endian bytes    |
| `validate.utf32`   | `[]const u32` | Unicode scalar values in native order     |

## Ask whether it is valid

```zig
if (!utf.validate.utf8(input)) return error.InvalidUtf8;
```

The answer is the scalar validator's, in `utf.scalar`. Every SIMD path is
tested against it, error kind and position included.

## Ask why it failed

The `WithErrors` form returns a `Result` instead of a `bool`.

```zig
const result = utf.validate.utf8WithErrors(input);
if (result.err != .none) {
    std.log.err("UTF-8 error {s} at byte {d}", .{ @tagName(result.err), result.count });
}
```

On success `count` is the number of code units validated. On failure it is the
position of the first bad one:

- UTF-8: the first byte of the ill-formed sequence.
- ASCII: the first byte above `0x7F`.
- UTF-16: the index of the unpaired surrogate.
- UTF-32: the index of the first value above U+10FFFF or in the surrogate range.

`Result` is a plain struct, not an error union, so it is checked with `if`, not
`try` or `catch`.

## The error kinds

- `header_bits`: a UTF-8 byte of the form `11111xxx`.
- `too_short`: a sequence that ends before its continuation bytes do.
- `too_long`: a continuation byte where none was expected.
- `overlong`: a sequence longer than the shortest one for its code point.
- `too_large`: a code point above U+10FFFF, or a Latin-1 output character above U+00FF.
- `surrogate`: a surrogate in UTF-8 or UTF-32, or an unpaired surrogate in UTF-16.
- `not_ascii`: a byte above `0x7F` in ASCII.
- `output_buffer_too_small`: the destination cannot hold the result. Only the conversions and base64 return it.

The base64 error kinds are in [Base64](#base64).

## UTF-16 byte order is the bytes, not the values

`[]const u16` is a view of memory, and `utf16le` and `utf16be` name the order
those bytes are in, as simdutf's `char16_t` functions do. On a little-endian
machine, a big-endian stream read into a byte buffer is a `[]const u16` with
every value swapped, and `utf16be` swaps it back. Do not decode the units to
native values first: that throws away the order the name is asking about.

UTF-32 is native order. There is no `utf32be`.

# Transcoding

`convert` has two forms for every pair of encodings.

- The checked form, `utf8ToUtf16le`, validates as it converts and returns a `ConvertResult`.
- The valid form, `validUtf8ToUtf16le`, assumes well-formed input and a destination the length function sized, and returns the number of code units written.

The names read source, then destination. Every pair among UTF-8, UTF-16LE,
UTF-16BE, UTF-32, and Latin-1 is there, except Latin-1 to itself.

## Size the output first

Every conversion needs a destination buffer. The `length` functions say how
big it must be:

```zig
const source = "Héllo, 世界";
const units = utf.length.utf16FromUtf8(source);

var buffer: [64]u16 = undefined;
const result = utf.convert.utf8ToUtf16le(source, buffer[0..units]);
if (result.err != .none) return error.InvalidUtf8;
```

On success `result.count` is the number of code units written. A buffer sized
by the matching length function always fits, even when the input turns out to
be invalid. If the destination is smaller, the checked form fails with
`output_buffer_too_small` at the first character that does not fit, and the
destination holds everything before it.

## The checked form names what failed

```zig
const units = [_]u16{ 'A', 0xE9, 0xD800, 'B' };
var buffer: [8]u8 = undefined;

const result = utf.convert.utf16leToUtf8(&units, &buffer);
// result.err is .surrogate, result.count is 2, and result.written is 3.
```

The error kinds and positions are the validators' own. One difference: a
conversion can also fail because the output ran out.

## Pick up where it stopped

`ConvertResult` has the `err` and `count` of a `Result`, and `written`: the
code units of output written. On success that is `count` again. On failure
the destination holds the conversion of everything before the error, and
`written` says how long it is, so a decoder that replaces a bad character and
carries on starts again at input `count` and output `written`, with no second
pass to measure the part that converted. In the example above, `buffer[0..3]`
is "Aé" in UTF-8.

## The valid form skips the checks

Use it when the input already passed a validator, or came from a source that
guarantees it. It returns a `usize` and never fails.

```zig
const written = utf.convert.validUtf8ToUtf16le(source, buffer[0..units]);
```

It assumes the destination is large enough. Size it with the length function.

## Latin-1 is 256 characters

Every byte is a code point from U+0000 to U+00FF. Conversion from Latin-1
cannot fail except on the output size. Conversion to Latin-1 fails with
`too_large` for any character above U+00FF, including every emoji.

It is ISO-8859-1, not Windows-1252: bytes `0x80` to `0x9F` become control
characters, not quotation marks or dashes.

## Byte order

`utf16le` and `utf16be` work the same way here as in the validators. Pass the
bytes as `[]u16` and pick the name for the order they are in. UTF-32 is native
order, and a big-endian UTF-32 stream needs its values swapped before it gets
here.

## Text staged through UTF-16

`bmpToUtf8` and `utf8ToBmp` are for UTF-16 that holds only characters below
U+10000, with no surrogates, in the machine's byte order: a single-byte
decoder that looks bytes up as UTF-16 and then wants UTF-8, or an encoder that
reads UTF-8 into UTF-16 to look characters up. With no surrogate pairs, their
kernels are smaller than the general converters'.

Both return a `BmpResult`: the input code units `read` and the output code
units `written`. `bmpToUtf8` writes as many whole characters as fit, and
trusts the caller that there is no surrogate. `utf8ToBmp` stops at the first
four-byte sequence, at the first ill-formed one, and where the output is full,
so the caller decodes what stopped it its own way and goes on from `read`:

```zig
var units: [8]u16 = undefined;
const result = utf.convert.utf8ToBmp("Aé😀B", &units);
// result.read is 3 and result.written is 2: the emoji is four bytes.
```

# Counting and sizing

`length` answers two questions without writing anything: how many code units a
conversion needs, and how many code points an input holds.

## Size a conversion

The name is destination, then source:

- `utf16FromUtf8`, `utf32FromUtf8`, `utf8FromUtf16le`, `utf8FromUtf32`.
- `latin1FromUtf8`, `latin1FromUtf16`, `latin1FromUtf32`.
- `utf16FromLatin1`, `utf32FromLatin1`, `utf8FromLatin1`.

```zig
const units = utf.length.utf16FromUtf8(source);
```

Every function is defined on any input, valid or not, and returns exactly what
the scalar reference returns. That is why a buffer sized by one always fits
the matching checked conversion.

## Count code points

```zig
const points = utf.length.countUtf8("aé日");         // 3
const units = [_]u16{ 0x61, 0xD83D, 0xDE00, 0x7A };
const same = utf.length.countUtf16le(&units);       // 3, because the pair is one
```

`countUtf8`, `countUtf16le`, and `countUtf16be` count code points, so a
surrogate pair counts once. `countUtf32` does not exist: each `u32` is one code point.

# Base64

`utf.base64` encodes and decodes with the standard alphabet (`+` and `/`) or
the URL alphabet (`-` and `_`).

## Encode

```zig
var buffer: [16]u8 = undefined;
const characters = utf.base64.encode(&buffer, "hello", .{});
// buffer[0..characters] is "aGVsbG8=".
```

`encodedLen(n, options)` gives the buffer size for `n` bytes. `EncodeOptions`
has two fields:

- `alphabet`: `.standard` or `.url`.
- `padding`: `true` by default. With `false`, the last chunk is two or three characters instead of four.

```zig
const characters = utf.base64.encode(&buffer, "\xFB\xFF", .{
    .alphabet = .url,
    .padding = false,
});
// "-_8"
```

## Decode

```zig
var buffer: [8]u8 = undefined;
const result = utf.base64.decode(&buffer, "aGVsbG8=", .{});
if (result.err != .none) return error.InvalidBase64;
// buffer[0..result.count] is "hello".
```

Size the destination with `maxDecodedLen(n)`, the most bytes `n` input
characters can produce. On success `count` is the number of bytes written.

`DecodeOptions` has two fields: `alphabet` and `last_chunk`.

## Whitespace is skipped

`decode` skips tab, line feed, form feed, carriage return, and space, wherever
they appear. That matches WHATWG's forgiving base64 and simdutf's behavior, so a MIME or
PEM body wrapped at 76 columns decodes without preprocessing.

No option rejects whitespace. A decoder that must reject it needs its own
scan first.

## The last chunk

`last_chunk` decides what happens to two or three characters at the end that
are not padded to four:

- `.loose`: decode them, padded or not, and ignore the extra bits in the padding position. This is the default.
- `.strict`: require padding to four characters, and reject those bits when they are nonzero.
- `.stop_before_partial`: leave an unpadded partial chunk undecoded, with no error.

```zig
const strict = utf.base64.decode(&buffer, "aGVsbG8", .{ .last_chunk = .strict });
// strict.err is .base64_input_remainder, and strict.count is 7.
```

## What a failure reports

- `invalid_base64_character`: the offending character's position. A misplaced `=` counts.
- `base64_input_remainder`: the end of the encoded data, when the last chunk cannot be decoded under the options.
- `base64_extra_bits`: the end of the encoded data, when the last chunk has nonzero bits past the last byte and the rule rejects them.
- `output_buffer_too_small`: the first character of the chunk that did not fit, where decoding can resume with more room.

On failure the contents of the destination are unspecified.

## Decode in place

The destination may start where the source does:

```zig
var buffer: [8]u8 = "aGVsbG8=".*;
const result = utf.base64.decode(&buffer, buffer[0..], .{});
```

The result is the same as decoding into a separate buffer. On failure the
source is unspecified too. Otherwise the two buffers must not overlap. There
is no in-place encode.

# Limits

- Whole buffers. Every function takes an input slice and an output slice; there is no incremental validator or transcoder. A stream implementation has to carry its own tail.
- No C ABI. The package is a Zig module, with no exported C symbols.
- No UTF-32BE. UTF-32 is native order, and a big-endian stream needs a byte swap first.
- Latin-1 only. Conversion to Latin-1 fails above U+00FF, and there is no Windows-1252 mode.
- No in-place conversion. Only `base64.decode` documents overlapping buffers.
- Base64 whitespace is always skipped. There is no strict no-whitespace mode.
- Pre-1.0. A minor release can change the API, and the changelog says what to change.
