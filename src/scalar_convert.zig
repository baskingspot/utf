//! Scalar reference transcoders and length functions, one code point at a
//! time. They define the result of every conversion: each SIMD path in
//! `convert.zig` and `length.zig` returns exactly what its counterpart here
//! returns, error kind and position included, on every input.
//!
//! A checked conversion (`utf8ToUtf16`, ...) validates as it converts and
//! stops at the first ill-formed character, with simdutf's error kind and the
//! index of that character in the input. Before writing a character it checks
//! that the output has room for it, and fails with `output_buffer_too_small`
//! at that character's index when it does not; the output then holds the
//! conversion of everything before it. A buffer sized by the matching length
//! function never fails that way, even on invalid input, because the length
//! functions count every prefix at least as large as it converts.
//!
//! A valid conversion (`validUtf8ToUtf16`, ...) assumes well-formed input and
//! an output buffer the matching length function sized; it returns the number
//! of code units written.
//!
//! UTF-16 functions take the byte order of the code units in memory as a
//! comptime `Endian`, as simdutf's `char16_t` functions do. UTF-32 is native.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Endian = std.lang.Endian;
const result = @import("result.zig");
const Error = result.Error;
const Result = result.Result;

const native = builtin.cpu.arch.endian();

/// A UTF-16 code unit stored in byte order `e`, as a native value, or a
/// native value as one stored in byte order `e`: the same swap both ways.
pub inline fn swap16(comptime e: Endian, unit: u16) u16 {
    return if (e == native) unit else @byteSwap(unit);
}

// One decoded character: its code point and length in code units, or an
// error kind.
const Char = struct {
    cp: u32 = 0,
    len: usize = 0,
    err: Error = .none,
};

/// Decodes the UTF-8 character at `src[i]`, classifying an ill-formed one as
/// `scalar.validateUtf8` and simdutf do.
inline fn decodeUtf8(src: []const u8, i: usize) Char {
    const lead = src[i];
    if (lead < 0x80) return .{ .cp = lead, .len = 1 };
    const len: usize = if (lead & 0xE0 == 0xC0)
        2
    else if (lead & 0xF0 == 0xE0)
        3
    else if (lead & 0xF8 == 0xF0)
        4
    else if (lead & 0xC0 == 0x80)
        return .{ .err = .too_long }
    else
        return .{ .err = .header_bits };
    if (src.len - i < len) return .{ .err = .too_short };
    var cp: u32 = lead & (@as(u8, 0x7F) >> @intCast(len));
    for (src[i + 1 .. i + len]) |b| {
        if (b & 0xC0 != 0x80) return .{ .err = .too_short };
        cp = (cp << 6) | (b & 0x3F);
    }
    switch (len) {
        2 => if (cp < 0x80) return .{ .err = .overlong },
        3 => {
            if (cp < 0x800) return .{ .err = .overlong };
            if (cp >= 0xD800 and cp <= 0xDFFF) return .{ .err = .surrogate };
        },
        else => {
            if (cp <= 0xFFFF) return .{ .err = .overlong };
            if (cp > 0x10FFFF) return .{ .err = .too_large };
        },
    }
    return .{ .cp = cp, .len = len };
}

/// Decodes well-formed UTF-8 at `src[i]` without checking it.
inline fn decodeValidUtf8(src: []const u8, i: usize) Char {
    const lead: u32 = src[i];
    if (lead < 0x80) return .{ .cp = lead, .len = 1 };
    if (lead < 0xE0) return .{ .cp = (lead & 0x1F) << 6 | (src[i + 1] & 0x3F), .len = 2 };
    if (lead < 0xF0) return .{
        .cp = (lead & 0x0F) << 12 | @as(u32, src[i + 1] & 0x3F) << 6 | (src[i + 2] & 0x3F),
        .len = 3,
    };
    return .{
        .cp = (lead & 0x07) << 18 | @as(u32, src[i + 1] & 0x3F) << 12 |
            @as(u32, src[i + 2] & 0x3F) << 6 | (src[i + 3] & 0x3F),
        .len = 4,
    };
}

