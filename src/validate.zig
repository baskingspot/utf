//! Validation of UTF-8, ASCII, UTF-16LE/BE, and UTF-32, with SIMD.
//!
//! Each function checks 64-byte blocks and stops at the first block that
//! fails. Inputs of four blocks or more check their first block unaligned
//! and the rest from the next 64-byte boundary, so no load splits a cache
//! line; a final partial block is the last 64 bytes of the input,
//! overlapping the block before it. Inputs shorter than a block are
//! zero-padded into one. The `WithErrors` forms find the position in the
//! failing block: ASCII, UTF-16, and UTF-32 from its lane masks, UTF-8 by
//! rerunning the scalar validator in `scalar.zig` from the last character
//! boundary before it, so error kinds and positions are exactly the scalar
//! validators'.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const simd = @import("simd.zig");
const dispatch = @import("dispatch.zig");
const scalar = @import("scalar.zig");
const Result = @import("result.zig").Result;
const Error = @import("result.zig").Error;

const Bytes = simd.Block(u8);

/// Reports whether `bytes` is well-formed UTF-8.
pub fn utf8(bytes: []const u8) bool {
    return dispatch.call(@src(), utf8Kernel, .{bytes});
}

fn utf8Kernel(bytes: []const u8) bool {
    if (simd.isa == .generic) return utf8WithErrorsKernel(bytes).err == .none;
    return utf8BadBlock(bytes) == none;
}

/// Validates UTF-8. On failure `count` is the index of the first byte of the
/// ill-formed sequence, and `err` says what is wrong with it.
pub fn utf8WithErrors(bytes: []const u8) Result {
    return dispatch.call(@src(), utf8WithErrorsKernel, .{bytes});
}

fn utf8WithErrorsKernel(bytes: []const u8) Result {
    const pos = utf8BadBlock(bytes);
    if (pos == none) return .ok(bytes.len);
    // Every byte before `pos` passed, so the character containing the byte
    // before it starts at most four bytes back.
    var start = pos;
    while (start > 0 and pos - start < 4) {
        start -= 1;
        if (bytes[start] & 0xC0 != 0x80) break;
    }
    // ASCII from a character boundary is whole characters, and every error
    // starts at a byte above 0x7F, so the scalar validator can start there.
    start = firstHigh(bytes, start);
    return offset(scalar.validateUtf8(bytes[start..]), start);
}

/// Reports whether every byte is below 0x80.
pub fn ascii(bytes: []const u8) bool {
    return dispatch.call(@src(), asciiKernel, .{bytes});
}

fn asciiKernel(bytes: []const u8) bool {
    return asciiBadBlock(bytes) == none;
}

/// Validates ASCII. On failure `count` is the index of the first byte above
/// 0x7F.
pub fn asciiWithErrors(bytes: []const u8) Result {
    return dispatch.call(@src(), asciiWithErrorsKernel, .{bytes});
}

fn asciiWithErrorsKernel(bytes: []const u8) Result {
    const pos = asciiBadBlock(bytes);
    if (pos == none) return .ok(bytes.len);
    return .fail(.not_ascii, firstHigh(bytes, pos));
}

/// Reports whether `units` is well-formed UTF-16 stored little-endian.
pub fn utf16le(units: []const u16) bool {
    return dispatch.call(@src(), utf16leKernel, .{units});
}

fn utf16leKernel(units: []const u16) bool {
    return utf16BadBlock(.little, units) == none;
}

/// Validates UTF-16 stored little-endian. On failure `count` is the index of
/// the unpaired surrogate.
pub fn utf16leWithErrors(units: []const u16) Result {
    return dispatch.call(@src(), utf16leWithErrorsKernel, .{units});
}

fn utf16leWithErrorsKernel(units: []const u16) Result {
    return utf16WithErrors(.little, units);
}

/// Reports whether `units` is well-formed UTF-16 stored big-endian.
pub fn utf16be(units: []const u16) bool {
    return dispatch.call(@src(), utf16beKernel, .{units});
}

fn utf16beKernel(units: []const u16) bool {
    return utf16BadBlock(.big, units) == none;
}

/// Validates UTF-16 stored big-endian. On failure `count` is the index of
/// the unpaired surrogate.
pub fn utf16beWithErrors(units: []const u16) Result {
    return dispatch.call(@src(), utf16beWithErrorsKernel, .{units});
}

fn utf16beWithErrorsKernel(units: []const u16) Result {
    return utf16WithErrors(.big, units);
}

/// Reports whether every value is a Unicode scalar value: at most U+10FFFF
/// and not a surrogate.
pub fn utf32(units: []const u32) bool {
    return dispatch.call(@src(), utf32Kernel, .{units});
}

fn utf32Kernel(units: []const u32) bool {
    return utf32BadBlock(units) == none;
}

/// Validates UTF-32 in native byte order. On failure `count` is the index of
/// the first value above U+10FFFF (`too_large`) or in the surrogate range
/// (`surrogate`).
pub fn utf32WithErrors(units: []const u32) Result {
    return dispatch.call(@src(), utf32WithErrorsKernel, .{units});
}

fn utf32WithErrorsKernel(units: []const u32) Result {
    const pos = utf32BadBlock(units);
    if (pos == none) return .ok(units.len);
    const v = if (units.len < n32) loadShort(u32, units) else simd.load(u32, units[pos..]);
    // Lanes before the first bad one passed, in an overlapping last block too.
    const at = pos + @ctz(simd.bitmask(utf32Key(v) > @as(Units32, @splat(utf32_key_max))));
    return .fail(if (units[at] > 0x10FFFF) .too_large else .surrogate, at);
}

fn offset(r: Result, start: usize) Result {
    return .{ .err = r.err, .count = r.count + start };
}

