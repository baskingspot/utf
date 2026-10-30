//! How many code units each conversion writes, and how many code points an
//! input holds. Each function is defined on any input, valid or not, and
//! returns exactly what its counterpart in `scalar_convert.zig` returns; on
//! valid input that is simdutf's answer. An output buffer of the size a
//! length function gives always fits the matching checked conversion, even
//! when the input turns out to be invalid.

const std = @import("std");
const Endian = std.builtin.Endian;
const scalar = @import("scalar_convert.zig");

const native = @import("builtin").cpu.arch.endian();

/// Code points in UTF-8: the bytes that are not continuation bytes.
pub fn countUtf8(src: []const u8) usize {
    const sum, const p = sumBlocks(u8, 1, struct {
        fn f(v: anytype) @TypeOf(v) {
            return ones(u8, notContinuation(v));
        }
    }.f, src);
    return sum + scalar.countUtf8(src[p..]);
}

/// Code points in UTF-16LE: the code units that are not low surrogates.
pub fn countUtf16le(src: []const u16) usize {
    return countUtf16(.little, src);
}

/// Code points in UTF-16BE: the code units that are not low surrogates.
pub fn countUtf16be(src: []const u16) usize {
    return countUtf16(.big, src);
}

/// UTF-16 code units for UTF-8: one per character, two per four-byte one.
pub fn utf16FromUtf8(src: []const u8) usize {
    const sum, const p = sumBlocks(u8, 2, struct {
        fn f(v: anytype) @TypeOf(v) {
            return ones(u8, notContinuation(v)) + ones(u8, v >= @as(@TypeOf(v), @splat(0xF0)));
        }
    }.f, src);
    return sum + scalar.utf16FromUtf8(src[p..]);
}

/// UTF-16 code units for UTF-32: one per code point, two above U+FFFF.
pub fn utf16FromUtf32(src: []const u32) usize {
    const sum, const p = sumBlocks(u32, 1, struct {
        fn f(v: anytype) @TypeOf(v) {
            return ones(u32, v > @as(@TypeOf(v), @splat(0xFFFF)));
        }
    }.f, src);
    return p + sum + scalar.utf16FromUtf32(src[p..]);
}

/// UTF-16 code units for Latin-1: one per byte.
pub fn utf16FromLatin1(src: []const u8) usize {
    return src.len;
}

/// UTF-32 code units for UTF-8: one per character.
pub fn utf32FromUtf8(src: []const u8) usize {
    return countUtf8(src);
}

/// UTF-32 code units for UTF-16LE: one per code point.
pub fn utf32FromUtf16le(src: []const u16) usize {
    return countUtf16(.little, src);
}

/// UTF-32 code units for UTF-16BE: one per code point.
pub fn utf32FromUtf16be(src: []const u16) usize {
    return countUtf16(.big, src);
}

/// UTF-32 code units for Latin-1: one per byte.
pub fn utf32FromLatin1(src: []const u8) usize {
    return src.len;
}

/// UTF-8 bytes for UTF-16LE: a surrogate counts two, so a pair counts four.
pub fn utf8FromUtf16le(src: []const u16) usize {
    return utf8FromUtf16(.little, src);
}

/// UTF-8 bytes for UTF-16BE: a surrogate counts two, so a pair counts four.
pub fn utf8FromUtf16be(src: []const u16) usize {
    return utf8FromUtf16(.big, src);
}

/// UTF-8 bytes for UTF-32: one to four per code point.
pub fn utf8FromUtf32(src: []const u32) usize {
    const sum, const p = sumBlocks(u32, 3, struct {
        fn f(v: anytype) @TypeOf(v) {
            const V = @TypeOf(v);
            return ones(u32, v >= @as(V, @splat(0x80))) + ones(u32, v >= @as(V, @splat(0x800))) +
                ones(u32, v >= @as(V, @splat(0x10000)));
        }
    }.f, src);
    return p + sum + scalar.utf8FromUtf32(src[p..]);
}

