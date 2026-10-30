//! Transcoding between UTF-8, UTF-16LE, UTF-16BE, UTF-32, and Latin-1, with
//! SIMD. Callers own every buffer; nothing allocates.
//!
//! Each conversion has two forms. The checked form (`utf8ToUtf16le`)
//! validates as it converts and returns a `Result`: on success the number of
//! code units written, on failure simdutf's error kind and the index in the
//! input of the first ill-formed character. When the output runs out it
//! fails with `output_buffer_too_small` at the first character that does not
//! fit; a buffer sized by the matching `length` function always fits. The
//! valid form (`validUtf8ToUtf16le`) assumes well-formed input and a buffer
//! the `length` function sized, and returns the number of code units written.
//! Results equal those of `scalar_convert.zig` on every input.
//!
//! UTF-16LE and UTF-16BE name the byte order of the code units in memory, as
//! simdutf's `char16_t` functions do; UTF-32 is native.
//!
//! The kernels follow Lemire and Muła, "Transcoding Billions of Unicode
//! Characters per Second with SIMD Instructions" (2022): UTF-8 is decoded in
//! 12-byte windows through shuffle tables keyed by the end-of-character mask,
//! and encoded by expanding code points into lanes and compressing them, with
//! ASCII and two-byte fast paths. UTF-8 is validated in the same pass with
//! Keiser and Lemire's three-lookup check. Every table is built at comptime.

const std = @import("std");
const builtin = @import("builtin");
const Endian = std.builtin.Endian;
const result = @import("result.zig");
const Result = result.Result;
const scalar = @import("scalar_convert.zig");
const simd = @import("simd.zig");

const native = builtin.cpu.arch.endian();

/// Whether byte shuffles are single instructions. Without them (the
/// generic path, and the self-hosted backends, which cannot call LLVM
/// intrinsics) shuffles go lane by lane and lose to the scalar code, so
/// only the ASCII paths stay vectorized and other blocks go to it.
const fast_shuffle = simd.isa != .generic and builtin.zig_backend == .stage2_llvm;

// The shuffle tables index bytes within lanes as a little-endian machine
// lays them out.
const use_simd = native == .little;

// UTF-8 source.

pub fn utf8ToUtf16le(src: []const u8, dst: []u16) Result {
    return utf8ToUnits(u16, .little, true, src, dst);
}
pub fn utf8ToUtf16be(src: []const u8, dst: []u16) Result {
    return utf8ToUnits(u16, .big, true, src, dst);
}
pub fn utf8ToUtf32(src: []const u8, dst: []u32) Result {
    return utf8ToUnits(u32, native, true, src, dst);
}
pub fn utf8ToLatin1(src: []const u8, dst: []u8) Result {
    return utf8ToLatin1Impl(true, src, dst);
}
pub fn validUtf8ToUtf16le(src: []const u8, dst: []u16) usize {
    return utf8ToUnits(u16, .little, false, src, dst).count;
}
pub fn validUtf8ToUtf16be(src: []const u8, dst: []u16) usize {
    return utf8ToUnits(u16, .big, false, src, dst).count;
}
pub fn validUtf8ToUtf32(src: []const u8, dst: []u32) usize {
    return utf8ToUnits(u32, native, false, src, dst).count;
}
pub fn validUtf8ToLatin1(src: []const u8, dst: []u8) usize {
    return utf8ToLatin1Impl(false, src, dst).count;
}

// UTF-16 source.

pub fn utf16leToUtf8(src: []const u16, dst: []u8) Result {
    return utf16ToUtf8Impl(.little, true, src, dst);
}
pub fn utf16beToUtf8(src: []const u16, dst: []u8) Result {
    return utf16ToUtf8Impl(.big, true, src, dst);
}
pub fn utf16leToUtf32(src: []const u16, dst: []u32) Result {
    return utf16ToUtf32Impl(.little, true, src, dst);
}
pub fn utf16beToUtf32(src: []const u16, dst: []u32) Result {
    return utf16ToUtf32Impl(.big, true, src, dst);
}
pub fn utf16leToLatin1(src: []const u16, dst: []u8) Result {
    return utf16ToLatin1Impl(.little, true, src, dst);
}
pub fn utf16beToLatin1(src: []const u16, dst: []u8) Result {
    return utf16ToLatin1Impl(.big, true, src, dst);
}
/// Swaps the byte order, failing on an unpaired surrogate.
pub fn utf16leToUtf16be(src: []const u16, dst: []u16) Result {
    return utf16SwapImpl(.little, true, src, dst);
}
/// Swaps the byte order, failing on an unpaired surrogate.
pub fn utf16beToUtf16le(src: []const u16, dst: []u16) Result {
    return utf16SwapImpl(.big, true, src, dst);
}
pub fn validUtf16leToUtf8(src: []const u16, dst: []u8) usize {
    return utf16ToUtf8Impl(.little, false, src, dst).count;
}
pub fn validUtf16beToUtf8(src: []const u16, dst: []u8) usize {
    return utf16ToUtf8Impl(.big, false, src, dst).count;
}
pub fn validUtf16leToUtf32(src: []const u16, dst: []u32) usize {
    return utf16ToUtf32Impl(.little, false, src, dst).count;
}
pub fn validUtf16beToUtf32(src: []const u16, dst: []u32) usize {
    return utf16ToUtf32Impl(.big, false, src, dst).count;
}
pub fn validUtf16leToLatin1(src: []const u16, dst: []u8) usize {
    return utf16ToLatin1Impl(.little, false, src, dst).count;
}
pub fn validUtf16beToLatin1(src: []const u16, dst: []u8) usize {
    return utf16ToLatin1Impl(.big, false, src, dst).count;
}
pub fn validUtf16leToUtf16be(src: []const u16, dst: []u16) usize {
    return utf16SwapImpl(.little, false, src, dst).count;
}
pub fn validUtf16beToUtf16le(src: []const u16, dst: []u16) usize {
    return utf16SwapImpl(.big, false, src, dst).count;
}

// UTF-32 source.

pub fn utf32ToUtf8(src: []const u32, dst: []u8) Result {
    return utf32ToUtf8Impl(true, src, dst);
}
pub fn utf32ToUtf16le(src: []const u32, dst: []u16) Result {
    return utf32ToUtf16Impl(.little, true, src, dst);
}
pub fn utf32ToUtf16be(src: []const u32, dst: []u16) Result {
    return utf32ToUtf16Impl(.big, true, src, dst);
}
pub fn utf32ToLatin1(src: []const u32, dst: []u8) Result {
    return utf32ToLatin1Impl(true, src, dst);
}
pub fn validUtf32ToUtf8(src: []const u32, dst: []u8) usize {
    return utf32ToUtf8Impl(false, src, dst).count;
}
pub fn validUtf32ToUtf16le(src: []const u32, dst: []u16) usize {
    return utf32ToUtf16Impl(.little, false, src, dst).count;
}
pub fn validUtf32ToUtf16be(src: []const u32, dst: []u16) usize {
    return utf32ToUtf16Impl(.big, false, src, dst).count;
}
pub fn validUtf32ToLatin1(src: []const u32, dst: []u8) usize {
    return utf32ToLatin1Impl(false, src, dst).count;
}

// Latin-1 source. Every byte is a character, so the checked forms fail only
// when the output runs out, and the valid forms only assume it does not.

pub fn latin1ToUtf8(src: []const u8, dst: []u8) Result {
    return latin1ToUtf8Impl(true, src, dst);
}
pub fn latin1ToUtf16le(src: []const u8, dst: []u16) Result {
    return latin1ToUnits(u16, .little, true, src, dst);
}
pub fn latin1ToUtf16be(src: []const u8, dst: []u16) Result {
    return latin1ToUnits(u16, .big, true, src, dst);
}
pub fn latin1ToUtf32(src: []const u8, dst: []u32) Result {
    return latin1ToUnits(u32, native, true, src, dst);
}
pub fn validLatin1ToUtf8(src: []const u8, dst: []u8) usize {
    return latin1ToUtf8Impl(false, src, dst).count;
}
pub fn validLatin1ToUtf16le(src: []const u8, dst: []u16) usize {
    return latin1ToUnits(u16, .little, false, src, dst).count;
}
pub fn validLatin1ToUtf16be(src: []const u8, dst: []u16) usize {
    return latin1ToUnits(u16, .big, false, src, dst).count;
}
pub fn validLatin1ToUtf32(src: []const u8, dst: []u32) usize {
    return latin1ToUnits(u32, native, false, src, dst).count;
}