inline fn splat(x: u8) Bytes {
    return @splat(x);
}

inline fn isAscii(v: Bytes) bool {
    return !@reduce(.Or, v >= splat(0x80));
}

inline fn any(v: Bytes) bool {
    return @reduce(.Or, v != splat(0));
}

/// The block at `src[0]`, which must be 64-byte aligned: an aligned load
/// can be an operand on SSE.
inline fn loadAligned(comptime T: type, src: []const T) simd.Block(T) {
    const n = @typeInfo(simd.Block(T)).vector.len;
    return @as(*align(64) const simd.Block(T), @ptrCast(@alignCast(src[0..n]))).*;
}

/// Code units from `p` to the first 64-byte boundary after it, 1 to a
/// block's worth.
inline fn toBoundary(comptime T: type, p: [*]const T) usize {
    return (64 - @intFromPtr(p) % 64) / @sizeOf(T);
}

/// AVX-512 loads a short input with one masked load, which reads no byte
/// past the input; elsewhere `simd.loadPartial` builds the block in
/// registers. The intrinsic needs the LLVM backend.
const masked_load = simd.isa == .avx512 and builtin.zig_backend == .stage2_llvm;
extern fn @"llvm.masked.load.v64i8.p0"(*const anyopaque, u32, @Vector(64, bool), @Vector(64, u8)) @Vector(64, u8);

/// A slice shorter than a block, zero-padded.
inline fn loadShort(comptime T: type, src: []const T) simd.Block(T) {
    if (!masked_load) return simd.loadPartial(T, src);
    const len = src.len * @sizeOf(T);
    // The pointer of an empty slice may be anything.
    if (len == 0) return @splat(0);
    const mask: u64 = (@as(u64, 1) << @intCast(len)) - 1;
    return @bitCast(@"llvm.masked.load.v64i8.p0"(src.ptr, 1, @bitCast(mask), @splat(0)));
}

/// Whether at most 64 bytes are all ASCII.
inline fn isAsciiShort(s: []const u8) bool {
    const len = s.len;
    if (len >= 16) {
        const V = @Vector(16, u8);
        var acc = simd.load16(s) | simd.load16(s[len - 16 ..]);
        if (len > 32) acc |= simd.load16(s[16..]) | simd.load16(s[len - 32 ..]);
        return !@reduce(.Or, acc >= @as(V, @splat(0x80)));
    }
    const x: u64 = if (len >= 8)
        std.mem.readInt(u64, s[0..8], .little) | std.mem.readInt(u64, s[len - 8 ..][0..8], .little)
    else if (len >= 4)
        std.mem.readInt(u32, s[0..4], .little) | std.mem.readInt(u32, s[len - 4 ..][0..4], .little)
    else if (len > 0)
        s[0] | s[len / 2] | s[len - 1]
    else
        0;
    return x & 0x8080_8080_8080_8080 == 0;
}

/// What the `BadBlock` functions return when every block passes. They
/// return a plain index: an optional one returned from an inline function
/// went through memory, loaded back from the stack or a constant, which
/// cost short inputs up to 10%.
const none = std.math.maxInt(usize);

/// The index of the first block that is not all ASCII, or `none`.
inline fn asciiBadBlock(bytes: []const u8) usize {
    if (bytes.len <= 64) return if (isAsciiShort(bytes)) none else 0;
    const i = asciiPrefix(bytes, true);
    return if (i == bytes.len) none else i;
}

/// The length of a prefix of `bytes`, at least 64 long, that is all ASCII:
/// `bytes.len` when the whole input is, else an index at or before the
/// first byte above 0x7F. Inputs longer than four blocks check their first
/// block, then aligned groups of four blocks with one test each. Up to four
/// blocks, `whole` tests overlapping loads of the whole input at once, for
/// ASCII validation; else each block in turn, so UTF-8 validation of text
/// that is not ASCII stops at its first block, which measured 11-25%
/// faster there.
inline fn asciiPrefix(bytes: []const u8, comptime whole: bool) usize {
    const len = bytes.len;
    if (len <= 256) {
        if (whole) {
            var acc = simd.load(u8, bytes) | simd.load(u8, bytes[len - 64 ..]);
            if (len > 128) acc |= simd.load(u8, bytes[64..]) | simd.load(u8, bytes[len - 128 ..]);
            return if (isAscii(acc)) len else 0;
        }
        var i: usize = 0;
        while (i + 64 <= len) : (i += 64) {
            if (!isAscii(simd.load(u8, bytes[i..]))) return i;
        }
        return if (isAscii(simd.load(u8, bytes[len - 64 ..]))) len else i;
    }
    if (!isAscii(simd.load(u8, bytes))) return 0;
    var i = toBoundary(u8, bytes.ptr);
    while (i + 256 <= len) : (i += 256) {
        const v = loadAligned(u8, bytes[i..]) | loadAligned(u8, bytes[i + 64 ..]) |
            loadAligned(u8, bytes[i + 128 ..]) | loadAligned(u8, bytes[i + 192 ..]);
        if (!isAscii(v)) break;
    }
    while (i + 64 <= len) : (i += 64) {
        if (!isAscii(loadAligned(u8, bytes[i..]))) return i;
    }
    return if (isAscii(simd.load(u8, bytes[len - 64 ..]))) len else i;
}

/// The index of the first byte above 0x7F at or after `from`; there must
/// be one.
fn firstHigh(bytes: []const u8, from: usize) usize {
    const len = bytes.len;
    if (len < 64) return from + @ctz(simd.bitmask(loadShort(u8, bytes) >= splat(0x80)) >> @intCast(from));
    var i = from;
    while (i + 64 <= len) : (i += 64) {
        const m = simd.bitmask(simd.load(u8, bytes[i..]) >= splat(0x80));
        if (m != 0) return i + @ctz(m);
    }
    const m = simd.bitmask(simd.load(u8, bytes[len - 64 ..]) >= splat(0x80));
    return i + @ctz(m >> @intCast(i + 64 - len));
}