/// UTF-8 bytes for Latin-1: one per byte below 0x80, two above.
pub fn utf8FromLatin1(src: []const u8) usize {
    const sum, const p = sumBlocks(u8, 1, struct {
        fn f(v: anytype) @TypeOf(v) {
            return ones(u8, v >= @as(@TypeOf(v), @splat(0x80)));
        }
    }.f, src);
    return p + sum + scalar.utf8FromLatin1(src[p..]);
}

/// Latin-1 bytes for UTF-8: one per character.
pub fn latin1FromUtf8(src: []const u8) usize {
    return countUtf8(src);
}

/// Latin-1 bytes for UTF-16: one per code unit.
pub fn latin1FromUtf16(src: []const u16) usize {
    return src.len;
}

/// Latin-1 bytes for UTF-32: one per code point.
pub fn latin1FromUtf32(src: []const u32) usize {
    return src.len;
}

fn countUtf16(comptime e: Endian, src: []const u16) usize {
    const lows, const p = sumBlocks(u16, 1, struct {
        fn f(v: anytype) @TypeOf(v) {
            const V = @TypeOf(v);
            return ones(u16, swap(e, v) & @as(V, @splat(0xFC00)) == @as(V, @splat(0xDC00)));
        }
    }.f, src);
    return p - lows + scalar.countUtf16(e, src[p..]);
}

fn utf8FromUtf16(comptime e: Endian, src: []const u16) usize {
    const sum, const p = sumBlocks(u16, 2, struct {
        fn f(raw: anytype) @TypeOf(raw) {
            const V = @TypeOf(raw);
            const v = swap(e, raw);
            // Above one byte, and above two unless a surrogate.
            return ones(u16, v >= @as(V, @splat(0x80))) +
                ones(u16, v >= @as(V, @splat(0x800))) -
                ones(u16, v & @as(V, @splat(0xF800)) == @as(V, @splat(0xD800)));
        }
    }.f, src);
    return p + sum + scalar.utf8FromUtf16(e, src[p..]);
}

/// Lanes that hold a byte other than a UTF-8 continuation byte.
inline fn notContinuation(v: anytype) @Vector(@typeInfo(@TypeOf(v)).vector.len, bool) {
    const S = @Vector(@typeInfo(@TypeOf(v)).vector.len, i8);
    return @as(S, @bitCast(v)) >= @as(S, @splat(-64));
}

inline fn ones(comptime T: type, b: anytype) @Vector(@typeInfo(@TypeOf(b)).vector.len, T) {
    const V = @Vector(@typeInfo(@TypeOf(b)).vector.len, T);
    return @select(T, b, @as(V, @splat(1)), @as(V, @splat(0)));
}

inline fn swap(comptime e: Endian, v: anytype) @TypeOf(v) {
    return if (e == native) v else @byteSwap(v);
}

/// Sums `f`, at most `max` per lane, over `src`: in 64-byte vectors, or in
/// 16-byte ones when `src` is shorter than 64 bytes. Returns the sum and the
/// number of code units it covers, all of `src` unless it is shorter than 16
/// bytes.
inline fn sumBlocks(
    comptime T: type,
    comptime max: comptime_int,
    comptime f: anytype,
    src: []const T,
) struct { usize, usize } {
    if (src.len >= 64 / @sizeOf(T)) return sumVectors(T, 64 / @sizeOf(T), max, f, src);
    if (src.len >= 16 / @sizeOf(T)) return sumVectors(T, 16 / @sizeOf(T), max, f, src);
    return .{ 0, 0 };
}