// Vector helpers. Private until simd.zig lands.

const V16 = @Vector(16, u8);

inline fn splat(comptime T: type, comptime x: anytype) T {
    return @splat(x);
}

/// The lanes of `b` as bits. The self-hosted x86 backend can leave junk
/// above bit 3 when it bitcasts a 4-lane bool vector, so it gets them one by
/// one.
inline fn mask4(b: @Vector(4, bool)) u4 {
    if (builtin.zig_backend == .stage2_llvm) return simd.bitmask(b);
    return @truncate(@reduce(.Or, @select(u8, b, @Vector(4, u8){ 1, 2, 4, 8 }, splat(@Vector(4, u8), 0))));
}

/// Loads `n` UTF-16 code units in byte order `e` as native values. Volatile,
/// as `load` is: a block and the units one past it would otherwise merge
/// into narrow loads that rebuild both.
inline fn load16(comptime e: Endian, comptime n: usize, src: []const u16, i: usize) @Vector(n, u16) {
    const v = @as(*align(1) const volatile @Vector(n, u16), @ptrCast(src[i..][0..n])).*;
    return if (e == native) v else @byteSwap(v);
}

/// Stores `v` to `dst[o..][0..n]`, widening or narrowing each lane to `T`
/// and putting UTF-16 in byte order `e`.
inline fn store(comptime T: type, comptime e: Endian, dst: []T, o: usize, v: anytype) void {
    const n = @typeInfo(@TypeOf(v)).vector.len;
    const Elem = @typeInfo(@TypeOf(v)).vector.child;
    const w: @Vector(n, T) = if (@bitSizeOf(Elem) <= @bitSizeOf(T)) v else @truncate(v);
    dst[o..][0..n].* = if (T == u16 and e != native) @byteSwap(w) else w;
}

/// Loads 16 bytes in one instruction. A shuffle table's entry, or a window
/// of input that shuffles use only in part, otherwise gets built from
/// several narrower loads, since LLVM can see which of their bytes matter
/// or never change; volatile keeps the load whole.
inline fn loadVolatile(ptr: *const [16]u8) V16 {
    return @as(*align(1) const volatile V16, @ptrCast(ptr)).*;
}

/// Whether every lane of `v` is below `limit`, a power of two: one test of
/// the bits above, where a reduction to the largest lane takes a tree of
/// shuffles.
inline fn below(comptime limit: comptime_int, v: anytype) bool {
    const V = @TypeOf(v);
    const Elem = @typeInfo(V).vector.child;
    return @reduce(.Or, v & splat(V, ~@as(Elem, limit - 1))) == 0;
}

/// Combines a checked scalar tail at input `p` and output `o` with the
/// work before it.
inline fn tail(r: Result, p: usize, o: usize) Result {
    return if (r.err == .none) .ok(o + r.count) else .fail(r.err, p + r.count);
}

/// How many code units the next scalar step takes: 16 when the SIMD loop
/// got past the last step, doubling to 64 while it does not. Short steps
/// return to the ASCII path sooner, as text with scattered accents wants;
/// long ones pay the call and the failed ASCII check less often, as text in
/// another script wants (64 is 15–40% faster on it, and 40% slower on
/// Latin).
const Steps = struct {
    n: usize = 16,
    end: usize = 0,

    fn next(s: *Steps, p: usize) usize {
        s.n = if (p == s.end) @min(2 * s.n, 64) else 16;
        return s.n;
    }
};

/// The scalar conversion `run` over `src[p.*..end]`, for a block without
/// `fast_shuffle`, advancing `p` and `o`; the result to return on an error.
/// `end` must be a character boundary, so the scalar code sees the same
/// characters, and reports the same errors, as over the whole input. Called
/// between SIMD loops, not inside them: a call in the loop makes LLVM
/// spill its vector constants, which cost the ASCII path 10-50%. Never
/// inlined: inlined, LLVM merges its first store into the ASCII path's and
/// splits the ASCII block into bytes and shifts (half the speed).
inline fn scalarStep(
    comptime run: anytype,
    src: anytype,
    end: usize,
    dst: anytype,
    p: *usize,
    o: *usize,
    steps: *Steps,
) ?Result {
    const r = @call(.never_inline, run, .{ src[p.*..end], dst[o.*..] });
    if (r.err != .none) return tail(r, p.*, o.*);
    p.* = end;
    o.* += r.count;
    steps.end = end;
    return null;
}

/// The character boundary at or before `src[i]`, and after `src[p]`: the
/// start of the character that holds it, or of a malformed run.
fn utf8Boundary(src: []const u8, p: usize, i: usize) usize {
    var q = @min(i, src.len);
    while (q > p + 1 and q < src.len and src[q] & 0xC0 == 0x80) q -= 1;
    return q;
}

/// `p + n`, or one less if that would split a surrogate pair.
fn utf16Boundary(comptime e: Endian, src: []const u16, p: usize, n: usize) usize {
    const q = p + n;
    const before = if (e == native) src[q - 1] else @byteSwap(src[q - 1]);
    return if (q < src.len and before & 0xFC00 == 0xD800) q - 1 else q;
}

// UTF-8 validation: Keiser and Lemire, "Validating UTF-8 In Less Than One
// Instruction Per Byte" (2021). Each byte is classified by its high nibble,
// and the byte before it by both nibbles; the AND of the three lookups is
// nonzero for every error that two bytes show, and the 0x80 bit flags a
// continuation byte that must or must not be the second or third of one.

const too_short: u8 = 1 << 0; // 11______ 0_______, 11______ 11______
const too_long: u8 = 1 << 1; // 0_______ 10______
const overlong_3: u8 = 1 << 2; // 11100000 100_____
const too_large: u8 = 1 << 3; // 11110100 1001____, 11110100 101_____, 11110101+
const surrogate: u8 = 1 << 4; // 11101101 101_____
const overlong_2: u8 = 1 << 5; // 1100000_ 10______
const too_large_1000: u8 = 1 << 6; // 11110101+ 1000____
const overlong_4: u8 = 1 << 6; // 11110000 1000____
const two_conts: u8 = 1 << 7; // 10______ 10______
const carry = too_short | too_long | two_conts;

const byte1_high = [16]u8{
    too_long, // 0_______
    too_long,
    too_long,
    too_long,
    too_long,
    too_long,
    too_long,
    too_long,
    two_conts, // 10______
    two_conts,
    two_conts,
    two_conts,
    too_short | overlong_2, // 1100____
    too_short, // 1101____
    too_short | overlong_3 | surrogate, // 1110____
    too_short | too_large | too_large_1000 | overlong_4, // 1111____
};
const byte1_low = [16]u8{
    carry | overlong_3 | overlong_2 | overlong_4,
    carry | overlong_2,
    carry,
    carry,
    carry | too_large,
    carry | too_large | too_large_1000,
    carry | too_large | too_large_1000,
    carry | too_large | too_large_1000,
    carry | too_large | too_large_1000,
    carry | too_large | too_large_1000,
    carry | too_large | too_large_1000,
    carry | too_large | too_large_1000,
    carry | too_large | too_large_1000,
    carry | too_large | too_large_1000 | surrogate,
    carry | too_large | too_large_1000,
    carry | too_large | too_large_1000,
};
const byte2_high = [16]u8{
    too_short, // 0_______
    too_short,
    too_short,
    too_short,
    too_short,
    too_short,
    too_short,
    too_short,
    too_long | overlong_2 | two_conts | overlong_3 | too_large_1000 | overlong_4, // 1000____
    too_long | overlong_2 | two_conts | overlong_3 | too_large, // 1001____
    too_long | overlong_2 | two_conts | surrogate | too_large, // 101_____
    too_long | overlong_2 | two_conts | surrogate | too_large,
    too_short, // 11______
    too_short,
    too_short,
    too_short,
};