// Keiser and Lemire's lookup algorithm. Each byte pair (previous byte,
// current byte) is classified by three nibble lookups; a bit survives the
// AND only when all three nibbles allow that error.
const too_short: u8 = 1 << 0; // 11______ 0_______, 11______ 11______
const too_long: u8 = 1 << 1; // 0_______ 10______
const overlong_3: u8 = 1 << 2; // 11100000 100_____
const too_large: u8 = 1 << 3; // 11110100 1001____, 11110100 101_____, 11110101+ 1001____+
const surrogate: u8 = 1 << 4; // 11101101 101_____
const overlong_2: u8 = 1 << 5; // 1100000_ 10______
const too_large_1000: u8 = 1 << 6; // 11110101+ 1000____
const overlong_4: u8 = 1 << 6; // 11110000 1000____
const two_conts: u8 = 1 << 7; // 10______ 10______
// Pairs whose meaning depends on the second byte alone.
const carry = too_short | too_long | two_conts;

const byte_1_high = [16]u8{
    // 0_______: ASCII
    too_long,
    too_long,
    too_long,
    too_long,
    too_long,
    too_long,
    too_long,
    too_long,
    // 10______: continuation
    two_conts,
    two_conts,
    two_conts,
    two_conts,
    // 1100____, 1101____: 2-byte lead
    too_short | overlong_2,
    too_short,
    // 1110____: 3-byte lead
    too_short | overlong_3 | surrogate,
    // 1111____: 4-byte lead, or 11111___
    too_short | too_large | too_large_1000 | overlong_4,
};

const byte_1_low = [16]u8{
    // ____0000
    carry | overlong_3 | overlong_2 | overlong_4,
    // ____0001
    carry | overlong_2,
    // ____001_
    carry,
    carry,
    // ____0100
    carry | too_large,
    // ____0101 to ____1100
    carry | too_large | too_large_1000,
    carry | too_large | too_large_1000,
    carry | too_large | too_large_1000,
    carry | too_large | too_large_1000,
    carry | too_large | too_large_1000,
    carry | too_large | too_large_1000,
    carry | too_large | too_large_1000,
    carry | too_large | too_large_1000,
    // ____1101
    carry | too_large | too_large_1000 | surrogate,
    // ____1110, ____1111
    carry | too_large | too_large_1000,
    carry | too_large | too_large_1000,
};

const byte_2_high = [16]u8{
    // ________ 0_______
    too_short,
    too_short,
    too_short,
    too_short,
    too_short,
    too_short,
    too_short,
    too_short,
    // ________ 1000____
    too_long | overlong_2 | two_conts | overlong_3 | too_large_1000 | overlong_4,
    // ________ 1001____
    too_long | overlong_2 | two_conts | overlong_3 | too_large,
    // ________ 101_____
    too_long | overlong_2 | two_conts | surrogate | too_large,
    too_long | overlong_2 | two_conts | surrogate | too_large,
    // ________ 11______
    too_short,
    too_short,
    too_short,
    too_short,
};

// The bytes one, two, and three back come from three unaligned loads on
// AVX2 and SSE, where that beat shifting them in from the previous block by
// 10% and 17%; on AVX-512 the loads, which all cross a cache line, lost 11%
// (docs/slop/results/validate-20261031.md). NEON and the generic path are
// unmeasured and shift.
const prev_by_load = simd.isa == .avx2 or simd.isa == .sse;

/// Error bits for the pairs ending in `cur`; `before` is the block before it.
inline fn utf8Errors(cur: Bytes, before: Bytes) Bytes {
    return utf8ErrorsPrev(cur, simd.prev(1, cur, before), simd.prev(2, cur, before), simd.prev(3, cur, before));
}

/// `utf8Errors` with the input shifted by one, two, and three bytes given.
inline fn utf8ErrorsPrev(cur: Bytes, prev1: Bytes, prev2: Bytes, prev3: Bytes) Bytes {
    const special = simd.lookup16(byte_1_high, prev1 >> @splat(4)) &
        simd.lookup16(byte_1_low, prev1 & splat(0x0F)) &
        simd.lookup16(byte_2_high, cur >> @splat(4));
    // A continuation after a continuation is right only as the third or
    // fourth byte of a sequence, which is where bit 7 here is set.
    const must_be_23 = (prev2 -| splat(0xE0 - 0x80)) | (prev3 -| splat(0xF0 - 0x80));
    return (must_be_23 & splat(0x80)) ^ special;
}

/// Nonzero where a lead in the block's last three bytes needs bytes beyond it.
inline fn utf8Incomplete(v: Bytes) Bytes {
    const max = comptime blk: {
        var m: [64]u8 = @splat(0xFF);
        m[61] = 0xF0 - 1;
        m[62] = 0xE0 - 1;
        m[63] = 0xC0 - 1;
        break :blk m;
    };
    return v -| @as(Bytes, max);
}

