//! Scalar base64, one character at a time: the reference every SIMD path in
//! `base64.zig` must match, result and error position included. Decoding
//! follows WHATWG forgiving-base64 and the TC39 `Uint8Array.fromBase64`
//! last-chunk rules, with simdutf's `base64_to_binary` error kinds and
//! positions.

const std = @import("std");
const testing = std.testing;
const result = @import("result.zig");
const Result = result.Result;

pub const Alphabet = enum {
    /// RFC 4648 section 4: `+` and `/`.
    standard,
    /// RFC 4648 section 5: `-` and `_`.
    url,

    pub fn chars(alphabet: Alphabet) *const [64]u8 {
        return switch (alphabet) {
            .standard => "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/",
            .url => "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_",
        };
    }
};

/// What decoding does with a last chunk of two or three characters, as the
/// TC39 `lastChunkHandling` option does.
pub const LastChunk = enum {
    /// Decode it, padded or not, and ignore nonzero bits past the last byte.
    loose,
    /// Require it to be padded to four characters with `=`, and reject
    /// nonzero bits past the last byte.
    strict,
    /// Leave an unpadded partial chunk undecoded, without an error.
    stop_before_partial,
};

pub const EncodeOptions = struct {
    alphabet: Alphabet = .standard,
    /// Pad the output with `=` to a multiple of four characters.
    padding: bool = true,
};

pub const DecodeOptions = struct {
    alphabet: Alphabet = .standard,
    last_chunk: LastChunk = .loose,
};

/// The number of characters `encode` writes for `n` bytes.
pub fn encodedLen(n: usize, options: EncodeOptions) usize {
    const tail = n % 3;
    if (tail == 0) return n / 3 * 4;
    return n / 3 * 4 + if (options.padding) 4 else tail + 1;
}

/// The most bytes `decode` can write for `n` input characters, whatever
/// they are.
pub fn maxDecodedLen(n: usize) usize {
    const tail = n % 4;
    return n / 4 * 3 + if (tail > 1) tail - 1 else 0;
}

/// Encodes `src` into `dst` and returns the number of characters written,
/// `encodedLen(src.len, options)`. `dst` must hold that many.
pub fn encode(dst: []u8, src: []const u8, options: EncodeOptions) usize {
    std.debug.assert(dst.len >= encodedLen(src.len, options));
    return encodeChars(dst, src, options.alphabet.chars(), options.padding);
}

/// `encode` with the alphabet's characters and the padding flag apart:
/// SIMD paths inline it, and LLVM keeps an options struct inlined into
/// them in memory.
pub inline fn encodeChars(dst: []u8, src: []const u8, table: *const [64]u8, padding: bool) usize {
    var i: usize = 0;
    var o: usize = 0;
    while (i + 3 <= src.len) : (i += 3) {
        const w = @as(u32, src[i]) << 16 | @as(u32, src[i + 1]) << 8 | src[i + 2];
        dst[o..][0..4].* = .{ table[w >> 18], table[w >> 12 & 63], table[w >> 6 & 63], table[w & 63] };
        o += 4;
    }
    const rest = src[i..];
    switch (rest.len) {
        0 => return o,
        1 => {
            dst[o] = table[rest[0] >> 2];
            dst[o + 1] = table[rest[0] << 4 & 63];
            if (!padding) return o + 2;
            dst[o + 2 ..][0..2].* = "==".*;
        },
        2 => {
            dst[o] = table[rest[0] >> 2];
            dst[o + 1] = table[(rest[0] << 4 | rest[1] >> 4) & 63];
            dst[o + 2] = table[rest[1] << 2 & 63];
            if (!padding) return o + 3;
            dst[o + 3] = '=';
        },
        else => unreachable,
    }
    return o + 4;
}

/// A character's 6-bit value, or `space` or `invalid`.
pub const space: u8 = 0x40;
pub const invalid: u8 = 0x80;

/// The decoding table: each byte's value, `space` for the ASCII whitespace
/// WHATWG's forgiving-base64 skips (tab, LF, FF, CR, space), and `invalid`
/// for everything else, `=` included.
pub fn decodeTable(alphabet: Alphabet) *const [256]u8 {
    return switch (alphabet) {
        inline else => |a| comptime &makeDecodeTable(a),
    };
}