/// Whether `cur` has an error its bytes show. `cur` starts at a character
/// boundary after valid input, so the bytes before it end a complete
/// character, and as context they act the same as ASCII: they cannot make a
/// byte of `cur` a required continuation, and they allow any lead. A
/// character cut off at the end is not an error here, since the next block
/// starts at or before its first byte.
///
/// The lookups are lane by lane, so the first byte's two are made for every
/// byte of `cur` and then shifted up a lane, with an ASCII byte's results
/// shifting in. Shifting `cur` itself instead leads LLVM to rebuild it from
/// loads that overlap it.
inline fn utf8Invalid(comptime n: usize, cur: @Vector(n, u8)) bool {
    const V = @Vector(n, u8);
    const zero = splat(V, 0);
    const first = simd.lookup16(byte1_high, cur >> splat(V, 4)) & simd.lookup16(byte1_low, cur & splat(V, 0x0F));
    const ascii = splat(V, byte1_high[0] & byte1_low[0]);
    const special = simd.prev(1, first, ascii) & simd.lookup16(byte2_high, cur >> splat(V, 4));
    const third = @select(u8, cur >= splat(V, 0xE0), splat(V, 0x80), zero);
    const fourth = @select(u8, cur >= splat(V, 0xF0), splat(V, 0x80), zero);
    const must23 = simd.prev(2, third, zero) | simd.prev(3, fourth, zero);
    return @reduce(.Or, special ^ must23) != 0;
}

/// Bit i set where byte i is not a continuation byte.
inline fn leadMask(comptime n: usize, v: @Vector(n, u8)) @Int(.unsigned, n) {
    const I = @Vector(n, i8);
    return simd.bitmask(@as(I, @bitCast(v)) >= splat(I, -64));
}

// UTF-8 to UTF-16 and UTF-32: the 12-byte windows.

// For each 12-bit end-of-character mask (bit i set where byte i ends a
// character), the shuffle that puts each of the first characters in its own
// lane, and how many bytes they take. Three layouts, by the longest of the
// characters taken: six of one or two bytes in 16-bit lanes (shuffles
// 0-63), four of up to three bytes in 32-bit lanes (64-144), or three of up
// to four bytes in 32-bit lanes (145-208). The last byte of a character goes
// in the lane's low byte, its lead in the highest one used.
const utf8_windows: struct { shuffles: [209][16]u8, index: [4096][2]u8 } = blk: {
    @setEvalBranchQuota(400_000);
    const zero = 0x80;
    var shuffles: [209][16]u8 = undefined;
    for (&shuffles, 0..) |*s, i| {
        s.* = @splat(zero);
        // The character lengths each layout's index encodes.
        const chars: usize, const lane_bytes: usize, const base: usize, const first: usize =
            if (i < 64) .{ 6, 2, 2, 0 } else if (i < 145) .{ 4, 4, 3, 64 } else .{ 3, 4, 4, 145 };
        var code = i - first;
        var start: usize = 0;
        for (0..chars) |k| {
            const len = code % base + 1;
            code /= base;
            for (0..len) |b| s[k * lane_bytes + b] = start + len - 1 - b;
            start += len;
        }
    }
    var index: [4096][2]u8 = undefined;
    for (&index, 0..) |*entry, mask| {
        var lens: [12]usize = undefined;
        var ends: [12]usize = undefined;
        var count: usize = 0;
        var start: usize = 0;
        for (0..12) |bit| {
            if (mask >> bit & 1 == 0) continue;
            lens[count] = bit + 1 - start;
            ends[count] = bit;
            count += 1;
            start = bit + 1;
        }
        const fits = struct {
            fn f(l: []const usize, n: usize, max: usize) bool {
                if (l.len < n) return false;
                for (l[0..n]) |x| if (x > max) return false;
                return true;
            }
        }.f;
        const l = lens[0..count];
        if (fits(l, 6, 2)) {
            var s: usize = 0;
            for (0..6) |k| s += (l[k] - 1) << k;
            entry.* = .{ s, ends[5] + 1 };
        } else if (fits(l, 4, 3)) {
            var s: usize = 0;
            for (0..4) |k| s += (l[k] - 1) * std.math.pow(usize, 3, k);
            entry.* = .{ 64 + s, ends[3] + 1 };
        } else if (fits(l, 3, 4)) {
            var s: usize = 0;
            for (0..3) |k| s += (l[k] - 1) * std.math.pow(usize, 4, k);
            entry.* = .{ 145 + s, ends[2] + 1 };
        } else {
            // Only ill-formed input gets here. Take three single bytes, so
            // the valid forms still make progress and write at most one
            // code unit per byte.
            entry.* = .{ 145, 3 };
        }
    }
    break :blk .{ .shuffles = shuffles, .index = index };
};

// Compresses four 32-bit lanes, each a code point below U+10000 or a UTF-16
// surrogate pair (high surrogate low), to their UTF-16 code units; indexed
// by which lanes hold pairs.
const utf16_pairs = blk: {
    @setEvalBranchQuota(100_000);
    var shuffles: [16][16]u8 = undefined;
    for (&shuffles, 0..) |*s, mask| {
        s.* = @splat(0x80);
        var o: usize = 0;
        for (0..4) |k| {
            const units: usize = if (mask >> k & 1 != 0) 2 else 1;
            for (0..units * 2) |b| s[o + b] = k * 4 + b;
            o += units * 2;
        }
    }
    break :blk shuffles;
};

/// Decodes the characters in a window with the shuffle `idx` picked, and
/// stores them as UTF-16 in byte order `e` or as UTF-32.
inline fn utf8Window(comptime T: type, comptime e: Endian, in: V16, ends: u64, dst: []T, o: *usize) usize {
    const U16x8 = @Vector(8, u16);
    const U32x4 = @Vector(4, u32);
    if (ends & 0xFFFF == 0xFFFF) {
        store(T, e, dst, o.*, in);
        o.* += 16;
        return 16;
    }
    if (ends & 0xFFFF == 0xAAAA) {
        // Eight two-byte characters: the lead is each 16-bit lane's low byte.
        const x: U16x8 = @bitCast(in);
        const lead = (x & splat(U16x8, 0x1F)) << splat(U16x8, 6);
        store(T, e, dst, o.*, lead | ((x >> splat(U16x8, 8)) & splat(U16x8, 0x3F)));
        o.* += 8;
        return 16;
    }
    if (ends & 0xFFF == 0x924) {
        // Four three-byte characters, without the table's load in the way
        // of the next window.
        const three = @shuffle(u8, in, splat(V16, 0), [16]i32{ 2, 1, 0, -1, 5, 4, 3, -1, 8, 7, 6, -1, 11, 10, 9, -1 });
        const x: U32x4 = @bitCast(three);
        store(T, e, dst, o.*, x & splat(U32x4, 0x3F) | (x & splat(U32x4, 0x3F00)) >> splat(U32x4, 2) |
            (x & splat(U32x4, 0x0F0000)) >> splat(U32x4, 4));
        o.* += 4;
        return 12;
    }
    const entry = utf8_windows.index[@as(u12, @truncate(ends))];
    const perm = simd.lookup16(in, loadVolatile(&utf8_windows.shuffles[entry[0]]));
    if (entry[0] < 64) {
        const x: U16x8 = @bitCast(perm);
        store(T, e, dst, o.*, x & splat(U16x8, 0x7F) | (x & splat(U16x8, 0x1F00)) >> splat(U16x8, 2));
        o.* += 6;
    } else if (entry[0] < 145) {
        const x: U32x4 = @bitCast(perm);
        store(T, e, dst, o.*, x & splat(U32x4, 0x7F) | (x & splat(U32x4, 0x3F00)) >> splat(U32x4, 2) |
            (x & splat(U32x4, 0x0F0000)) >> splat(U32x4, 4));
        o.* += 4;
    } else {
        const x: U32x4 = @bitCast(perm);
        // The third byte is a continuation (keep six bits) or a three-byte
        // lead (keep four): a lead has bit 6 set, so clear bit 5 with it.
        const third = x & splat(U32x4, 0x3F0000) ^ (x & splat(U32x4, 0x400000)) >> splat(U32x4, 1);
        const cp = x & splat(U32x4, 0x7F) | (x & splat(U32x4, 0x3F00)) >> splat(U32x4, 2) |
            third >> splat(U32x4, 4) | (x & splat(U32x4, 0x07000000)) >> splat(U32x4, 6);
        if (T == u32) {
            store(T, e, dst, o.*, cp);
            o.* += 3;
        } else {
            const pairs = cp >= splat(U32x4, 0x10000);
            const mask = mask4(pairs) & 7;
            const s = cp -% splat(U32x4, 0x10000);
            const pair = (splat(U32x4, 0xD800) | s >> splat(U32x4, 10)) |
                (splat(U32x4, 0xDC00) | (s & splat(U32x4, 0x3FF))) << splat(U32x4, 16);
            const units = simd.lookup16(@bitCast(@select(u32, pairs, pair, cp)), loadVolatile(&utf16_pairs[mask]));
            store(T, e, dst, o.*, @as(U16x8, @bitCast(units)));
            o.* += 3 + @as(usize, @popCount(mask));
        }
    }
    return entry[1];
}