/// The index of the first 64-byte block that fails, or `none`. Every byte
/// before the returned index belongs to well-formed UTF-8, except that the
/// last character before it may be cut short. On the generic path, the first
/// block that is not ASCII.
inline fn utf8BadBlock(bytes: []const u8) usize {
    const zero = splat(0);
    if (bytes.len < 64) {
        if (isAsciiShort(bytes)) return none;
        if (simd.isa == .generic) return 0;
        // The zero padding ends any sequence the input cuts short.
        return if (!any(utf8Errors(loadShort(u8, bytes), zero))) none else 0;
    }
    // Leading ASCII blocks first, so ASCII text never loads the lookup
    // tables. Zero stands in for ASCII as context.
    var i = asciiPrefix(bytes, false);
    if (i == bytes.len) return none;
    // With no byte shuffle, emulating the three lookups ran at 0.5 GB/s on
    // x86-64 baseline, below the scalar validator, which takes over from
    // the first block that is not ASCII instead.
    if (simd.isa == .generic) return i;
    var before = zero;
    var incomplete = zero;
    if (i == 0 and bytes.len >= 4096) {
        // The first block, then the rest from the next 64-byte boundary,
        // like the ASCII prefix: 11-12% from 64 KiB, but the extra block
        // cost 5-7% at 1 KiB. The block at the boundary rechecks the pairs
        // it overlaps, and covers a sequence the first block cuts short,
        // unless it starts right after it.
        const cur: Bytes = simd.load(u8, bytes);
        if (any(utf8Errors(cur, zero))) return 0;
        i = toBoundary(u8, bytes.ptr);
        if (i == 64) {
            before = cur;
            incomplete = utf8Incomplete(cur);
        } else before = context(bytes, i);
    }
    while (i + 64 <= bytes.len) : (i += 64) {
        const cur: Bytes = simd.load(u8, bytes[i..]);
        if (isAscii(cur)) {
            if (any(incomplete)) return i;
            incomplete = zero;
        } else {
            const errors = if (prev_by_load and i >= 3)
                utf8ErrorsPrev(
                    cur,
                    simd.load(u8, bytes[i - 1 ..]),
                    simd.load(u8, bytes[i - 2 ..]),
                    simd.load(u8, bytes[i - 3 ..]),
                )
            else
                utf8Errors(cur, before);
            if (any(errors)) return i;
            incomplete = utf8Incomplete(cur);
        }
        before = cur;
    }
    if (i < bytes.len) {
        // The last 64 bytes, with the three bytes before them as context.
        // They recheck pairs already checked, which is harmless, and cover
        // the cut sequence `incomplete` was tracking. If they are all ASCII,
        // a sequence cut before them misses a byte at or before `last`,
        // which the loop above checked.
        const last = bytes.len - 64;
        const cur: Bytes = simd.load(u8, bytes[last..]);
        before = context(bytes, last);
        if (isAscii(cur)) return none;
        if (any(utf8Errors(cur, before))) return last;
        incomplete = utf8Incomplete(cur);
    }
    return if (any(incomplete)) bytes.len else none;
}

/// A block whose last lanes are the eight bytes before `pos`, or as many as
/// there are: the context for a block at `pos` that does not follow the
/// block before it. A stack array here would cost every call a realigned
/// stack frame.
inline fn context(bytes: []const u8, pos: usize) Bytes {
    var w: u64 = 0;
    if (pos >= 8) {
        w = std.mem.readInt(u64, bytes[pos - 8 ..][0..8], .little);
    } else for (bytes[0..pos], 8 - pos..) |c, j| {
        w |= @as(u64, c) << @intCast(8 * j);
    }
    const last8: @Vector(8, u8) = @bitCast(std.mem.nativeToLittle(u64, w));
    return @shuffle(u8, last8, @as(@Vector(8, u8), @splat(0)), lastLanes());
}

fn lastLanes() [64]i32 {
    var m: [64]i32 = @splat(-1);
    for (56..64) |i| m[i] = @intCast(i - 56);
    return m;
}

const Units16 = simd.Block(u16);
const n16 = @typeInfo(Units16).vector.len;
const Mask16 = @Int(.unsigned, n16);

fn utf16WithErrors(comptime endian: std.builtin.Endian, units: []const u16) Result {
    const pos = utf16BadBlock(endian, units);
    if (pos == none) return .ok(units.len);
    const len = units.len;
    // A high surrogate ends the input.
    if (pos == len) return .fail(.surrogate, len - 1);
    if (len < n16) {
        // The zero padding is not a surrogate.
        const s = surrogateMasks(endian, loadShort(u16, units));
        return .fail(.surrogate, @ctz((s.low & ~(s.high << 1)) | (s.high & ~(s.low >> 1))));
    }
    // The scalar validator stops at the first low surrogate with no high
    // one before it, or high one with no low one after it. Every unit
    // before the block passed, but for a high one just before it.
    const s = surrogateMasks(endian, simd.load(u16, units[pos..]));
    const pending = pos > 0 and isHigh(std.mem.toNative(u16, units[pos - 1], endian));
    if (pending and s.low & 1 == 0) return .fail(.surrogate, pos - 1);
    // A high one in the last lane pairs with the unit after the block, but
    // the block failed on an error in an earlier lane, or a low one there.
    const unfollowed = s.high & ~(s.low >> 1);
    return .fail(.surrogate, pos + @ctz((s.low & ~(s.high << 1 | @intFromBool(pending))) | unfollowed));
}

fn isHigh(unit: u16) bool {
    return unit & 0xFC00 == 0xD800;
}

const Surrogates = struct { high: Mask16, low: Mask16 };

/// The highs and lows of one block, each as a bit mask.
inline fn surrogateMasks(comptime endian: std.builtin.Endian, block: Units16) Surrogates {
    const v = if (endian == builtin.cpu.arch.endian()) block else @byteSwap(block);
    const top = v & @as(Units16, @splat(0xFC00));
    return .{
        .high = simd.bitmask(top == @as(Units16, @splat(0xD800))),
        .low = simd.bitmask(top == @as(Units16, @splat(0xDC00))),
    };
}

inline fn hasSurrogate(comptime endian: std.builtin.Endian, block: Units16) bool {
    return @reduce(.Or, surrogateKey(endian, block) == @as(Units16, @splat(0)));
}