/// `sumBlocks` in vectors of `n` units, for `src` at least that long,
/// accumulating in lanes as wide as `T`. The last partial vector is a whole
/// one that ends with `src`, with the lanes already counted masked off.
inline fn sumVectors(
    comptime T: type,
    comptime n: usize,
    comptime max: comptime_int,
    comptime f: anytype,
    src: []const T,
) struct { usize, usize } {
    const V = @Vector(n, T);
    var sum: usize = 0;
    var p: usize = 0;
    while (src.len - p >= n) {
        const blocks = @min((src.len - p) / n, std.math.maxInt(T) / max);
        var acc: V = @splat(0);
        for (0..blocks) |_| {
            acc +%= f(@as(V, src[p..][0..n].*));
            p += n;
        }
        sum += @reduce(.Add, @as(@Vector(n, u64), acc));
    }
    if (p < src.len) {
        const fresh = std.simd.iota(T, n) >= @as(V, @splat(@intCast(n - (src.len - p))));
        const last = f(@as(V, src[src.len - n ..][0..n].*));
        sum += @reduce(.Add, @as(@Vector(n, u64), @select(T, fresh, last, @as(V, @splat(0)))));
    }
    return .{ sum, src.len };
}

test "every length function matches the scalar reference on any input" {
    const testing = std.testing;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    var buf8: [700]u8 = undefined;
    var buf16: [350]u16 = undefined;
    var buf32: [180]u32 = undefined;
    for (0..2000) |_| {
        const n8 = r.uintLessThan(usize, buf8.len);
        const n16 = r.uintLessThan(usize, buf16.len);
        const n32 = r.uintLessThan(usize, buf32.len);
        // Bytes and units of every class, surrogates and invalid values
        // included, most of the time ASCII so the blocks vary.
        for (buf8[0..n8]) |*b| b.* = if (r.boolean()) r.uintLessThan(u8, 0x80) else r.int(u8);
        for (buf16[0..n16]) |*u| u.* = switch (r.uintLessThan(u8, 4)) {
            0 => r.uintLessThan(u16, 0x80),
            1 => 0xD800 + r.uintLessThan(u16, 0x800),
            else => r.int(u16),
        };
        for (buf32[0..n32]) |*u| u.* = switch (r.uintLessThan(u8, 4)) {
            0 => r.uintLessThan(u32, 0x80),
            1 => r.uintLessThan(u32, 0x110000),
            else => r.int(u32) >> r.int(u5),
        };
        const s8 = buf8[0..n8];
        const s16 = buf16[0..n16];
        const s32 = buf32[0..n32];
        try testing.expectEqual(scalar.countUtf8(s8), countUtf8(s8));
        try testing.expectEqual(scalar.utf16FromUtf8(s8), utf16FromUtf8(s8));
        try testing.expectEqual(scalar.utf8FromLatin1(s8), utf8FromLatin1(s8));
        try testing.expectEqual(scalar.countUtf16(.little, s16), countUtf16le(s16));
        try testing.expectEqual(scalar.countUtf16(.big, s16), countUtf16be(s16));
        try testing.expectEqual(scalar.utf8FromUtf16(.little, s16), utf8FromUtf16le(s16));
        try testing.expectEqual(scalar.utf8FromUtf16(.big, s16), utf8FromUtf16be(s16));
        try testing.expectEqual(scalar.utf8FromUtf32(s32), utf8FromUtf32(s32));
        try testing.expectEqual(scalar.utf16FromUtf32(s32), utf16FromUtf32(s32));
    }
}

test "length functions count past their lane accumulators' range" {
    const testing = std.testing;
    // Every byte and unit counts the most it can, for more blocks than one
    // accumulator holds.
    const leads = [_]u8{0xF4} ** (64 * 300 + 5);
    try testing.expectEqual(leads.len, countUtf8(&leads));
    try testing.expectEqual(2 * leads.len, utf16FromUtf8(&leads));
    try testing.expectEqual(2 * leads.len, utf8FromLatin1(&leads));
    const units = [_]u16{0x0800} ** (32 * 100 + 3);
    try testing.expectEqual(3 * units.len, utf8FromUtf16le(&units));
    const cps = [_]u32{0x10000} ** (16 * 100 + 7);
    try testing.expectEqual(4 * cps.len, utf8FromUtf32(&cps));
    try testing.expectEqual(2 * cps.len, utf16FromUtf32(&cps));
}