fn utf8ToUnits(comptime T: type, comptime e: Endian, comptime checked: bool, src: []const u8, dst: []T) Result {
    const run = struct {
        fn f(s: []const u8, d: []T) Result {
            if (T == u16) {
                if (checked) return scalar.utf8ToUtf16(e, s, d);
                return .ok(scalar.validUtf8ToUtf16(e, s, d));
            }
            if (checked) return scalar.utf8ToUtf32(s, d);
            return .ok(scalar.validUtf8ToUtf32(s, d));
        }
    }.f;
    var p: usize = 0;
    var o: usize = 0;
    var steps: Steps = .{};
    if (use_simd) while (true) {
        // A block writes at most one code unit per byte, and a window's last
        // store reaches at most eight past its output, and loads 16 bytes
        // from as far as byte 51: an ASCII block needs neither.
        while (src.len - p >= 64 and dst.len - o >= 64) {
            const block = simd.load(u8, src[p..]);
            if (below(0x80, block)) {
                store(T, e, dst, o, block);
                p += 64;
                o += 64;
                continue;
            }
            if (!fast_shuffle) {
                break;
            }
            if (src.len - p < 64 + 16 or dst.len - o < 64 + 16) break;
            if (checked and utf8Invalid(64, block)) break;
            // Bit i set where byte i ends a character; bit 63 is unknown.
            const ends = leadMask(64, block) >> 1;
            var pos: usize = 0;
            while (pos < 64 - 12) {
                pos += utf8Window(T, e, loadVolatile(src[p + pos ..][0..16]), ends >> @intCast(pos), dst, &o);
            }
            p += pos;
        }
        while (src.len - p >= 16 and dst.len - o >= 16) {
            const w = simd.load16(src[p..]);
            if (below(0x80, w)) {
                store(T, e, dst, o, w);
                p += 16;
                o += 16;
                continue;
            }
            if (!fast_shuffle) {
                break;
            }
            if (checked and utf8Invalid(16, w)) break;
            p += utf8Window(T, e, w, leadMask(16, w) >> 1, dst, &o);
        }
        if (fast_shuffle or !(src.len - p >= 16 and dst.len - o >= 16)) break;
        if (scalarStep(run, src, utf8Boundary(src, p, p + steps.next(p)), dst, &p, &o, &steps)) |r| return r;
    };
    return tail(run(src[p..], dst[o..]), p, o);
}

// UTF-8 to Latin-1: only ASCII and the leads 0xC2 and 0xC3 are valid, so a
// 16-byte window is checked by classifying its bytes, decoded with one
// shifted copy, and compressed to drop the continuation bytes.

// For each 8-bit mask, the indexes of its set bits, in order.
const compress8 = blk: {
    @setEvalBranchQuota(100_000);
    var shuffles: [256][16]u8 = undefined;
    for (&shuffles, 0..) |*s, mask| {
        s.* = @splat(0x80);
        var o: usize = 0;
        for (0..8) |k| {
            if (mask >> k & 1 == 0) continue;
            s[o] = k;
            o += 1;
        }
    }
    break :blk shuffles;
};

/// Stores the lanes of `v` that `keep` selects, in order, to `dst[o..]`, and
/// returns how many. Writes 16 bytes past the start of each half.
inline fn compress16(v: V16, keep: u16, dst: []u8, o: usize) usize {
    const lo: u8 = @truncate(keep);
    const hi: u8 = @truncate(keep >> 8);
    const n_lo: usize = @popCount(lo);
    dst[o..][0..16].* = simd.lookup16(v, loadVolatile(&compress8[lo]));
    dst[o + n_lo ..][0..16].* = simd.lookup16(v, loadVolatile(&compress8[hi]) +% splat(V16, 8));
    return n_lo + @popCount(hi);
}

fn utf8ToLatin1Impl(comptime checked: bool, src: []const u8, dst: []u8) Result {
    const run = struct {
        fn f(s: []const u8, d: []u8) Result {
            if (checked) return scalar.utf8ToLatin1(s, d);
            return .ok(scalar.validUtf8ToLatin1(s, d));
        }
    }.f;
    var p: usize = 0;
    var o: usize = 0;
    var steps: Steps = .{};
    if (use_simd) while (true) {
        while (src.len - p >= 16 and dst.len - o >= 32) {
            if (src.len - p >= 64 and dst.len - o >= 64) {
                const block = simd.load(u8, src[p..]);
                if (below(0x80, block)) {
                    dst[o..][0..64].* = block;
                    p += 64;
                    o += 64;
                    continue;
                }
            }
            const w = simd.load16(src[p..]);
            if (below(0x80, w)) {
                dst[o..][0..16].* = w;
                p += 16;
                o += 16;
                continue;
            }
            if (!fast_shuffle) {
                break;
            }
            const lead: u16 = simd.bitmask(w & splat(V16, 0xFE) == splat(V16, 0xC2));
            const cont: u16 = simd.bitmask(w & splat(V16, 0xC0) == splat(V16, 0x80));
            if (checked) {
                const high: u16 = simd.bitmask(w >= splat(V16, 0x80));
                // p is a character boundary, so byte 0 is not a continuation.
                if (high & ~lead & ~cont != 0 or cont != lead << 1) break;
            }
            const down = [16]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, -1 };
            const next = @shuffle(u8, w, splat(V16, 0), down);
            const leads: @Vector(16, bool) = @bitCast(lead);
            const v = @select(u8, leads, w << splat(V16, 6) | (next & splat(V16, 0x3F)), w);
            // A lead in the last byte waits for the next window.
            const last: u16 = lead & 0x8000;
            o += compress16(v, ~cont & ~last, dst, o);
            p += if (last != 0) 15 else 16;
        }
        if (fast_shuffle or !(src.len - p >= 16 and dst.len - o >= 32)) break;
        if (scalarStep(run, src, utf8Boundary(src, p, p + steps.next(p)), dst, &p, &o, &steps)) |r| return r;
    };
    return tail(run(src[p..], dst[o..]), p, o);
}

// UTF-16 and UTF-32 to UTF-8: each code point expands to its UTF-8 bytes in a
// lane, and a shuffle packs the lanes.

// Packs eight 16-bit lanes holding one or two UTF-8 bytes; indexed by which
// lanes hold one.
const utf8_pack2: struct { shuffles: [256][16]u8, lens: [256]u8 } = blk: {
    @setEvalBranchQuota(100_000);
    var shuffles: [256][16]u8 = undefined;
    var lens: [256]u8 = undefined;
    for (&shuffles, &lens, 0..) |*s, *len, mask| {
        s.* = @splat(0x80);
        var o: usize = 0;
        for (0..8) |k| {
            s[o] = 2 * k;
            o += 1;
            if (mask >> k & 1 == 0) {
                s[o] = 2 * k + 1;
                o += 1;
            }
        }
        len.* = o;
    }
    break :blk .{ .shuffles = shuffles, .lens = lens };
};

// Packs four 32-bit lanes holding zero to four UTF-8 bytes; indexed by the
// byte counts as a base-5 number, lane 0 lowest.
const utf8_pack4: struct { shuffles: [625][16]u8, lens: [625]u8 } = blk: {
    @setEvalBranchQuota(100_000);
    var shuffles: [625][16]u8 = undefined;
    var lens: [625]u8 = undefined;
    for (&shuffles, &lens, 0..) |*s, *len, i| {
        s.* = @splat(0x80);
        var o: usize = 0;
        var code = i;
        for (0..4) |k| {
            for (0..code % 5) |b| s[o + b] = 4 * k + b;
            o += code % 5;
            code /= 5;
        }
        len.* = o;
    }
    break :blk .{ .shuffles = shuffles, .lens = lens };
};