/// Below `groupKeyMax(endian)` in the lanes that hold a surrogate. In
/// native order one subtraction, which takes its block from memory, where
/// `surrogateKey`'s AND and XOR became a ternary op that overwrites a copy
/// of a constant: 5-17% from 4 KiB.
inline fn groupKey(comptime endian: std.builtin.Endian, block: Units16) Units16 {
    if (endian != builtin.cpu.arch.endian()) return surrogateKey(endian, block);
    return block -% @as(Units16, @splat(0xD800));
}
fn groupKeyMax(comptime endian: std.builtin.Endian) u16 {
    return if (endian == builtin.cpu.arch.endian()) 0x800 else 1;
}

/// Zero in the lanes that hold a surrogate, in either byte order without
/// swapping the bytes.
inline fn surrogateKey(comptime endian: std.builtin.Endian, block: Units16) Units16 {
    const native = endian == builtin.cpu.arch.endian();
    return (block & @as(Units16, @splat(if (native) 0xF800 else 0x00F8))) ^
        @as(Units16, @splat(if (native) 0xD800 else 0x00D8));
}

/// Checks one block, given whether the unit before it is a high surrogate;
/// returns whether its last unit is one, or `bad_block` if it fails. Each low
/// surrogate must follow a high one, and each high one precede a low one.
inline fn utf16Block(comptime endian: std.builtin.Endian, block: Units16, pending: Mask16) Mask16 {
    if (!hasSurrogate(endian, block)) return if (pending != 0) bad_block else 0;
    const s = surrogateMasks(endian, block);
    if (s.low != (s.high << 1 | pending)) return bad_block;
    return s.high >> (n16 - 1);
}
const bad_block: Mask16 = 2;

/// The index of the first 32-unit block that fails, or `none`;
/// `units.len` when the input ends in a high surrogate.
inline fn utf16BadBlock(comptime endian: std.builtin.Endian, units: []const u16) usize {
    const len = units.len;
    if (len < n16) {
        // The zero padding is not a low surrogate, so a high one at the end
        // fails here.
        const block = loadShort(u16, units);
        if (!hasSurrogate(endian, block)) return none;
        const s = surrogateMasks(endian, block);
        return if (s.low != s.high << 1) 0 else none;
    }
    if (len <= 2 * n16) {
        // Up to two blocks, overlapping loads of the whole input with one
        // test for a surrogate anywhere, as most text has none.
        const max: Units16 = @splat(groupKeyMax(endian));
        const first = groupKey(endian, simd.load(u16, units));
        const key = @min(first, groupKey(endian, simd.load(u16, units[len - n16 ..])));
        if (!@reduce(.Or, key < max)) return none;
    }
    var pending: Mask16 = 0;
    var i: usize = 0;
    if (len >= 8 * n16) {
        // The first block, then groups from the next 64-byte boundary.
        if (utf16Block(endian, simd.load(u16, units), 0) == bad_block) return 0;
        i = toBoundary(u16, units.ptr);
        pending = @intFromBool(isHigh(std.mem.toNative(u16, units[i - 1], endian)));
    }
    // Groups of eight blocks, then one of four, with one test for a
    // surrogate in any of them.
    inline for ([_]usize{ 8, 4 }) |g| {
        while (i + g * n16 <= len) : (i += g * n16) {
            var key = groupKey(endian, simd.load(u16, units[i..]));
            inline for (1..g) |k| key = @min(key, groupKey(endian, simd.load(u16, units[i + k * n16 ..])));
            if (!@reduce(.Or, key < @as(Units16, @splat(groupKeyMax(endian))))) {
                if (pending != 0) return i;
                continue;
            }
            // The masks alone check a block; the test for a surrogate in
            // it only saves work on blocks without one.
            inline for (0..g) |k| {
                const j = i + k * n16;
                const s = surrogateMasks(endian, simd.load(u16, units[j..]));
                if (s.low != (s.high << 1 | pending)) return j;
                pending = s.high >> (n16 - 1);
            }
        }
    }
    while (i + n16 <= len) : (i += n16) {
        pending = utf16Block(endian, simd.load(u16, units[i..]), pending);
        if (pending == bad_block) return i;
    }
    if (i < len) {
        // The last 32 units, overlapping the block before. A high surrogate
        // at the loop's last unit is in them, with the unit after it.
        const last = len - n16;
        const before: Mask16 = @intFromBool(isHigh(std.mem.toNative(u16, units[last - 1], endian)));
        pending = utf16Block(endian, simd.load(u16, units[last..]), before);
        if (pending == bad_block) return last;
    }
    return if (pending != 0) len else none;
}

const Units32 = simd.Block(u32);
const n32 = @typeInfo(Units32).vector.len;

/// The values that are not Unicode scalar values, above U+10FFFF or
/// surrogates, are exactly those whose key is above `utf32_key_max`: the
/// XOR moves the surrogates to 0-0x7FF without changing which values are
/// above U+10FFFF, and the subtraction wraps them past the top.
inline fn utf32Key(v: Units32) Units32 {
    return (v ^ @as(Units32, @splat(0xD800))) -% @as(Units32, @splat(0x800));
}
const utf32_key_max = 0x10FFFF - 0x800;

/// One block: two compares, which measured 7-25% faster on one block than
/// the key's three dependent operations.
inline fn utf32Bad(v: Units32) bool {
    const above = v > @as(Units32, @splat(0x10FFFF));
    const surr = v -% @as(Units32, @splat(0xD800)) < @as(Units32, @splat(0x800));
    return @reduce(.Or, above) or @reduce(.Or, surr);
}