/// Decodes the UTF-16 character at `src[i]`: an unpaired surrogate is an
/// error at its own index, as simdutf reports it.
inline fn decodeUtf16(comptime e: Endian, src: []const u16, i: usize) Char {
    const w = swap16(e, src[i]);
    if (w & 0xF800 != 0xD800) return .{ .cp = w, .len = 1 };
    if (w >= 0xDC00 or i + 1 >= src.len) return .{ .err = .surrogate };
    const next = swap16(e, src[i + 1]);
    if (next & 0xFC00 != 0xDC00) return .{ .err = .surrogate };
    return .{ .cp = 0x10000 + ((@as(u32, w) - 0xD800) << 10 | (next - 0xDC00)), .len = 2 };
}

inline fn decodeValidUtf16(comptime e: Endian, src: []const u16, i: usize) Char {
    const w = swap16(e, src[i]);
    if (w & 0xF800 != 0xD800) return .{ .cp = w, .len = 1 };
    const next = swap16(e, src[i + 1]);
    return .{ .cp = 0x10000 + ((@as(u32, w) - 0xD800) << 10 | (next - 0xDC00)), .len = 2 };
}

inline fn checkUtf32(cp: u32) Error {
    if (cp > 0x10FFFF) return .too_large;
    if (cp >= 0xD800 and cp <= 0xDFFF) return .surrogate;
    return .none;
}

inline fn utf8Len(cp: u32) usize {
    if (cp < 0x80) return 1;
    if (cp < 0x800) return 2;
    if (cp < 0x10000) return 3;
    return 4;
}

inline fn encodeUtf8(cp: u32, dst: []u8, o: usize) usize {
    if (cp < 0x80) {
        dst[o] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        dst[o] = @intCast(0xC0 | cp >> 6);
        dst[o + 1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        dst[o] = @intCast(0xE0 | cp >> 12);
        dst[o + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        dst[o + 2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
    dst[o] = @intCast(0xF0 | cp >> 18);
    dst[o + 1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
    dst[o + 2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
    dst[o + 3] = @intCast(0x80 | (cp & 0x3F));
    return 4;
}

inline fn encodeUtf16(comptime e: Endian, cp: u32, dst: []u16, o: usize) usize {
    if (cp < 0x10000) {
        dst[o] = swap16(e, @intCast(cp));
        return 1;
    }
    const v = cp - 0x10000;
    dst[o] = swap16(e, @intCast(0xD800 | v >> 10));
    dst[o + 1] = swap16(e, @intCast(0xDC00 | (v & 0x3FF)));
    return 2;
}

// UTF-8 source.

pub fn utf8ToUtf16(comptime e: Endian, src: []const u8, dst: []u16) Result {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len) {
        const c = decodeUtf8(src, i);
        if (c.err != .none) return .fail(c.err, i);
        if (dst.len - o < @as(usize, if (c.cp < 0x10000) 1 else 2)) return .fail(.output_buffer_too_small, i);
        o += encodeUtf16(e, c.cp, dst, o);
        i += c.len;
    }
    return .ok(o);
}

pub fn validUtf8ToUtf16(comptime e: Endian, src: []const u8, dst: []u16) usize {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len) {
        const c = decodeValidUtf8(src, i);
        o += encodeUtf16(e, c.cp, dst, o);
        i += c.len;
    }
    return o;
}

pub fn utf8ToUtf32(src: []const u8, dst: []u32) Result {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len) {
        const c = decodeUtf8(src, i);
        if (c.err != .none) return .fail(c.err, i);
        if (o == dst.len) return .fail(.output_buffer_too_small, i);
        dst[o] = c.cp;
        o += 1;
        i += c.len;
    }
    return .ok(o);
}

pub fn validUtf8ToUtf32(src: []const u8, dst: []u32) usize {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len) {
        const c = decodeValidUtf8(src, i);
        dst[o] = c.cp;
        o += 1;
        i += c.len;
    }
    return o;
}

/// Converts UTF-8 holding only U+0000-U+00FF to Latin-1, classifying errors
/// as simdutf does: a two-byte character above U+00FF, and any three- or
/// four-byte lead, is `too_large` at its first byte, before its continuation
/// bytes are looked at.
pub fn utf8ToLatin1(src: []const u8, dst: []u8) Result {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len) {
        const lead = src[i];
        var len: usize = 1;
        var cp: u8 = lead;
        if (lead >= 0x80) {
            if (lead & 0xE0 == 0xC0) {
                if (i + 1 >= src.len or src[i + 1] & 0xC0 != 0x80) return .fail(.too_short, i);
                if (lead < 0xC2) return .fail(.overlong, i);
                if (lead > 0xC3) return .fail(.too_large, i);
                cp = (lead << 6) | (src[i + 1] & 0x3F);
                len = 2;
            } else if (lead & 0xF0 == 0xE0 or lead & 0xF8 == 0xF0) {
                return .fail(.too_large, i);
            } else if (lead & 0xC0 == 0x80) {
                return .fail(.too_long, i);
            } else {
                return .fail(.header_bits, i);
            }
        }
        if (o == dst.len) return .fail(.output_buffer_too_small, i);
        dst[o] = cp;
        o += 1;
        i += len;
    }
    return .ok(o);
}

pub fn validUtf8ToLatin1(src: []const u8, dst: []u8) usize {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len) {
        const lead = src[i];
        if (lead < 0x80) {
            dst[o] = lead;
            i += 1;
        } else {
            dst[o] = (lead << 6) | (src[i + 1] & 0x3F);
            i += 2;
        }
        o += 1;
    }
    return o;
}