/// Encodes eight code points below U+0800 as UTF-8 at `dst[o.*..]`.
/// Writes 16 bytes.
inline fn utf8From2(v: @Vector(8, u16), dst: []u8, o: *usize) void {
    const U = @Vector(8, u16);
    const ascii = v < splat(U, 0x80);
    const two = (splat(U, 0xC0) | v >> splat(U, 6)) | (splat(U, 0x80) | (v & splat(U, 0x3F))) << splat(U, 8);
    const mask: u8 = simd.bitmask(ascii);
    const lanes: [16]u8 = @bitCast(@select(u16, ascii, v, two));
    dst[o.*..][0..16].* = simd.lookup16(lanes, loadVolatile(&utf8_pack2.shuffles[mask]));
    o.* += utf8_pack2.lens[mask];
}

// Packs four 32-bit lanes holding one to three UTF-8 bytes; indexed by
// which lanes are at least U+0080 (low four bits) and at least U+0800 (high
// four bits).
const utf8_pack3: struct { shuffles: [256][16]u8, lens: [256]u8 } = blk: {
    @setEvalBranchQuota(100_000);
    var shuffles: [256][16]u8 = undefined;
    var lens: [256]u8 = undefined;
    for (&shuffles, &lens, 0..) |*s, *len, i| {
        s.* = @splat(0x80);
        var o: usize = 0;
        for (0..4) |k| {
            const n = 1 + (i >> k & 1) + (i >> (k + 4) & 1);
            for (0..n) |b| s[o + b] = 4 * k + b;
            o += n;
        }
        len.* = o;
    }
    break :blk .{ .shuffles = shuffles, .lens = lens };
};

// The sum of 5^k over the set bits k of each 4-bit mask: four lanes' byte
// counts, as utf8_pack4 indexes them, add up from these.
const base5 = blk: {
    var t: [16]u16 = undefined;
    for (&t, 0..) |*x, mask| {
        x.* = 0;
        for (0..4) |k| x.* += (mask >> k & 1) * std.math.pow(u16, 5, k);
    }
    break :blk t;
};

/// Encodes the lanes of `cp` that `take` selects as UTF-8 at `dst[o.*..]`,
/// in four groups of four lanes. `four` says whether any lane needs four
/// bytes; without it, every lane is taken. Writes 16 bytes past the start of
/// each group's output.
inline fn utf8From16(comptime four: bool, cp: @Vector(16, u32), take: u16, dst: []u8, o: *usize) void {
    const W = @Vector(16, u32);
    const ge80 = cp >= splat(W, 0x80);
    const ge800 = cp >= splat(W, 0x800);
    const ge10000 = cp >= splat(W, 0x10000);
    const c0 = splat(W, 0x80) | (cp & splat(W, 0x3F));
    const c1 = splat(W, 0x80) | (cp >> splat(W, 6) & splat(W, 0x3F));
    const b2 = (splat(W, 0xC0) | cp >> splat(W, 6)) | c0 << splat(W, 8);
    const b3 = (splat(W, 0xE0) | cp >> splat(W, 12)) | c1 << splat(W, 8) | c0 << splat(W, 16);
    var bytes = @select(u32, ge800, b3, @select(u32, ge80, b2, cp));
    if (four) {
        const c2 = splat(W, 0x80) | (cp >> splat(W, 12) & splat(W, 0x3F));
        const lead = splat(W, 0xF0) | cp >> splat(W, 18);
        const b4 = lead | c2 << splat(W, 8) | c1 << splat(W, 16) | c0 << splat(W, 24);
        bytes = @select(u32, ge10000, b4, bytes);
    }
    // A lane's byte count is 1 for being taken, plus 1 for each threshold
    // it reaches.
    const m1 = simd.bitmask(ge80) & take;
    const m2 = simd.bitmask(ge800) & take;
    const m4 = if (four) simd.bitmask(ge10000) & take else 0;
    const b: [16]u32 = bytes;
    inline for (0..4) |g| {
        const sh = 4 * g;
        const lanes: @Vector(4, u32) = b[sh..][0..4].*;
        if (four) {
            const i = @as(usize, base5[take >> sh & 15]) + base5[m1 >> sh & 15] +
                base5[m2 >> sh & 15] + base5[m4 >> sh & 15];
            dst[o.*..][0..16].* = simd.lookup16(@bitCast(lanes), loadVolatile(&utf8_pack4.shuffles[i]));
            o.* += utf8_pack4.lens[i];
        } else {
            const i = (m1 >> sh & 15) | (m2 >> sh & 15) << 4;
            dst[o.*..][0..16].* = simd.lookup16(@bitCast(lanes), loadVolatile(&utf8_pack3.shuffles[i]));
            o.* += utf8_pack3.lens[i];
        }
    }
}

/// Code points for 16 UTF-16 code units `v`, given the units after them,
/// `next`, which lanes to take, and how many units that consumes. A pair
/// decodes in its high surrogate's lane, and its low surrogate's lane is not
/// taken; nor is a final high surrogate, whose pair the next block decodes.
/// In the checked form, null when a surrogate is unpaired.
const Units16 = struct { cp: @Vector(16, u32), take: @Vector(16, bool), consumed: usize };

inline fn decode16(comptime checked: bool, v: @Vector(16, u16), next: @Vector(16, u16)) ?Units16 {
    const U = @Vector(16, u16);
    const W = @Vector(16, u32);
    const hi: u16 = simd.bitmask(v & splat(U, 0xFC00) == splat(U, 0xD800));
    const lo: u16 = simd.bitmask(v & splat(U, 0xFC00) == splat(U, 0xDC00));
    if (checked) {
        // Block starts are character boundaries, so lane 0 has no high
        // surrogate before it.
        const next_lo: u16 = simd.bitmask(next & splat(U, 0xFC00) == splat(U, 0xDC00));
        if ((hi & ~next_lo) | (lo & ~(hi << 1)) != 0) return null;
    }
    const w: W = v;
    const bias: u32 = @bitCast(@as(i32, 0x10000 - (0xD800 << 10) - 0xDC00));
    const pair = @as(W, @splat(bias)) +% (w << splat(W, 10)) +% @as(W, next);
    const last = hi & 0x8000;
    return .{
        .cp = @select(u32, @as(@Vector(16, bool), @bitCast(hi)), pair, w),
        .take = @bitCast(~lo & ~last),
        .consumed = if (last != 0) 15 else 16,
    };
}

fn utf16ToUtf8Impl(comptime e: Endian, comptime checked: bool, src: []const u16, dst: []u8) Result {
    const U = @Vector(16, u16);
    const run = struct {
        fn f(s: []const u16, d: []u8) Result {
            if (checked) return scalar.utf16ToUtf8(e, s, d);
            return .ok(scalar.validUtf16ToUtf8(e, s, d));
        }
    }.f;
    var p: usize = 0;
    var o: usize = 0;
    // A block writes at most 48 bytes, and each group's store reaches 16
    // past its start.
    var steps: Steps = .{};
    if (use_simd) while (true) {
        while (src.len - p >= 16 and dst.len - o >= 64) {
            if (src.len - p >= 32) {
                const pair = load16(e, 32, src, p);
                if (below(0x80, pair)) {
                    dst[o..][0..32].* = @as(@Vector(32, u8), @truncate(pair));
                    p += 32;
                    o += 32;
                    continue;
                }
            }
            const v = load16(e, 16, src, p);
            if (below(0x80, v)) {
                dst[o..][0..16].* = @as(V16, @truncate(v));
                p += 16;
                o += 16;
                continue;
            }
            if (!fast_shuffle) {
                break;
            }
            if (below(0x800, v)) {
                const a: [16]u16 = v;
                utf8From2(a[0..8].*, dst, &o);
                utf8From2(a[8..16].*, dst, &o);
                p += 16;
                continue;
            }
            if (!@reduce(.Or, v & splat(U, 0xF800) == splat(U, 0xD800))) {
                utf8From16(false, v, 0xFFFF, dst, &o);
                p += 16;
                continue;
            }
            if (src.len - p < 17) break;
            const d = decode16(checked, v, load16(e, 16, src, p + 1)) orelse break;
            utf8From16(true, d.cp, simd.bitmask(d.take), dst, &o);
            p += d.consumed;
        }
        if (fast_shuffle or !(src.len - p >= 16 and dst.len - o >= 64)) break;
        const end = utf16Boundary(e, src, p, @min(steps.next(p), src.len - p));
        if (scalarStep(run, src, end, dst, &p, &o, &steps)) |r| return r;
    };
    return tail(run(src[p..], dst[o..]), p, o);
}