inline fn utf32BadBlock(units: []const u32) usize {
    const len = units.len;
    if (len < n32) return if (utf32Bad(loadShort(u32, units))) 0 else none;
    if (len <= 2 * n32) {
        // One block, or the first and the last, overlapping it, with one
        // test: the loops' setup cost a third of the time here, and so did
        // loading the one block a second time.
        const a = simd.load(u32, units);
        if (len == n32) return if (utf32Bad(a)) 0 else none;
        const b = simd.load(u32, units[len - n32 ..]);
        const max: Units32 = @splat(0x10FFFF);
        const d: Units32 = @splat(0xD800);
        const w: Units32 = @splat(0x800);
        if (!@reduce(.Or, (a > max) | (b > max) | (a -% d < w) | (b -% d < w))) return none;
        return if (utf32Bad(a)) 0 else len - n32;
    }
    var i: usize = 0;
    if (len >= 8 * n32) {
        // The first block, then groups from the next 64-byte boundary.
        if (utf32Bad(simd.load(u32, units))) return 0;
        i = toBoundary(u32, units.ptr);
    }
    // Groups of four blocks with one test; the loop below finds the block
    // in a group that fails.
    while (i + 4 * n32 <= len) : (i += 4 * n32) {
        var key = utf32Key(simd.load(u32, units[i..]));
        inline for (1..4) |k| key = @max(key, utf32Key(simd.load(u32, units[i + k * n32 ..])));
        if (@reduce(.Or, key > @as(Units32, @splat(utf32_key_max)))) break;
    }
    while (i + n32 <= len) : (i += n32) {
        if (utf32Bad(simd.load(u32, units[i..]))) return i;
    }
    if (i < len and utf32Bad(simd.load(u32, units[len - n32 ..]))) return len - n32;
    return none;
}

// Differential tests: every function against its scalar counterpart, with
// each error kind placed at every position inside and across blocks and at
// the end of the input, through the public functions, once per tier the CPU
// has (`dispatch.forEachLevel`).

// Past the aligned ASCII loop, so every error lands in it too: a first
// block, up to 64 bytes to the next boundary, two groups of four blocks, a
// block, and the tail. Each input starts at a random offset from a 64-byte
// boundary, so the aligned loops start at every offset.
const max_len = 4 * 64 + 2 * 256 + 8;

fn checkUtf8(bytes: []const u8) !void {
    const want = scalar.validateUtf8(bytes);
    try testing.expectEqual(want, utf8WithErrors(bytes));
    try testing.expectEqual(want.err == .none, utf8(bytes));
}

/// Appends one random well-formed character of at most `room` bytes. With
/// `ascii_only` set, or less than four bytes of room, smaller ones.
fn randomChar(r: std.Random, buf: []u8, ascii_only: bool) usize {
    if (ascii_only or buf.len == 1) {
        buf[0] = r.uintLessThan(u8, 0x80);
        return 1;
    }
    const cp: u21 = switch (r.uintLessThan(usize, @min(buf.len, 4))) {
        0 => r.uintLessThan(u21, 0x80),
        1 => r.intRangeAtMost(u21, 0x80, 0x7FF),
        2 => blk: {
            const c = r.intRangeAtMost(u21, 0x800, 0xFFFF - 0x800);
            break :blk if (c >= 0xD800) c + 0x800 else c;
        },
        else => r.intRangeAtMost(u21, 0x10000, 0x10FFFF),
    };
    return std.unicode.utf8Encode(cp, buf) catch unreachable;
}

/// Fills `buf` with random well-formed characters.
fn randomText(r: std.Random, buf: []u8, ascii_only: bool) void {
    var i: usize = 0;
    while (i < buf.len) i += randomChar(r, buf[i..], ascii_only);
}

test "utf8 accepts random well-formed text of every length" {
    try dispatch.forEachLevel(utf8WellFormed, .{});
}

fn utf8WellFormed() !void {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    var storage: [max_len + 64]u8 align(64) = undefined;
    for (0..max_len) |len| {
        for (0..4) |_| {
            const buf = storage[r.uintLessThan(usize, 64)..];
            randomText(r, buf[0..len], false);
            try testing.expectEqual(Result.ok(len), utf8WithErrors(buf[0..len]));
            try testing.expect(utf8(buf[0..len]));
        }
    }
}

test "utf8 matches scalar with each error kind at every position" {
    try dispatch.forEachLevel(utf8ErrorKinds, .{});
}

fn utf8ErrorKinds() !void {
    const Case = struct { bytes: []const u8, err: Error, at: usize = 0 };
    const cases = [_]Case{
        .{ .bytes = "\xf8", .err = .header_bits },
        .{ .bytes = "\xff\x80\x80\x80", .err = .header_bits },
        .{ .bytes = "\xc3", .err = .too_short },
        .{ .bytes = "\xe2", .err = .too_short },
        .{ .bytes = "\xe2\x82", .err = .too_short },
        .{ .bytes = "\xf0\x9f\x98", .err = .too_short },
        .{ .bytes = "\x80", .err = .too_long },
        .{ .bytes = "\xbf\xbf", .err = .too_long },
        .{ .bytes = "\xc3\xa9\x80", .err = .too_long, .at = 2 },
        .{ .bytes = "\xf0\x9f\x98\x80\x80", .err = .too_long, .at = 4 },
        .{ .bytes = "\xc0\x80", .err = .overlong },
        .{ .bytes = "\xc1\xbf", .err = .overlong },
        .{ .bytes = "\xe0\x9f\xbf", .err = .overlong },
        .{ .bytes = "\xf0\x8f\xbf\xbf", .err = .overlong },
        .{ .bytes = "\xf4\x90\x80\x80", .err = .too_large },
        .{ .bytes = "\xf5\x80\x80\x80", .err = .too_large },
        .{ .bytes = "\xf7\xbf\xbf\xbf", .err = .too_large },
        .{ .bytes = "\xed\xa0\x80", .err = .surrogate },
        .{ .bytes = "\xed\xbf\xbf", .err = .surrogate },
    };
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    var storage: [max_len + 80 + 64]u8 align(64) = undefined;
    for (cases) |c| {
        for ([_]bool{ true, false }) |ascii_only| {
            for (0..max_len) |p| {
                const buf = storage[r.uintLessThan(usize, 64)..];
                randomText(r, buf[0..p], ascii_only);
                @memcpy(buf[p..][0..c.bytes.len], c.bytes);
                const end = p + c.bytes.len;
                // At the end of the input, then followed by more text.
                for ([_]usize{ end, end + r.uintAtMost(usize, 72) }) |len| {
                    randomText(r, buf[end..len], ascii_only);
                    try testing.expectEqual(Result.fail(c.err, p + c.at), scalar.validateUtf8(buf[0..len]));
                    try checkUtf8(buf[0..len]);
                }
            }
        }
    }
}