// UTF-16 source.

pub fn utf16ToUtf8(comptime e: Endian, src: []const u16, dst: []u8) Result {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len) {
        const c = decodeUtf16(e, src, i);
        if (c.err != .none) return .fail(c.err, i);
        if (dst.len - o < utf8Len(c.cp)) return .fail(.output_buffer_too_small, i);
        o += encodeUtf8(c.cp, dst, o);
        i += c.len;
    }
    return .ok(o);
}

pub fn validUtf16ToUtf8(comptime e: Endian, src: []const u16, dst: []u8) usize {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len) {
        const c = decodeValidUtf16(e, src, i);
        o += encodeUtf8(c.cp, dst, o);
        i += c.len;
    }
    return o;
}

pub fn utf16ToUtf32(comptime e: Endian, src: []const u16, dst: []u32) Result {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len) {
        const c = decodeUtf16(e, src, i);
        if (c.err != .none) return .fail(c.err, i);
        if (o == dst.len) return .fail(.output_buffer_too_small, i);
        dst[o] = c.cp;
        o += 1;
        i += c.len;
    }
    return .ok(o);
}

pub fn validUtf16ToUtf32(comptime e: Endian, src: []const u16, dst: []u32) usize {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len) {
        const c = decodeValidUtf16(e, src, i);
        dst[o] = c.cp;
        o += 1;
        i += c.len;
    }
    return o;
}

/// Every code unit above 0xFF, surrogates included, is `too_large` at its
/// index, as simdutf reports it.
pub fn utf16ToLatin1(comptime e: Endian, src: []const u16, dst: []u8) Result {
    for (src, 0..) |unit, i| {
        const w = swap16(e, unit);
        if (w > 0xFF) return .fail(.too_large, i);
        if (i == dst.len) return .fail(.output_buffer_too_small, i);
        dst[i] = @intCast(w);
    }
    return .ok(src.len);
}

pub fn validUtf16ToLatin1(comptime e: Endian, src: []const u16, dst: []u8) usize {
    for (src, dst[0..src.len]) |unit, *out| out.* = @truncate(swap16(e, unit));
    return src.len;
}

/// Converts UTF-16 in byte order `e` to the other byte order, failing on an
/// unpaired surrogate as `utf16ToUtf8` does.
pub fn utf16ToUtf16Swapped(comptime e: Endian, src: []const u16, dst: []u16) Result {
    var i: usize = 0;
    while (i < src.len) {
        const c = decodeUtf16(e, src, i);
        if (c.err != .none) return .fail(c.err, i);
        if (dst.len - i < c.len) return .fail(.output_buffer_too_small, i);
        for (src[i..][0..c.len], dst[i..][0..c.len]) |unit, *out| out.* = @byteSwap(unit);
        i += c.len;
    }
    return .ok(src.len);
}

pub fn validUtf16ToUtf16Swapped(src: []const u16, dst: []u16) usize {
    for (src, dst[0..src.len]) |unit, *out| out.* = @byteSwap(unit);
    return src.len;
}

// UTF-32 source.