fn utf32ToUtf8Impl(comptime checked: bool, src: []const u32, dst: []u8) Result {
    const run = struct {
        fn f(s: []const u32, d: []u8) Result {
            if (checked) return scalar.utf32ToUtf8(s, d);
            return .ok(scalar.validUtf32ToUtf8(s, d));
        }
    }.f;
    const W = @Vector(16, u32);
    var p: usize = 0;
    var o: usize = 0;
    var steps: Steps = .{};
    if (use_simd) while (true) {
        while (src.len - p >= 16 and dst.len - o >= 64) {
            const v = simd.load(u32, src[p..]);
            if (below(0x80, v)) {
                dst[o..][0..16].* = @as(V16, @truncate(v));
                o += 16;
            } else if (!fast_shuffle) {
                break;
            } else if (below(0x800, v)) {
                const a: [16]u32 = v;
                utf8From2(@truncate(@as(@Vector(8, u32), a[0..8].*)), dst, &o);
                utf8From2(@truncate(@as(@Vector(8, u32), a[8..16].*)), dst, &o);
            } else {
                const too_big = v > splat(W, 0x10FFFF);
                const surrogates = v & splat(W, 0xFFFFF800) == splat(W, 0xD800);
                if (checked and @reduce(.Or, too_big != surrogates)) break;
                if (below(0x10000, v)) utf8From16(false, v, 0xFFFF, dst, &o) else utf8From16(true, v, 0xFFFF, dst, &o);
            }
            p += 16;
        }
        if (fast_shuffle or !(src.len - p >= 16 and dst.len - o >= 64)) break;
        if (scalarStep(run, src, p + @min(steps.next(p), src.len - p), dst, &p, &o, &steps)) |r| return r;
    };
    return tail(run(src[p..], dst[o..]), p, o);
}

// UTF-16 to UTF-32.

// Compresses four 32-bit lanes; indexed by which to keep.
const compress32 = blk: {
    @setEvalBranchQuota(100_000);
    var shuffles: [16][16]u8 = undefined;
    for (&shuffles, 0..) |*s, mask| {
        s.* = @splat(0x80);
        var o: usize = 0;
        for (0..4) |k| {
            if (mask >> k & 1 == 0) continue;
            for (0..4) |b| s[o + b] = 4 * k + b;
            o += 4;
        }
    }
    break :blk shuffles;
};

fn utf16ToUtf32Impl(comptime e: Endian, comptime checked: bool, src: []const u16, dst: []u32) Result {
    const U = @Vector(16, u16);
    const run = struct {
        fn f(s: []const u16, d: []u32) Result {
            if (checked) return scalar.utf16ToUtf32(e, s, d);
            return .ok(scalar.validUtf16ToUtf32(e, s, d));
        }
    }.f;
    var p: usize = 0;
    var o: usize = 0;
    var steps: Steps = .{};
    if (use_simd) while (true) {
        while (src.len - p >= 16 and dst.len - o >= 16) {
            const v = load16(e, 16, src, p);
            if (!@reduce(.Or, v & splat(U, 0xF800) == splat(U, 0xD800))) {
                store(u32, native, dst, o, v);
                p += 16;
                o += 16;
                continue;
            }
            if (!fast_shuffle) {
                break;
            }
            if (src.len - p < 17) break;
            const d = decode16(checked, v, load16(e, 16, src, p + 1)) orelse break;
            const c: [16]u32 = d.cp;
            const take: u16 = simd.bitmask(d.take);
            inline for (0..4) |g| {
                const keep: u4 = @truncate(take >> 4 * g);
                const lanes: @Vector(4, u32) = c[4 * g ..][0..4].*;
                const kept = simd.lookup16(@bitCast(lanes), loadVolatile(&compress32[keep]));
                dst[o..][0..4].* = @as(@Vector(4, u32), @bitCast(kept));
                o += @popCount(keep);
            }
            p += d.consumed;
        }
        if (fast_shuffle or !(src.len - p >= 16 and dst.len - o >= 16)) break;
        const end = utf16Boundary(e, src, p, @min(steps.next(p), src.len - p));
        if (scalarStep(run, src, end, dst, &p, &o, &steps)) |r| return r;
    };
    return tail(run(src[p..], dst[o..]), p, o);
}

// UTF-32 to UTF-16.

fn utf32ToUtf16Impl(comptime e: Endian, comptime checked: bool, src: []const u32, dst: []u16) Result {
    const run = struct {
        fn f(s: []const u32, d: []u16) Result {
            if (checked) return scalar.utf32ToUtf16(e, s, d);
            return .ok(scalar.validUtf32ToUtf16(e, s, d));
        }
    }.f;
    const W = @Vector(16, u32);
    const U32x4 = @Vector(4, u32);
    var p: usize = 0;
    var o: usize = 0;
    var steps: Steps = .{};
    if (use_simd) while (true) {
        while (src.len - p >= 16 and dst.len - o >= 32) {
            const v = simd.load(u32, src[p..]);
            const surrogates = v & splat(W, 0xFFFFF800) == splat(W, 0xD800);
            if (checked and @reduce(.Or, (v > splat(W, 0x10FFFF)) != surrogates)) break;
            if (below(0x10000, v)) {
                store(u16, e, dst, o, v);
                p += 16;
                o += 16;
                continue;
            }
            if (!fast_shuffle) {
                break;
            }
            const c: [16]u32 = v;
            inline for (0..4) |g| {
                const cp: U32x4 = c[4 * g ..][0..4].*;
                const pairs = cp >= splat(U32x4, 0x10000);
                const mask = mask4(pairs);
                const s = cp -% splat(U32x4, 0x10000);
                const pair = (splat(U32x4, 0xD800) | s >> splat(U32x4, 10)) |
                    (splat(U32x4, 0xDC00) | (s & splat(U32x4, 0x3FF))) << splat(U32x4, 16);
                const units = simd.lookup16(@bitCast(@select(u32, pairs, pair, cp)), loadVolatile(&utf16_pairs[mask]));
                store(u16, e, dst, o, @as(@Vector(8, u16), @bitCast(units)));
                o += 4 + @as(usize, @popCount(mask));
            }
            p += 16;
        }
        if (fast_shuffle or !(src.len - p >= 16 and dst.len - o >= 32)) break;
        if (scalarStep(run, src, p + @min(steps.next(p), src.len - p), dst, &p, &o, &steps)) |r| return r;
    };
    return tail(run(src[p..], dst[o..]), p, o);
}

// To Latin-1 from UTF-16 and UTF-32: narrowing, once no unit is above 0xFF.

fn utf16ToLatin1Impl(comptime e: Endian, comptime checked: bool, src: []const u16, dst: []u8) Result {
    var p: usize = 0;
    if (use_simd) while (src.len - p >= 32 and dst.len - p >= 32) {
        const v = load16(e, 32, src, p);
        if (checked and !below(0x100, v)) break;
        dst[p..][0..32].* = @as(@Vector(32, u8), @truncate(v));
        p += 32;
    };
    if (checked) return tail(scalar.utf16ToLatin1(e, src[p..], dst[p..]), p, p);
    return .ok(p + scalar.validUtf16ToLatin1(e, src[p..], dst[p..]));
}

fn utf32ToLatin1Impl(comptime checked: bool, src: []const u32, dst: []u8) Result {
    var p: usize = 0;
    if (use_simd) while (src.len - p >= 16 and dst.len - p >= 16) {
        const v = simd.load(u32, src[p..]);
        if (checked and !below(0x100, v)) break;
        dst[p..][0..16].* = @as(V16, @truncate(v));
        p += 16;
    };
    if (checked) return tail(scalar.utf32ToLatin1(src[p..], dst[p..]), p, p);
    return .ok(p + scalar.validUtf32ToLatin1(src[p..], dst[p..]));
}

// UTF-16 byte-order swap: a copy, validated like UTF-16 to UTF-8.