test "utf8 finds a sequence cut short before ASCII at every offset" {
    try dispatch.forEachLevel(utf8CutShort, .{});
}

fn utf8CutShort() !void {
    // Text that is not ASCII from the start, a lead whose sequence the
    // ASCII after it cuts short, across the first blocks and at every
    // offset from a 64-byte boundary: the aligned loop restarts inside the
    // first block, or right after it.
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    var storage: [64 + 4096 + 64]u8 align(64) = undefined;
    for (0..64) |off| {
        const buf = storage[off..][0 .. 4096 + 64];
        for ([_][]const u8{ "\xc3", "\xe2", "\xe2\x82", "\xf0\x9f\x98" }) |cut| {
            for ([_]usize{ 2, 56, 120 }) |from| for (from..from + 16) |p| {
                buf[0..2].* = "\xc3\xa9".*;
                randomText(r, buf[2..p], false);
                @memcpy(buf[p..][0..cut.len], cut);
                randomText(r, buf[p + cut.len ..], true);
                try checkUtf8(buf);
            };
        }
    }
}

test "utf8 matches scalar on mutated random text" {
    try dispatch.forEachLevel(utf8Mutated, .{});
}

fn utf8Mutated() !void {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    var storage: [max_len + 64]u8 align(64) = undefined;
    for (0..20_000) |_| {
        const buf = storage[r.uintLessThan(usize, 64)..][0..max_len];
        const len = r.uintAtMost(usize, buf.len);
        randomText(r, buf[0..len], r.boolean());
        for (0..r.uintAtMost(usize, 3)) |_| {
            if (len == 0) break;
            buf[r.uintLessThan(usize, len)] = switch (r.uintLessThan(u8, 3)) {
                0 => r.int(u8),
                1 => 0x80 | r.uintLessThan(u8, 0x40),
                else => 0xC0 | r.uintLessThan(u8, 0x40),
            };
        }
        try checkUtf8(buf[0..len]);
    }
    // Long enough for the aligned loop past a first block that is not ASCII.
    var long: [5000 + 64]u8 align(64) = undefined;
    for (0..300) |_| {
        const buf = long[r.uintLessThan(usize, 64)..][0..5000];
        const len = r.intRangeAtMost(usize, 4096, buf.len);
        randomText(r, buf[0..len], false);
        buf[r.uintLessThan(usize, len)] = 0x80 | r.uintLessThan(u8, 0x40);
        try checkUtf8(buf[0..len]);
    }
}

test "ascii matches scalar with a high byte at every position" {
    try dispatch.forEachLevel(asciiHighByte, .{});
}

fn asciiHighByte() !void {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    var storage: [max_len + 72 + 64]u8 align(64) = undefined;
    for (0..max_len) |p| {
        const buf = storage[r.uintLessThan(usize, 64)..];
        for ([_]u8{ 0x80, 0xFF }) |high| {
            for ([_]usize{ p, p + 1, p + 1 + r.uintAtMost(usize, 72) }) |len| {
                randomText(r, buf[0..len], true);
                if (len > p) buf[p] = high;
                const want = scalar.validateAscii(buf[0..len]);
                try testing.expectEqual(if (len > p) Result.fail(.not_ascii, p) else Result.ok(len), want);
                try testing.expectEqual(want, asciiWithErrors(buf[0..len]));
                try testing.expectEqual(want.err == .none, ascii(buf[0..len]));
            }
        }
    }
    // A high byte at every position of every length up to two blocks, for
    // the short paths' overlapping loads, in ASCII and UTF-8 validation.
    for (0..2 * 64 + 8) |len| for (0..len) |p| {
        const buf = storage[r.uintLessThan(usize, 64)..][0..len];
        randomText(r, buf, true);
        buf[p] = 0x80;
        try testing.expectEqual(Result.fail(.not_ascii, p), asciiWithErrors(buf));
        try testing.expect(!ascii(buf));
        try checkUtf8(buf);
    };
}

// Past the aligned UTF-16 loops: eight blocks before they start, up to a
// block to the boundary, a group of eight blocks, one of four, and a tail.
const utf16_max_len = 10 * n16 + 2 * 4 * n16 + 4;

fn scalarUtf16(comptime endian: std.builtin.Endian, units: []const u16) Result {
    return switch (endian) {
        .little => scalar.validateUtf16le(units),
        .big => scalar.validateUtf16be(units),
    };
}

fn utf16(comptime endian: std.builtin.Endian, units: []const u16) bool {
    return switch (endian) {
        .little => utf16le(units),
        .big => utf16be(units),
    };
}

fn utf16Errors(comptime endian: std.builtin.Endian, units: []const u16) Result {
    return switch (endian) {
        .little => utf16leWithErrors(units),
        .big => utf16beWithErrors(units),
    };
}