pub fn utf32ToUtf8(src: []const u32, dst: []u8) Result {
    var o: usize = 0;
    for (src, 0..) |cp, i| {
        const err = checkUtf32(cp);
        if (err != .none) return .fail(err, i);
        if (dst.len - o < utf8Len(cp)) return .fail(.output_buffer_too_small, i);
        o += encodeUtf8(cp, dst, o);
    }
    return .ok(o);
}

pub fn validUtf32ToUtf8(src: []const u32, dst: []u8) usize {
    var o: usize = 0;
    for (src) |cp| o += encodeUtf8(cp, dst, o);
    return o;
}

pub fn utf32ToUtf16(comptime e: Endian, src: []const u32, dst: []u16) Result {
    var o: usize = 0;
    for (src, 0..) |cp, i| {
        const err = checkUtf32(cp);
        if (err != .none) return .fail(err, i);
        if (dst.len - o < @as(usize, if (cp < 0x10000) 1 else 2)) return .fail(.output_buffer_too_small, i);
        o += encodeUtf16(e, cp, dst, o);
    }
    return .ok(o);
}

pub fn validUtf32ToUtf16(comptime e: Endian, src: []const u32, dst: []u16) usize {
    var o: usize = 0;
    for (src) |cp| o += encodeUtf16(e, cp, dst, o);
    return o;
}

/// Every code point above 0xFF is `too_large` at its index.
pub fn utf32ToLatin1(src: []const u32, dst: []u8) Result {
    for (src, 0..) |cp, i| {
        if (cp > 0xFF) return .fail(.too_large, i);
        if (i == dst.len) return .fail(.output_buffer_too_small, i);
        dst[i] = @intCast(cp);
    }
    return .ok(src.len);
}

pub fn validUtf32ToLatin1(src: []const u32, dst: []u8) usize {
    for (src, dst[0..src.len]) |cp, *out| out.* = @truncate(cp);
    return src.len;
}

// Latin-1 source: every byte is a character, so the checked forms can only
// run out of output.

pub fn latin1ToUtf8(src: []const u8, dst: []u8) Result {
    var o: usize = 0;
    for (src, 0..) |b, i| {
        if (dst.len - o < utf8Len(b)) return .fail(.output_buffer_too_small, i);
        o += encodeUtf8(b, dst, o);
    }
    return .ok(o);
}

pub fn validLatin1ToUtf8(src: []const u8, dst: []u8) usize {
    var o: usize = 0;
    for (src) |b| o += encodeUtf8(b, dst, o);
    return o;
}

pub fn latin1ToUtf16(comptime e: Endian, src: []const u8, dst: []u16) Result {
    const n = @min(src.len, dst.len);
    _ = validLatin1ToUtf16(e, src[0..n], dst);
    if (n < src.len) return .fail(.output_buffer_too_small, n);
    return .ok(n);
}

pub fn validLatin1ToUtf16(comptime e: Endian, src: []const u8, dst: []u16) usize {
    for (src, dst[0..src.len]) |b, *out| out.* = swap16(e, b);
    return src.len;
}

pub fn latin1ToUtf32(src: []const u8, dst: []u32) Result {
    const n = @min(src.len, dst.len);
    _ = validLatin1ToUtf32(src[0..n], dst);
    if (n < src.len) return .fail(.output_buffer_too_small, n);
    return .ok(n);
}

pub fn validLatin1ToUtf32(src: []const u8, dst: []u32) usize {
    for (src, dst[0..src.len]) |b, *out| out.* = b;
    return src.len;
}

// Lengths. Each is defined on any input, valid or not, by a per-unit rule
// that matches simdutf's on valid input.

/// Code points in UTF-8: the bytes that are not continuation bytes.
pub fn countUtf8(src: []const u8) usize {
    var n: usize = 0;
    for (src) |b| n += @intFromBool(b & 0xC0 != 0x80);
    return n;
}

/// Code points in UTF-16: the code units that are not low surrogates.
pub fn countUtf16(comptime e: Endian, src: []const u16) usize {
    var n: usize = 0;
    for (src) |unit| n += @intFromBool(swap16(e, unit) & 0xFC00 != 0xDC00);
    return n;
}

/// UTF-16 code units for UTF-8: one per character, two per four-byte one.
pub fn utf16FromUtf8(src: []const u8) usize {
    var n: usize = 0;
    for (src) |b| n += @as(usize, @intFromBool(b & 0xC0 != 0x80)) + @intFromBool(b >= 0xF0);
    return n;
}