fn utf16SwapImpl(comptime e: Endian, comptime checked: bool, src: []const u16, dst: []u16) Result {
    const U = @Vector(16, u16);
    var p: usize = 0;
    if (use_simd) while (src.len - p >= 16 and dst.len - p >= 16) {
        const raw: U = src[p..][0..16].*;
        dst[p..][0..16].* = @byteSwap(raw);
        var consumed: usize = 16;
        if (checked) {
            const v = if (e == native) raw else @byteSwap(raw);
            if (@reduce(.Or, v & splat(U, 0xF800) == splat(U, 0xD800))) {
                if (src.len - p < 17) break;
                const d = decode16(true, v, load16(e, 16, src, p + 1)) orelse break;
                consumed = d.consumed;
            }
        }
        p += consumed;
    };
    if (checked) return tail(scalar.utf16ToUtf16Swapped(e, src[p..], dst[p..]), p, p);
    return .ok(p + scalar.validUtf16ToUtf16Swapped(src[p..], dst[p..]));
}

// Latin-1 to UTF-8, UTF-16, and UTF-32.

fn latin1ToUtf8Impl(comptime checked: bool, src: []const u8, dst: []u8) Result {
    const run = struct {
        fn f(s: []const u8, d: []u8) Result {
            if (checked) return scalar.latin1ToUtf8(s, d);
            return .ok(scalar.validLatin1ToUtf8(s, d));
        }
    }.f;
    var p: usize = 0;
    var o: usize = 0;
    var steps: Steps = .{};
    if (use_simd) while (true) {
        while (src.len - p >= 16 and dst.len - o >= 32) {
            if (src.len - p >= 64 and dst.len - o >= 64) {
                const block = simd.load(u8, src[p..]);
                if (below(0x80, block)) {
                    dst[o..][0..64].* = block;
                    p += 64;
                    o += 64;
                    continue;
                }
            }
            const w = simd.load16(src[p..]);
            if (below(0x80, w)) {
                dst[o..][0..16].* = w;
                o += 16;
            } else if (!fast_shuffle) {
                break;
            } else {
                const a: [16]u8 = w;
                utf8From2(@as(@Vector(8, u8), a[0..8].*), dst, &o);
                utf8From2(@as(@Vector(8, u8), a[8..16].*), dst, &o);
            }
            p += 16;
        }
        if (fast_shuffle or !(src.len - p >= 16 and dst.len - o >= 32)) break;
        if (scalarStep(run, src, p + @min(steps.next(p), src.len - p), dst, &p, &o, &steps)) |r| return r;
    };
    return tail(run(src[p..], dst[o..]), p, o);
}

fn latin1ToUnits(comptime T: type, comptime e: Endian, comptime checked: bool, src: []const u8, dst: []T) Result {
    var p: usize = 0;
    if (use_simd) while (src.len - p >= 16 and dst.len - p >= 16) {
        store(T, e, dst, p, @as(V16, src[p..][0..16].*));
        p += 16;
    };
    if (T == u16) {
        if (checked) return tail(scalar.latin1ToUtf16(e, src[p..], dst[p..]), p, p);
        return .ok(p + scalar.validLatin1ToUtf16(e, src[p..], dst[p..]));
    }
    if (checked) return tail(scalar.latin1ToUtf32(src[p..], dst[p..]), p, p);
    return .ok(p + scalar.validLatin1ToUtf32(src[p..], dst[p..]));
}

// Tests: every path against the scalar reference, on valid text of every
// mix, with every error at every position, and with output buffers of
// exactly the needed size and smaller.

const testing = std.testing;
const length = @import("length.zig");
const Self = @This();

const Format = enum {
    utf8,
    utf16le,
    utf16be,
    utf32,
    latin1,

    fn Unit(comptime f: Format) type {
        return switch (f) {
            .utf8, .latin1 => u8,
            .utf16le, .utf16be => u16,
            .utf32 => u32,
        };
    }

    fn title(comptime f: Format) []const u8 {
        const name = @tagName(f);
        return [_]u8{std.ascii.toUpper(name[0])} ++ name[1..];
    }
};

/// The public conversion `from` to `to`, checked or valid, by name.
fn simdConvert(
    comptime from: Format,
    comptime to: Format,
    comptime checked: bool,
    src: []const from.Unit(),
    dst: []to.Unit(),
) Result {
    if (checked) return @field(Self, @tagName(from) ++ "To" ++ to.title())(src, dst);
    return .ok(@field(Self, "valid" ++ from.title() ++ "To" ++ to.title())(src, dst));
}

/// The scalar reference for the same conversion.
fn refConvert(
    comptime from: Format,
    comptime to: Format,
    comptime checked: bool,
    src: []const from.Unit(),
    dst: []to.Unit(),
) Result {
    const s = scalar;
    const e: Endian = if (from == .utf16be or to == .utf16be) .big else .little;
    if (checked) return switch (from) {
        .utf8 => switch (to) {
            .utf16le, .utf16be => s.utf8ToUtf16(e, src, dst),
            .utf32 => s.utf8ToUtf32(src, dst),
            .latin1 => s.utf8ToLatin1(src, dst),
            .utf8 => unreachable,
        },
        .utf16le, .utf16be => switch (to) {
            .utf8 => s.utf16ToUtf8(e, src, dst),
            .utf32 => s.utf16ToUtf32(e, src, dst),
            .latin1 => s.utf16ToLatin1(e, src, dst),
            .utf16le, .utf16be => s.utf16ToUtf16Swapped(if (from == .utf16be) .big else .little, src, dst),
        },
        .utf32 => switch (to) {
            .utf8 => s.utf32ToUtf8(src, dst),
            .utf16le, .utf16be => s.utf32ToUtf16(e, src, dst),
            .latin1 => s.utf32ToLatin1(src, dst),
            .utf32 => unreachable,
        },
        .latin1 => switch (to) {
            .utf8 => s.latin1ToUtf8(src, dst),
            .utf16le, .utf16be => s.latin1ToUtf16(e, src, dst),
            .utf32 => s.latin1ToUtf32(src, dst),
            .latin1 => unreachable,
        },
    };
    return .ok(switch (from) {
        .utf8 => switch (to) {
            .utf16le, .utf16be => s.validUtf8ToUtf16(e, src, dst),
            .utf32 => s.validUtf8ToUtf32(src, dst),
            .latin1 => s.validUtf8ToLatin1(src, dst),
            .utf8 => unreachable,
        },
        .utf16le, .utf16be => switch (to) {
            .utf8 => s.validUtf16ToUtf8(e, src, dst),
            .utf32 => s.validUtf16ToUtf32(e, src, dst),
            .latin1 => s.validUtf16ToLatin1(e, src, dst),
            .utf16le, .utf16be => s.validUtf16ToUtf16Swapped(src, dst),
        },
        .utf32 => switch (to) {
            .utf8 => s.validUtf32ToUtf8(src, dst),
            .utf16le, .utf16be => s.validUtf32ToUtf16(e, src, dst),
            .latin1 => s.validUtf32ToLatin1(src, dst),
            .utf32 => unreachable,
        },
        .latin1 => switch (to) {
            .utf8 => s.validLatin1ToUtf8(src, dst),
            .utf16le, .utf16be => s.validLatin1ToUtf16(e, src, dst),
            .utf32 => s.validLatin1ToUtf32(src, dst),
            .latin1 => unreachable,
        },
    });
}

/// The `length` function that sizes the conversion's output.
fn needed(comptime from: Format, comptime to: Format, src: []const from.Unit()) usize {
    if ((from == .utf16le or from == .utf16be) and (to == .utf16le or to == .utf16be)) return src.len;
    const target = comptime switch (to) {
        .utf16le, .utf16be => "utf16",
        else => @tagName(to),
    };
    const source = comptime if (to == .latin1 and from != .utf8) switch (from) {
        .utf16le, .utf16be => "Utf16",
        else => from.title(),
    } else from.title();
    return @field(length, target ++ "From" ++ source)(src);
}

const conversions = blk: {
    var list: []const [2]Format = &.{};
    for (std.enums.values(Format)) |from| for (std.enums.values(Format)) |to| {
        if (from == to or (from == .utf16be and to == .utf16be)) continue;
        list = list ++ [_][2]Format{.{ from, to }};
    };
    break :blk list;
};

const Mix = enum { ascii, latin1, two_byte, cjk, emoji, mixed };