fn makeDecodeTable(alphabet: Alphabet) [256]u8 {
    var t: [256]u8 = @splat(invalid);
    for (alphabet.chars(), 0..) |c, v| t[c] = v;
    for ("\t\n\x0c\r ") |c| t[c] = space;
    return t;
}

fn quadTables(alphabet: Alphabet) *const [4][256]u32 {
    return switch (alphabet) {
        inline else => |a| comptime &makeQuadTables(a),
    };
}

fn makeQuadTables(alphabet: Alphabet) [4][256]u32 {
    @setEvalBranchQuota(10000);
    const values = makeDecodeTable(alphabet);
    var t: [4][256]u32 = undefined;
    for (0..256) |c| {
        const v: u32 = values[c];
        if (v >= 64) {
            for (&t) |*tk| tk[c] = 1 << 24;
            continue;
        }
        // Little-endian: the first byte is the low one.
        t[0][c] = v << 2;
        t[1][c] = v >> 4 | (v & 0xf) << 12;
        t[2][c] = v >> 2 << 8 | (v & 0x3) << 22;
        t[3][c] = v << 16;
    }
    return t;
}

pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\x0c' or c == '\r';
}

/// Where the encoded data ends: the input with trailing whitespace and up to
/// two trailing `=` (with whitespace between them) cut off, as simdutf cuts
/// them. A `=` left inside `src[0..len]` is an invalid character. `pad` is
/// the index of the first `=` cut off, or `len` without padding.
pub const Trim = struct { len: usize, pad: usize, padding: u2 };

pub fn trim(src: []const u8) Trim {
    var len = src.len;
    while (len > 0 and isSpace(src[len - 1])) len -= 1;
    if (len == 0 or src[len - 1] != '=') return .{ .len = len, .pad = len, .padding = 0 };
    var pad = len - 1;
    len = pad;
    while (len > 0 and isSpace(src[len - 1])) len -= 1;
    if (len == 0 or src[len - 1] != '=') return .{ .len = len, .pad = pad, .padding = 1 };
    pad = len - 1;
    return .{ .len = pad, .pad = pad, .padding = 2 };
}

/// Decodes base64 `src` into `dst`, skipping ASCII whitespace.
///
/// On success `count` is the number of bytes written. On failure it is a
/// position in `src`: for `invalid_base64_character`, the offending
/// character, which includes a misplaced `=` and the first of trailing
/// padding that does not fit the last chunk; for `base64_input_remainder`
/// and `base64_extra_bits`, the end of the encoded data, before any trailing
/// padding and whitespace; for `output_buffer_too_small`, the first character
/// of the chunk that does not fit, where decoding can resume. `dst` needs at
/// most `maxDecodedLen(src.len)` bytes. On failure the contents of `dst` are
/// unspecified.
pub fn decode(dst: []u8, src: []const u8, options: DecodeOptions) Result {
    return decodeFrom(dst, src, trim(src), 0, 0, options);
}