/// Checks `units`, in native order, then byte-swapped as the other order.
fn checkUtf16(units: []u16) !void {
    const native = comptime builtin.cpu.arch.endian();
    const other: std.builtin.Endian = comptime if (native == .little) .big else .little;
    const want = scalarUtf16(native, units);
    try testing.expectEqual(want, utf16Errors(native, units));
    try testing.expectEqual(want.err == .none, utf16(native, units));
    for (units) |*u| u.* = @byteSwap(u.*);
    defer for (units) |*u| {
        u.* = @byteSwap(u.*);
    };
    try testing.expectEqual(want, scalarUtf16(other, units));
    try testing.expectEqual(want, utf16Errors(other, units));
    try testing.expectEqual(want.err == .none, utf16(other, units));
}

/// Fills `buf` with random well-formed UTF-16, in native order, ending on a
/// whole character. With `pairs` unset, only the BMP.
fn randomUtf16(r: std.Random, buf: []u16, pairs: bool) void {
    var i: usize = 0;
    while (i < buf.len) {
        if (pairs and i + 1 < buf.len and r.uintLessThan(u8, 4) == 0) {
            buf[i] = r.intRangeAtMost(u16, 0xD800, 0xDBFF);
            buf[i + 1] = r.intRangeAtMost(u16, 0xDC00, 0xDFFF);
            i += 2;
        } else {
            const u = r.int(u16);
            buf[i] = if (u & 0xF800 == 0xD800) u ^ 0x8000 else u;
            i += 1;
        }
    }
}

test "utf16 matches scalar with each unpaired surrogate at every position" {
    try dispatch.forEachLevel(utf16Unpaired, .{});
}

fn utf16Unpaired() !void {
    const Case = struct { units: []const u16, at: usize = 0 };
    const cases = [_]Case{
        .{ .units = &.{0xDC00} }, // a low one alone
        .{ .units = &.{0xDFFF} },
        .{ .units = &.{0xD800} }, // a high one at the end, or before a non-low
        .{ .units = &.{ 0xDBFF, 0x0041 } },
        .{ .units = &.{ 0xD800, 0xD800, 0xDC00 } },
        .{ .units = &.{ 0xDC00, 0xD800 } },
        .{ .units = &.{ 0xD800, 0xDC00, 0xDC00 }, .at = 2 },
    };
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    const n = utf16_max_len;
    var storage: [n + 48 + 32]u16 align(64) = undefined;
    for (cases) |c| {
        for ([_]bool{ true, false }) |pairs| {
            for (0..n) |p| {
                const buf = storage[r.uintLessThan(usize, 32)..];
                randomUtf16(r, buf[0..p], pairs);
                @memcpy(buf[p..][0..c.units.len], c.units);
                const end = p + c.units.len;
                // At the end of the input, then followed by more text.
                for ([_]usize{ end, end + r.uintAtMost(usize, 40) }) |len| {
                    randomUtf16(r, buf[end..len], pairs);
                    const want = scalarUtf16(builtin.cpu.arch.endian(), buf[0..len]);
                    try testing.expectEqual(Result.fail(.surrogate, p + c.at), want);
                    try checkUtf16(buf[0..len]);
                }
            }
        }
    }
}

test "utf16 matches scalar on random units and well-formed text" {
    try dispatch.forEachLevel(utf16Random, .{});
}

fn utf16Random() !void {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    var storage: [utf16_max_len + 32]u16 align(64) = undefined;
    for (0..utf16_max_len) |len| {
        const buf = storage[r.uintLessThan(usize, 32)..];
        randomUtf16(r, buf[0..len], true);
        try testing.expectEqual(Result.ok(len), scalarUtf16(builtin.cpu.arch.endian(), buf[0..len]));
        try checkUtf16(buf[0..len]);
    }
    for (0..20_000) |_| {
        const buf = storage[r.uintLessThan(usize, 32)..][0..utf16_max_len];
        const len = r.uintAtMost(usize, buf.len);
        randomUtf16(r, buf[0..len], r.boolean());
        // Rarely more than one unpaired surrogate, so later blocks still count.
        for (0..r.uintAtMost(usize, 2)) |_| {
            if (len == 0) break;
            buf[r.uintLessThan(usize, len)] = r.intRangeAtMost(u16, 0xD800, 0xDFFF);
        }
        try checkUtf16(buf[0..len]);
    }
}

test "utf32 matches scalar with each bad value at every position" {
    try dispatch.forEachLevel(utf32BadValues, .{});
}

fn utf32BadValues() !void {
    const bad = [_]struct { u32, Error }{
        .{ 0xD800, .surrogate },     .{ 0xDFFF, .surrogate },
        .{ 0x110000, .too_large },   .{ 0xFFFFFFFF, .too_large },
        .{ 0x80000000, .too_large },
    };
    // Every boundary that must pass, and random values that do.
    const good = [_]u32{ 0, 0x7F, 0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF };
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    // Past the aligned groups, as for UTF-16.
    const n = 10 * n32 + 2 * 4 * n32 + 4;
    var storage: [n + 20 + 16]u32 align(64) = undefined;
    for (bad) |b| {
        for (0..n) |p| {
            const buf = storage[r.uintLessThan(usize, 16)..];
            for ([_]usize{ p + 1, p + 1 + r.uintAtMost(usize, 20) }) |len| {
                for (buf[0..len]) |*u| {
                    u.* = if (r.boolean()) good[r.uintLessThan(usize, good.len)] else r.uintAtMost(u32, 0xD7FF);
                }
                buf[p] = b[0];
                const want = scalar.validateUtf32(buf[0..len]);
                try testing.expectEqual(Result.fail(b[1], p), want);
                try testing.expectEqual(want, utf32WithErrors(buf[0..len]));
                try testing.expect(!utf32(buf[0..len]));
                try testing.expectEqual(Result.ok(p), utf32WithErrors(buf[0..p]));
                try testing.expect(utf32(buf[0..p]));
            }
        }
    }
}