fn randomCodePoint(r: std.Random, mix: Mix) u32 {
    const ascii = r.uintLessThan(u32, 0x80);
    return switch (mix) {
        .ascii => ascii,
        .latin1 => if (r.boolean()) ascii else r.intRangeLessThan(u32, 0x80, 0x100),
        .two_byte => if (r.uintLessThan(u8, 8) == 0) ascii else r.intRangeLessThan(u32, 0x80, 0x800),
        .cjk => if (r.uintLessThan(u8, 8) == 0) ascii else r.intRangeLessThan(u32, 0x3000, 0xA000),
        .emoji => if (r.uintLessThan(u8, 8) == 0) ascii else r.intRangeLessThan(u32, 0x1F300, 0x1FB00),
        .mixed => switch (r.uintLessThan(u8, 5)) {
            0 => ascii,
            1 => r.intRangeLessThan(u32, 0x80, 0x800),
            2 => r.intRangeLessThan(u32, 0x800, 0xD800),
            3 => r.intRangeLessThan(u32, 0xE000, 0x10000),
            else => r.intRangeLessThan(u32, 0x10000, 0x110000),
        },
    };
}

/// One text in every format: valid, except Latin-1, which is null when the
/// text does not fit it.
const Text = struct {
    buf8: [4096]u8 = undefined,
    buf16le: [2048]u16 = undefined,
    buf16be: [2048]u16 = undefined,
    buf32: [1024]u32 = undefined,
    buf_latin1: [1024]u8 = undefined,
    n8: usize = 0,
    n16: usize = 0,
    n32: usize = 0,
    latin1: bool = false,

    fn set(t: *Text, cps: []const u32) void {
        @memcpy(t.buf32[0..cps.len], cps);
        t.n32 = cps.len;
        t.n8 = scalar.validUtf32ToUtf8(cps, &t.buf8);
        t.n16 = scalar.validUtf32ToUtf16(.little, cps, &t.buf16le);
        _ = scalar.validUtf32ToUtf16(.big, cps, &t.buf16be);
        t.latin1 = scalar.utf32ToLatin1(cps, &t.buf_latin1).err == .none;
    }

    fn get(t: *Text, comptime f: Format) []f.Unit() {
        return switch (f) {
            .utf8 => t.buf8[0..t.n8],
            .utf16le => t.buf16le[0..t.n16],
            .utf16be => t.buf16be[0..t.n16],
            .utf32 => t.buf32[0..t.n32],
            .latin1 => t.buf_latin1[0..t.n32],
        };
    }
};

/// Runs the conversion and its reference on `src` into buffers of `size`,
/// and expects the same result and the same output before any error.
fn expectSame(
    comptime from: Format,
    comptime to: Format,
    comptime checked: bool,
    src: []const from.Unit(),
    size: usize,
) !void {
    const T = to.Unit();
    var want_buf: [8192]T = undefined;
    var got_buf: [8192]T = undefined;
    const want = refConvert(from, to, checked, src, want_buf[0..size]);
    const got = simdConvert(from, to, checked, src, got_buf[0..size]);
    errdefer std.debug.print("{t} to {t} ({s}), {d} units into {d}: want {t}@{d}, got {t}@{d}\n", .{
        from, to, if (checked) "checked" else "valid", src.len, size, want.err, want.count, got.err, got.count,
    });
    try testing.expectEqual(want, got);
    // On failure the output holds the conversion of the input before the
    // error.
    const written = if (want.err == .none)
        want.count
    else
        refConvert(from, to, true, src[0..want.count], &want_buf).count;
    try testing.expectEqualSlices(T, want_buf[0..written], got_buf[0..written]);
}

test "every conversion matches the scalar reference on valid text" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    var text: Text = .{};
    var cps: [1024]u32 = undefined;
    for (std.enums.values(Mix)) |mix| {
        var n: usize = 0;
        while (n < 1024) : (n += if (n < 160) 1 else r.intRangeAtMost(usize, 50, 300)) {
            // A run of ASCII first shifts every later character, and every
            // surrogate pair, across block boundaries.
            const shift = r.uintLessThan(usize, @min(n + 1, 20));
            for (cps[0..n], 0..) |*cp, i| cp.* = if (i < shift) 'a' else randomCodePoint(r, mix);
            text.set(cps[0..n]);
            inline for (conversions) |pair| {
                const from, const to = pair;
                if (from != .latin1 or text.latin1) {
                    const src = text.get(from);
                    var scratch: [4096]to.Unit() = undefined;
                    const need = refConvert(from, to, true, src, &scratch).count;
                    const fits = to != .latin1 or text.latin1;
                    if (fits) {
                        try testing.expectEqual(need, needed(from, to, src));
                        try expectSame(from, to, true, src, need);
                        try expectSame(from, to, false, src, need);
                    }
                    // Too small, by one and by a random amount.
                    if (need > 0) {
                        try expectSame(from, to, true, src, need - 1);
                        try expectSame(from, to, true, src, r.uintLessThan(usize, need));
                    }
                }
            }
        }
    }
}

/// Overwrites `src` at `i` with as much of `pattern` as fits.
fn corrupt(comptime T: type, src: []T, i: usize, pattern: []const T) void {
    const n = @min(pattern.len, src.len - i);
    @memcpy(src[i..][0..n], pattern[0..n]);
}

fn expectErrorsMatch(comptime from: Format, text: *Text, patterns: []const []const from.Unit()) !void {
    const clean = text.get(from);
    var src_buf: [4096]from.Unit() = undefined;
    const src = src_buf[0..clean.len];
    for (0..src.len) |i| for (patterns) |pattern| {
        @memcpy(src, clean);
        corrupt(from.Unit(), src, i, pattern);
        inline for (conversions) |pair| if (pair[0] == from) {
            try expectSame(from, pair[1], true, src, needed(from, pair[1], src));
        };
    };
}

test "every error kind at every position matches the scalar reference" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    var text: Text = .{};
    var cps: [200]u32 = undefined;
    const utf8_patterns = [_][]const u8{
        "\x80", "\xbf", // too long
        "\xf8",         "\xff", // header bits
        "\xc0\x80",     "\xc1\xbf",
        "\xe0\x80\x80", "\xe0\x9f\xbf",
        "\xf0\x80\x80\x80", "\xf0\x8f\xbf\xbf", // overlong
        "\xed\xa0\x80",     "\xed\xbf\xbf", // surrogate
        "\xf4\x90\x80\x80", "\xf5\x80\x80\x80",
        "\xf7\xbf\xbf\xbf", // too large
        "\xc2A",
        "\xe2\x82A",
        "\xf0\x9fA",
        "\xf0\x9f\x98", // too short
        "\xc3\xa9",
        "\xc4\x80",
        "\xe2\x82\xac", "\xf0\x9f\x98\x80", // valid, and too large for Latin-1
    };
    const utf16_patterns = [_][]const u16{
        &.{0xD800}, &.{0xDBFF}, &.{0xDC00}, &.{0xDFFF}, &.{ 0xDC00, 0xD800 }, &.{ 0xD83D, 0xDE00 },
        &.{0x00E9}, &.{0x0100}, &.{0xFFFF},
    };
    const utf32_patterns = [_][]const u32{
        &.{0xD800}, &.{0xDFFF}, &.{0x110000}, &.{0xFFFFFFFF}, &.{0x100}, &.{0xFF}, &.{0x10FFFF},
    };
    for ([_]Mix{ .latin1, .cjk, .mixed }) |mix| {
        for (&cps) |*cp| cp.* = randomCodePoint(r, mix);
        text.set(&cps);
        try expectErrorsMatch(.utf8, &text, &utf8_patterns);
        try expectErrorsMatch(.utf32, &text, &utf32_patterns);
        // Swapping the pattern's bytes gives the same code units big-endian.
        try expectErrorsMatch(.utf16le, &text, &utf16_patterns);
        var be_patterns: [utf16_patterns.len][2]u16 = undefined;
        var be: [utf16_patterns.len][]const u16 = undefined;
        for (utf16_patterns, &be_patterns, &be) |p, *bp, *b| {
            for (p, bp[0..p.len]) |unit, *swapped| swapped.* = @byteSwap(unit);
            b.* = bp[0..p.len];
        }
        try expectErrorsMatch(.utf16be, &text, &be);
    }
}