/// UTF-8 bytes for UTF-16: every surrogate counts two, so a pair counts
/// four. On unpaired surrogates simdutf disagrees with itself (its SIMD
/// blocks count two, its scalar tail three); this is the per-unit rule.
pub fn utf8FromUtf16(comptime e: Endian, src: []const u16) usize {
    var n: usize = 0;
    for (src) |unit| {
        const w = swap16(e, unit);
        n += if (w < 0x80) 1 else if (w < 0x800 or w & 0xF800 == 0xD800) 2 else 3;
    }
    return n;
}

pub fn utf8FromUtf32(src: []const u32) usize {
    var n: usize = 0;
    for (src) |cp| n += utf8Len(cp);
    return n;
}

pub fn utf16FromUtf32(src: []const u32) usize {
    var n: usize = 0;
    for (src) |cp| n += @as(usize, 1) + @intFromBool(cp > 0xFFFF);
    return n;
}

pub fn utf8FromLatin1(src: []const u8) usize {
    var n: usize = 0;
    for (src) |b| n += @as(usize, 1) + @intFromBool(b >= 0x80);
    return n;
}

test "checked conversions agree with std.unicode on well-formed text" {
    const text = "héllo wörld ✓ 日本語 🎉 \u{0}\u{7f}\u{80}\u{7ff}\u{800}" ++
        "\u{d7ff}\u{e000}\u{ffff}\u{10000}\u{10ffff}";
    var want16: [64]u16 = undefined;
    const n16 = try std.unicode.utf8ToUtf16Le(&want16, text);
    try testing.expectEqual(n16, utf16FromUtf8(text));

    var got16: [64]u16 = undefined;
    try testing.expectEqual(Result.ok(n16), utf8ToUtf16(.little, text, &got16));
    try testing.expectEqualSlices(u16, want16[0..n16], got16[0..n16]);
    try testing.expectEqual(n16, validUtf8ToUtf16(.little, text, &got16));
    try testing.expectEqualSlices(u16, want16[0..n16], got16[0..n16]);

    var be: [64]u16 = undefined;
    try testing.expectEqual(Result.ok(n16), utf8ToUtf16(.big, text, &be));
    for (want16[0..n16], be[0..n16]) |w, b| try testing.expectEqual(w, @byteSwap(b));

    var back: [128]u8 = undefined;
    try testing.expectEqual(text.len, utf8FromUtf16(.big, be[0..n16]));
    try testing.expectEqual(Result.ok(text.len), utf16ToUtf8(.big, be[0..n16], &back));
    try testing.expectEqualStrings(text, back[0..text.len]);

    var cps: [64]u32 = undefined;
    const ncp = try std.unicode.utf8CountCodepoints(text);
    try testing.expectEqual(ncp, countUtf8(text));
    try testing.expectEqual(ncp, countUtf16(.little, want16[0..n16]));
    try testing.expectEqual(Result.ok(ncp), utf8ToUtf32(text, &cps));
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    for (cps[0..ncp]) |cp| try testing.expectEqual(it.nextCodepoint().?, cp);

    var from32: [64]u16 = undefined;
    try testing.expectEqual(n16, utf16FromUtf32(cps[0..ncp]));
    try testing.expectEqual(Result.ok(n16), utf32ToUtf16(.little, cps[0..ncp], &from32));
    try testing.expectEqualSlices(u16, want16[0..n16], from32[0..n16]);
    try testing.expectEqual(text.len, utf8FromUtf32(cps[0..ncp]));
    try testing.expectEqual(Result.ok(text.len), utf32ToUtf8(cps[0..ncp], &back));
    try testing.expectEqualStrings(text, back[0..text.len]);
}