/// Decodes `src[i..t.len]` into `dst[o..]` and finishes the input, where
/// `t` is `trim(src)` and `i` starts a chunk: the characters before it, less
/// whitespace, are a multiple of four and already decoded into `dst[0..o]`.
/// SIMD paths call it for the part of the input they leave.
pub fn decodeFrom(dst: []u8, src: []const u8, t: Trim, start: usize, out: usize, options: DecodeOptions) Result {
    const table = decodeTable(options.alphabet);
    const quad = quadTables(options.alphabet);
    var o = out;
    var chunk: u32 = 0;
    var n: u3 = 0;
    var chunk_start: usize = start;
    var i = start;
    chunks: while (true) {
        // Four alphabet characters at a chunk boundary: the common case,
        // with a table for each position that puts the character's bits
        // where they go in the three bytes, and flags the rest in a fourth.
        while (t.len - i >= 4) : (i += 4) {
            const w = quad[0][src[i]] | quad[1][src[i + 1]] | quad[2][src[i + 2]] | quad[3][src[i + 3]];
            if (w >> 24 != 0) break;
            if (dst.len - o < 3) return .fail(.output_buffer_too_small, i);
            std.mem.writeInt(u24, dst[o..][0..3], @truncate(w), .little);
            o += 3;
        }
        // Otherwise one character at a time, to the end of the chunk.
        while (i < t.len) {
            const v = table[src[i]];
            i += 1;
            if (v == space) continue;
            if (v == invalid) return .fail(.invalid_base64_character, i - 1);
            if (n == 0) chunk_start = i - 1;
            chunk = chunk << 6 | v;
            n += 1;
            if (n == 4) {
                if (dst.len - o < 3) return .fail(.output_buffer_too_small, chunk_start);
                dst[o..][0..3].* = .{ @truncate(chunk >> 16), @truncate(chunk >> 8), @truncate(chunk) };
                o += 3;
                chunk = 0;
                n = 0;
                continue :chunks;
            }
        }
        break;
    }

    const end = t.len;
    const last = options.last_chunk;
    if (n == 1) {
        if (last == .stop_before_partial and t.padding == 0) return .ok(o);
        return .fail(.base64_input_remainder, end);
    }
    if (t.padding == 0) {
        if (n == 0 or last == .stop_before_partial) return .ok(o);
        if (last == .strict) return .fail(.base64_input_remainder, end);
    } else if (n == 0 or @as(u3, t.padding) + n != 4) {
        // Padding after a whole chunk, too much padding, or one `=` after
        // two characters, which only stop_before_partial forgives and
        // strict calls a remainder.
        if (n == 2 and last == .stop_before_partial) return .ok(o);
        if (n == 2 and last == .strict) return .fail(.base64_input_remainder, t.pad);
        return .fail(.invalid_base64_character, t.pad);
    }

    // A partial chunk of two or three characters, padded or not.
    // Two characters carry one byte and 4 extra bits, three carry two bytes
    // and 2 extra bits.
    const bytes: usize = n - 1;
    const extra: u32 = if (n == 2) chunk & 0xf else chunk & 0x3;
    if (t.padding != 0 and last == .strict and extra != 0) return .fail(.base64_extra_bits, end);
    if (dst.len - o < bytes) return .fail(.output_buffer_too_small, chunk_start);
    const w = chunk << (24 - 6 * @as(u5, n));
    dst[o] = @truncate(w >> 16);
    if (bytes == 2) dst[o + 1] = @truncate(w >> 8);
    return .ok(o + bytes);
}

fn expectDecode(src: []const u8, options: DecodeOptions, expected: Result, bytes: []const u8) !void {
    var buf: [64]u8 = undefined;
    const r = decode(&buf, src, options);
    try testing.expectEqual(expected, r);
    if (r.err == .none) try testing.expectEqualSlices(u8, bytes, buf[0..r.count]);
}

test "encode and decode RFC 4648's test vectors" {
    const vectors = [_][2][]const u8{
        .{ "", "" },
        .{ "f", "Zg==" },
        .{ "fo", "Zm8=" },
        .{ "foo", "Zm9v" },
        .{ "foob", "Zm9vYg==" },
        .{ "fooba", "Zm9vYmE=" },
        .{ "foobar", "Zm9vYmFy" },
    };
    for (vectors) |v| {
        var buf: [16]u8 = undefined;
        try testing.expectEqualStrings(v[1], buf[0..encode(&buf, v[0], .{})]);
        const unpadded = std.mem.trimEnd(u8, v[1], "=");
        try testing.expectEqualStrings(unpadded, buf[0..encode(&buf, v[0], .{ .padding = false })]);
        for ([_]LastChunk{ .loose, .strict, .stop_before_partial }) |last| {
            try expectDecode(v[1], .{ .last_chunk = last }, .ok(v[0].len), v[0]);
        }
        try expectDecode(unpadded, .{}, .ok(v[0].len), v[0]);
    }
}

test "the URL alphabet swaps + and / for - and _" {
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("-_-_", buf[0..encode(&buf, "\xfb\xff\xbf", .{ .alphabet = .url })]);
    try testing.expectEqualStrings("+/+/", buf[0..encode(&buf, "\xfb\xff\xbf", .{})]);
    try expectDecode("-_-_", .{ .alphabet = .url }, .ok(3), "\xfb\xff\xbf");
    try expectDecode("+/+/", .{ .alphabet = .url }, .fail(.invalid_base64_character, 0), "");
    try expectDecode("-_-_", .{}, .fail(.invalid_base64_character, 0), "");
}