test "Latin-1 round-trips through UTF-8, UTF-16, and UTF-32" {
    var latin: [256]u8 = undefined;
    for (&latin, 0..) |*b, i| b.* = @intCast(i);
    var utf8: [384]u8 = undefined;
    try testing.expectEqual(384, utf8FromLatin1(&latin));
    try testing.expectEqual(Result.ok(384), latin1ToUtf8(&latin, &utf8));
    try testing.expectEqualStrings("\xc3\xbf", utf8[382..384]);
    var back: [256]u8 = undefined;
    try testing.expectEqual(Result.ok(256), utf8ToLatin1(&utf8, &back));
    try testing.expectEqualSlices(u8, &latin, &back);
    try testing.expectEqual(256, validUtf8ToLatin1(&utf8, &back));
    try testing.expectEqualSlices(u8, &latin, &back);

    var u16s: [256]u16 = undefined;
    try testing.expectEqual(Result.ok(256), latin1ToUtf16(.big, &latin, &u16s));
    try testing.expectEqual(Result.ok(256), utf16ToLatin1(.big, &u16s, &back));
    try testing.expectEqualSlices(u8, &latin, &back);
    var u32s: [256]u32 = undefined;
    try testing.expectEqual(Result.ok(256), latin1ToUtf32(&latin, &u32s));
    try testing.expectEqual(Result.ok(256), utf32ToLatin1(&u32s, &back));
    try testing.expectEqualSlices(u8, &latin, &back);
}

test "checked conversions name the first error and where it starts" {
    var out8: [16]u8 = undefined;
    var out16: [16]u16 = undefined;
    var out32: [16]u32 = undefined;
    // UTF-8 errors match scalar.validateUtf8's.
    try testing.expectEqual(Result.fail(.too_short, 2), utf8ToUtf16(.little, "ab\xe2\x82", &out16));
    try testing.expectEqual(Result.fail(.surrogate, 1), utf8ToUtf32("a\xed\xa0\x80", &out32));
    // Latin-1 output: a three-byte lead is too large before it is truncated.
    try testing.expectEqual(Result.fail(.too_large, 1), utf8ToLatin1("a\xe2", &out8));
    try testing.expectEqual(Result.fail(.too_large, 0), utf8ToLatin1("\xc4\x80", &out8));
    try testing.expectEqual(Result.fail(.overlong, 0), utf8ToLatin1("\xc1\xbf", &out8));
    try testing.expectEqual(Result.fail(.too_short, 0), utf8ToLatin1("\xc3", &out8));
    try testing.expectEqual(Result.fail(.too_long, 1), utf8ToLatin1("a\x80", &out8));
    // UTF-16: an unpaired surrogate fails at its own index. The units are
    // native values, so they are read in native byte order.
    const lone_high = [_]u16{ 'a', 0xD800, 'b' };
    const lone_low = [_]u16{ 'a', 'b', 0xDC00 };
    const trailing_high = [_]u16{ 'a', 0xD83D };
    try testing.expectEqual(Result.fail(.surrogate, 1), utf16ToUtf8(native, &lone_high, &out8));
    try testing.expectEqual(Result.fail(.surrogate, 2), utf16ToUtf32(native, &lone_low, &out32));
    try testing.expectEqual(Result.fail(.surrogate, 1), utf16ToUtf16Swapped(native, &trailing_high, &out16));
    try testing.expectEqual(Result.fail(.too_large, 1), utf16ToLatin1(native, &lone_high, &out8));
    // UTF-32.
    const bad32 = [_]u32{ 'a', 0x110000, 0xD800 };
    try testing.expectEqual(Result.fail(.too_large, 1), utf32ToUtf8(&bad32, &out8));
    try testing.expectEqual(Result.fail(.surrogate, 0), utf32ToUtf16(.big, bad32[2..], &out16));
    try testing.expectEqual(Result.fail(.too_large, 1), utf32ToLatin1(&.{ 0xFF, 0x100 }, &out8));
}

test "checked conversions stop at the first character that does not fit" {
    var out8: [3]u8 = undefined;
    var out16: [2]u16 = undefined;
    // "a€" needs four bytes; three hold only "a".
    try testing.expectEqual(Result.fail(.output_buffer_too_small, 1), utf16ToUtf8(native, &.{ 'a', 0x20AC }, &out8));
    const emoji = "a\xf0\x9f\x8e\x89";
    try testing.expectEqual(Result.fail(.output_buffer_too_small, 1), utf8ToUtf16(.little, emoji, &out16));
    // A validation error at the same character wins.
    try testing.expectEqual(Result.fail(.too_short, 1), utf8ToUtf16(.little, "a\xf0\x9f\x8e", &out16));
    try testing.expectEqual(Result.fail(.output_buffer_too_small, 2), latin1ToUtf8("ab\xe9", &out8));
    try testing.expectEqual(Result.fail(.output_buffer_too_small, 2), latin1ToUtf16(.little, "abc", &out16));
}