// Expected results from simdutf 9.2.1's base64_to_binary.
test "decode reports simdutf's error kinds and positions" {
    const loose: DecodeOptions = .{};
    const strict: DecodeOptions = .{ .last_chunk = .strict };
    const partial: DecodeOptions = .{ .last_chunk = .stop_before_partial };
    const cases = [_]struct { []const u8, DecodeOptions, Result, []const u8 }{
        .{ "   ", loose, .ok(0), "" },
        .{ "A", loose, .fail(.base64_input_remainder, 1), "" },
        .{ "ABCDE", loose, .fail(.base64_input_remainder, 5), "" },
        .{ "ZXhhZ ", loose, .fail(.base64_input_remainder, 5), "" },
        .{ "A==", loose, .fail(.base64_input_remainder, 1), "" },
        .{ "AB=", loose, .fail(.invalid_base64_character, 2), "" },
        .{ "ABC==", loose, .fail(.invalid_base64_character, 3), "" },
        .{ "AB===", loose, .fail(.invalid_base64_character, 2), "" },
        .{ "=", loose, .fail(.invalid_base64_character, 0), "" },
        .{ "AB==A", loose, .fail(.invalid_base64_character, 2), "" },
        .{ "ABCD=", loose, .fail(.invalid_base64_character, 4), "" },
        .{ "Zg==  *", loose, .fail(.invalid_base64_character, 2), "" },
        .{ "A\x80", loose, .fail(.invalid_base64_character, 1), "" },
        .{ "AB\x0b", loose, .fail(.invalid_base64_character, 2), "" },
        .{ "AB = = ", loose, .ok(1), "\x00" },
        .{ "ZXhhZh==", loose, .ok(4), "exaf" },
        .{ "ZXhhZh", loose, .ok(4), "exaf" },
        .{ "ZX\thh\nZ\x0cg\r", loose, .ok(4), "exaf" },
        .{ "AB", strict, .fail(.base64_input_remainder, 2), "" },
        .{ "ZXhh Zg", strict, .fail(.base64_input_remainder, 7), "" },
        .{ "AB=", strict, .fail(.base64_input_remainder, 2), "" },
        .{ "ABC==", strict, .fail(.invalid_base64_character, 3), "" },
        .{ " AB==  ", strict, .fail(.base64_extra_bits, 3), "" },
        .{ "ABCD AB==", strict, .fail(.base64_extra_bits, 7), "" },
        .{ "ZXhhZhA=", strict, .ok(5), "exaf\x10" },
        .{ "ZXhhZhB=", strict, .fail(.base64_extra_bits, 7), "" },
        .{ "ZXhhZ", partial, .ok(3), "exa" },
        .{ "ZXhh Zg", partial, .ok(3), "exa" },
        .{ "AB=", partial, .ok(0), "" },
        .{ "ZXhhZ=", partial, .fail(.base64_input_remainder, 5), "" },
        .{ "ABC==", partial, .fail(.invalid_base64_character, 3), "" },
        .{ "ZXhhZh==", partial, .ok(4), "exaf" },
    };
    for (cases) |c| try expectDecode(c[0], c[1], c[2], c[3]);
}

test "decode stops at the first chunk that does not fit" {
    var buf: [5]u8 = undefined;
    try testing.expectEqual(Result.fail(.output_buffer_too_small, 5), decode(buf[0..3], "Zm9v Zm9v", .{}));
    try testing.expectEqual(Result.fail(.output_buffer_too_small, 4), decode(buf[0..4], "Zm9vZm8=", .{}));
    try testing.expectEqual(Result.ok(5), decode(buf[0..5], "Zm9vZm8=", .{}));
}

test "length functions bound what encode and decode write" {
    const zeros: [64]u8 = @splat(0);
    const as: [64]u8 = @splat('A');
    var buf: [64]u8 = undefined;
    for (0..48) |n| {
        try testing.expectEqual((n + 2) / 3 * 4, encodedLen(n, .{}));
        try testing.expectEqual((n * 4 + 2) / 3, encodedLen(n, .{ .padding = false }));
        try testing.expectEqual(encodedLen(n, .{}), encode(&buf, zeros[0..n], .{}));
        // The input of n characters that decodes longest has no padding or
        // space, and a lone last character is an error.
        if (n % 4 == 1) {
            try testing.expectEqual(maxDecodedLen(n - 1), maxDecodedLen(n));
        } else {
            try testing.expectEqual(Result.ok(maxDecodedLen(n)), decode(&buf, as[0..n], .{}));
        }
    }
}
