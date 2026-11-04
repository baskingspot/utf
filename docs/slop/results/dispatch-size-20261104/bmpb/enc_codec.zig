//! What every codec family shares: the results a decode or encode call
//! returns, the error modes, the output writers for UTF-8 and UTF-16, the
//! input reader encoders use, and numeric character references.
//!
//! A family (single_byte.zig, utf8.zig, ...) implements the standard's
//! decoder and encoder for its encodings over these, and codecs.zig
//! registers it. docs/slop/adding-an-encoding.md is the contract.

const std = @import("std");
const builtin = @import("builtin");

pub const Encoding = enum { stub };

/// Why a decode call returned.
pub const DecodeStatus = enum(u8) {
    /// Every byte of `src` was read. With `last` set, the stream is
    /// finished too: a sequence it cut off has been reported.
    input_empty,
    /// The next character does not fit in what is left of `dst`. Call
    /// again with the unread input and more room.
    output_full,
    /// Fatal mode only: the input holds an error. The malformed sequence
    /// ends at `read` (it may have started in an earlier call), and the
    /// decoder can go on from there with the rest of the input.
    malformed,
};

/// What a decode call did: how many bytes of `src` it read, how many code
/// units of `dst` it wrote, and why it stopped.
pub const DecodeResult = struct {
    status: DecodeStatus,
    read: usize,
    written: usize,
};

/// Why an encode call returned.
pub const EncodeStatus = enum(u8) {
    /// Every code unit of `src` was read; with `last`, the stream is
    /// finished too.
    input_empty,
    /// The next character, or the escape that ends the stream, does not
    /// fit in what is left of `dst`.
    output_full,
    /// Fatal mode only: `unmappable` has no representation in the
    /// encoding. It is the last character of `src[0..read]`; the encoder
    /// can go on from there.
    unmappable,
};

/// What an encode call did: how many code units of `src` it read, how
/// many bytes of `dst` it wrote, and why it stopped.
pub const EncodeResult = struct {
    status: EncodeStatus,
    read: usize,
    written: usize,
    /// With `.unmappable`, the character that cannot be encoded.
    unmappable: u21 = 0,
};

/// A decoder's error mode, as the standard names them: "replacement"
/// writes U+FFFD for each error, "fatal" stops at the first.
pub const DecoderMode = enum(u1) { replacement, fatal };

/// An encoder's error mode, as the standard names them: "html" writes a
/// numeric character reference (`&#8364;`) for each character the
/// encoding cannot represent, "fatal" stops at the first.
pub const EncoderMode = enum(u1) { html, fatal };

pub const replacement_character: u21 = 0xFFFD;

/// The code units a decoder writes: `u8` for UTF-8, `u16` for UTF-16 in
/// the machine's byte order.
pub fn checkUnit(comptime Unit: type) void {
    if (Unit != u8 and Unit != u16) @compileError("decoders write u8 (UTF-8) or u16 (UTF-16)");
}

/// The code units `cp` takes in UTF-8 (`u8`) or UTF-16 (`u16`).
pub inline fn unitsOf(comptime Unit: type, cp: u21) usize {
    if (Unit == u16) return if (cp < 0x10000) 1 else 2;
    if (cp < 0x80) return 1;
    if (cp < 0x800) return 2;
    if (cp < 0x10000) return 3;
    return 4;
}

/// Writes `cp`, a scalar value, at `dst[o..]`, which has room for it, and
/// returns the units written.
pub inline fn put(comptime Unit: type, dst: []Unit, o: usize, cp: u21) usize {
    if (Unit == u16) {
        if (cp < 0x10000) {
            dst[o] = @intCast(cp);
            return 1;
        }
        const v = cp - 0x10000;
        dst[o] = @intCast(0xD800 | (v >> 10));
        dst[o + 1] = @intCast(0xDC00 | (v & 0x3FF));
        return 2;
    }
    if (cp < 0x80) {
        dst[o] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        dst[o] = @intCast(0xC0 | (cp >> 6));
        dst[o + 1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        dst[o] = @intCast(0xE0 | (cp >> 12));
        dst[o + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        dst[o + 2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
    dst[o] = @intCast(0xF0 | (cp >> 18));
    dst[o + 1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
    dst[o + 2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
    dst[o + 3] = @intCast(0x80 | (cp & 0x3F));
    return 4;
}

/// Writes `cp` at `dst[o..]` if it fits; returns the units written, or
/// null when it does not fit.
pub inline fn tryPut(comptime Unit: type, dst: []Unit, o: usize, cp: u21) ?usize {
    if (dst.len - o < unitsOf(Unit, cp)) return null;
    return put(Unit, dst, o, cp);
}

/// Writes `cp`, a code point from U+0080 to U+FFFF, at `dst[o..]` if it
/// fits, and returns the units written, or 0 when it does not fit: no
/// optional to carry through a decoder's hot loop.
pub inline fn putBmp(comptime Unit: type, dst: []Unit, o: usize, cp: u32) usize {
    if (Unit == u16) {
        if (o == dst.len) return 0;
        dst[o] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        if (dst.len - o < 2) return 0;
        dst[o..][0..2].* = .{ @intCast(0xC0 | cp >> 6), @intCast(0x80 | (cp & 0x3F)) };
        return 2;
    }
    if (dst.len - o < 3) return 0;
    dst[o..][0..3].* = .{ @intCast(0xE0 | cp >> 12), @intCast(0x80 | (cp >> 6 & 0x3F)), @intCast(0x80 | (cp & 0x3F)) };
    return 3;
}

/// The longest numeric character reference, `&#1114111;`.
pub const max_ncr_len = 10;

/// Writes the standard's "html" error for `cp`, `&#` and its decimal value
/// and `;`, at `dst[o..]` if it fits; returns the bytes written or null.
pub fn putNcr(dst: []u8, o: usize, cp: u21) ?usize {
    var digits: [7]u8 = undefined;
    var n: usize = 0;
    var v: u32 = cp;
    while (true) {
        digits[digits.len - 1 - n] = @intCast('0' + v % 10);
        n += 1;
        v /= 10;
        if (v == 0) break;
    }
    const len = n + 3;
    if (dst.len - o < len) return null;
    dst[o] = '&';
    dst[o + 1] = '#';
    @memcpy(dst[o + 2 ..][0..n], digits[digits.len - n ..]);
    dst[o + 2 + n] = ';';
    return len;
}

/// One scalar value read from an encoder's input, and the code units it
/// took.
pub const Scalar = struct { cp: u21, len: usize };

/// Reads the scalar value at `src[i]`, `i < src.len`, from UTF-8 (`u8`) or
/// UTF-16 in the machine's byte order (`u16`). Ill-formed input reads as
/// U+FFFD: in UTF-8 one for each maximal subpart, as the standard's UTF-8
/// decoder does, and in UTF-16 one for each unpaired surrogate. A
/// sequence cut off by the end of `src` is ill-formed here; the encoder
/// wrappers hold one back until the next call.
pub fn readScalar(comptime Unit: type, src: []const Unit, i: usize) Scalar {
    if (Unit == u16) {
        const u = src[i];
        if (u < 0xD800 or u > 0xDFFF) return .{ .cp = u, .len = 1 };
        if (u <= 0xDBFF and i + 1 < src.len) {
            const t = src[i + 1];
            if (t >= 0xDC00 and t <= 0xDFFF) {
                return .{ .cp = 0x10000 + ((@as(u21, u) - 0xD800) << 10) + (t - 0xDC00), .len = 2 };
            }
        }
        return .{ .cp = replacement_character, .len = 1 };
    }
    const b = src[i];
    if (b < 0x80) return .{ .cp = b, .len = 1 };
    const s = utf8Step(src[i..]);
    return switch (s) {
        .scalar => |c| c,
        .invalid => |n| .{ .cp = replacement_character, .len = n },
        .incomplete => |n| .{ .cp = replacement_character, .len = n },
    };
}

/// What the standard's UTF-8 decoder makes of the bytes at the start of
/// `s`, `s.len > 0`.
pub const Utf8Step = union(enum) {
    /// A whole, well-formed character.
    scalar: Scalar,
    /// An error: one U+FFFD for the first `n` bytes (the maximal subpart),
    /// then go on after them.
    invalid: usize,
    /// The first `n` bytes, all of `s`, begin a character that the end of
    /// `s` cuts off: an error at the end of the stream, otherwise wait for
    /// more input.
    incomplete: usize,
};

/// The standard's UTF-8 decoder over one character at the start of `s`.
pub fn utf8Step(s: []const u8) Utf8Step {
    const b = s[0];
    if (b < 0x80) return .{ .scalar = .{ .cp = b, .len = 1 } };
    var need: usize = undefined;
    var lower: u8 = 0x80;
    var upper: u8 = 0xBF;
    var cp: u21 = undefined;
    switch (b) {
        0xC2...0xDF => {
            need = 1;
            cp = b & 0x1F;
        },
        0xE0...0xEF => {
            if (b == 0xE0) lower = 0xA0;
            if (b == 0xED) upper = 0x9F;
            need = 2;
            cp = b & 0xF;
        },
        0xF0...0xF4 => {
            if (b == 0xF0) lower = 0x90;
            if (b == 0xF4) upper = 0x8F;
            need = 3;
            cp = b & 0x7;
        },
        else => return .{ .invalid = 1 },
    }
    var k: usize = 1;
    while (k <= need) : (k += 1) {
        if (k == s.len) return .{ .incomplete = k };
        const c = s[k];
        if (c < lower or c > upper) return .{ .invalid = k };
        lower = 0x80;
        upper = 0xBF;
        cp = (cp << 6) | (c & 0x3F);
    }
    return .{ .scalar = .{ .cp = cp, .len = need + 1 } };
}

/// How many code units at the end of `src` begin a character that its end
/// cuts off and that later input could complete: up to three UTF-8 bytes
/// that are a prefix of a well-formed sequence, or one leading surrogate.
pub fn incompleteTail(comptime Unit: type, src: []const Unit) usize {
    if (src.len == 0) return 0;
    if (Unit == u16) {
        const u = src[src.len - 1];
        return @intFromBool(u >= 0xD800 and u <= 0xDBFF);
    }
    // The last lead byte within the last three bytes.
    const start = src.len -| 3;
    var i = src.len;
    while (i > start) {
        i -= 1;
        const b = src[i];
        if (b < 0x80) return 0;
        if (b >= 0xC0) {
            return switch (utf8Step(src[i..])) {
                .incomplete => |n| n,
                else => 0,
            };
        }
    }
    return 0;
}

pub const native_endian = builtin.cpu.arch.endian();

/// `a * b + c`, or null on overflow: the max-length functions' arithmetic.
pub fn mulAdd(a: usize, b: usize, c: usize) ?usize {
    const m = std.math.mul(usize, a, b) catch return null;
    return std.math.add(usize, m, c) catch null;
}

/// The blocks the ASCII fast paths work in.
pub const ascii_block = 16;

/// The units at the start of `s`, bytes or UTF-16 units, in whole ASCII
/// blocks: a multiple of `ascii_block` at or below the index of the first
/// non-ASCII unit. The caller finishes the scan unit by unit.
pub inline fn asciiPrefixBlocks(comptime Unit: type, s: []const Unit) usize {
    const V = @Vector(ascii_block, Unit);
    var i: usize = 0;
    while (s.len - i >= ascii_block) : (i += ascii_block) {
        const v: V = s[i..][0..ascii_block].*;
        if (@reduce(.Or, v >= @as(V, @splat(0x80)))) break;
    }
    return i;
}

/// Copies ASCII bytes to UTF-8, or widens them to UTF-16. `src.len` is a
/// multiple of `ascii_block`.
pub inline fn copyAscii(comptime Unit: type, dst: []Unit, src: []const u8) void {
    if (Unit == u8) {
        @memcpy(dst, src);
        return;
    }
    var k: usize = 0;
    while (k < src.len) : (k += ascii_block) {
        const v: @Vector(ascii_block, u8) = src[k..][0..ascii_block].*;
        dst[k..][0..ascii_block].* = @as(@Vector(ascii_block, u16), v);
    }
}

/// Copies ASCII UTF-8 to bytes, or narrows ASCII UTF-16 units to them.
/// `src.len` is a multiple of `ascii_block`.
pub inline fn narrowAscii(comptime Unit: type, dst: []u8, src: []const Unit) void {
    if (Unit == u8) {
        @memcpy(dst, src);
        return;
    }
    var k: usize = 0;
    while (k < src.len) : (k += ascii_block) {
        const v: @Vector(ascii_block, u16) = src[k..][0..ascii_block].*;
        dst[k..][0..ascii_block].* = @as(@Vector(ascii_block, u8), @truncate(v));
    }
}

/// A bit for each lane of `mask`, lane 0 in the lowest bit. A bool vector
/// bitcasts lane 0 to the highest bit on big-endian targets.
pub inline fn highBits(mask: @Vector(ascii_block, bool)) u16 {
    const bits: u16 = @bitCast(mask);
    return if (native_endian == .little) bits else @bitReverse(bits);
}

/// Copies the ASCII bytes at the start of `src`, which starts with one,
/// to `dst`, widened for UTF-16, a block at a time while both have a block
/// left, and returns how many it copied. `dst` may hold more after them,
/// which the caller overwrites.
pub inline fn asciiRun(comptime Unit: type, src: []const u8, dst: []Unit) usize {
    const V = @Vector(ascii_block, u8);
    var k: usize = 0;
    while (src.len - k >= ascii_block and dst.len - k >= ascii_block) {
        const v: V = src[k..][0..ascii_block].*;
        dst[k..][0..ascii_block].* = if (Unit == u8) v else @as(@Vector(ascii_block, u16), v);
        const high = highBits(v >= @as(V, @splat(0x80)));
        if (high != 0) return k + @ctz(high);
        k += ascii_block;
    }
    return k;
}

/// Copies the ASCII units at the start of `src`, UTF-8 or UTF-16 that
/// starts with one, to `dst`, narrowed, a block at a time while both have
/// a block left, and returns how many it copied. `dst` may hold more after
/// them, which the caller overwrites.
pub inline fn asciiRunOut(comptime Unit: type, src: []const Unit, dst: []u8) usize {
    const V = @Vector(ascii_block, Unit);
    var k: usize = 0;
    while (src.len - k >= ascii_block and dst.len - k >= ascii_block) {
        const v: V = src[k..][0..ascii_block].*;
        dst[k..][0..ascii_block].* = if (Unit == u8) v else @as(@Vector(ascii_block, u8), @truncate(v));
        const high = highBits(v >= @as(V, @splat(0x80)));
        if (high != 0) return k + @ctz(high);
        k += ascii_block;
    }
    return k;
}

/// Copies whole blocks of ASCII bytes from the start of `src` to `dst`,
/// widened for UTF-16, while both have a block left, and returns how many
/// it copied: 0 when the first block holds a byte from 0x80. After one
/// block, more ASCII likely follows, so it goes on two blocks at a time.
pub inline fn asciiBlocks(comptime Unit: type, src: []const u8, dst: []Unit) usize {
    const V = @Vector(ascii_block, u8);
    const v: V = src[0..ascii_block].*;
    if (@reduce(.Or, v >= @as(V, @splat(0x80)))) return 0;
    dst[0..ascii_block].* = if (Unit == u8) v else @as(@Vector(ascii_block, u16), v);
    var k: usize = ascii_block;
    const P = @Vector(2 * ascii_block, u8);
    while (src.len - k >= 2 * ascii_block and dst.len - k >= 2 * ascii_block) : (k += 2 * ascii_block) {
        const p: P = src[k..][0 .. 2 * ascii_block].*;
        if (@reduce(.Or, p >= @as(P, @splat(0x80)))) break;
        dst[k..][0 .. 2 * ascii_block].* = if (Unit == u8) p else @as(@Vector(2 * ascii_block, u16), p);
    }
    return k;
}

/// `asciiBlocks` from UTF-8 or UTF-16 to bytes, narrowed.
pub inline fn asciiBlocksOut(comptime Unit: type, src: []const Unit, dst: []u8) usize {
    const V = @Vector(ascii_block, Unit);
    const v: V = src[0..ascii_block].*;
    if (@reduce(.Or, v >= @as(V, @splat(0x80)))) return 0;
    dst[0..ascii_block].* = if (Unit == u8) v else @as(@Vector(ascii_block, u8), @truncate(v));
    var k: usize = ascii_block;
    const P = @Vector(2 * ascii_block, Unit);
    while (src.len - k >= 2 * ascii_block and dst.len - k >= 2 * ascii_block) : (k += 2 * ascii_block) {
        const p: P = src[k..][0 .. 2 * ascii_block].*;
        if (@reduce(.Or, p >= @as(P, @splat(0x80)))) break;
        dst[k..][0 .. 2 * ascii_block].* = if (Unit == u8) p else @as(@Vector(2 * ascii_block, u8), @truncate(p));
    }
    return k;
}

/// How `bmpToUtf8` and `utf8ToBmp`, the single-byte families' staging,
/// pack characters of different lengths, chosen at compile time from the
/// target's features: AVX-512 VBMI2's `vpcompressb` and `vpcompressw`; a
/// byte shuffle (SSSE3's `pshufb`, two at once with AVX2, NEON's `tbl`)
/// indexed by tables of 256 shuffles for each eight 16-bit lanes or four
/// 32-bit lanes (8.25 KB for decoding, 4 KB for encoding); or, with
/// neither, one store per character. They do not call
/// utf, whose transcoders carry 4 to 11 KB tables each and, on an x86-64
/// build below AVX-512, the higher levels' kernels for its run-time
/// dispatch: a one-encoding decoder linked 51 to 73 KB more there
/// (docs/slop/results/single-byte-size-20261103.md).
const Pack = enum { compress, shuffle, store };

const pack: Pack = blk: {
    if (builtin.zig_backend != .stage2_llvm or native_endian != .little) break :blk .store;
    const f = builtin.cpu.features;
    break :blk switch (builtin.cpu.arch) {
        .x86_64 => if (std.Target.x86.featureSetHasAll(f, .{ .avx512vbmi2, .avx512bw, .avx512vl }))
            .compress
        else if (std.Target.x86.featureSetHas(f, .ssse3))
            .shuffle
        else
            .store,
        .aarch64 => if (std.Target.aarch64.featureSetHas(f, .neon)) .shuffle else .store,
        else => .store,
    };
};

const B16 = @Vector(16, u8);

extern fn @"llvm.x86.ssse3.pshuf.b.128"(B16, B16) callconv(.{ .x86_64_sysv = .{} }) B16;
extern fn @"llvm.aarch64.neon.tbl1.v16i8"(B16, B16) callconv(.c) B16;
extern fn @"llvm.x86.avx512.mask.compress.v64i8"(
    @Vector(64, u8),
    @Vector(64, u8),
    @Vector(64, bool),
) callconv(.{ .x86_64_sysv = .{} }) @Vector(64, u8);
extern fn @"llvm.x86.avx512.mask.compress.v32i16"(
    @Vector(32, u16),
    @Vector(32, u16),
    @Vector(32, bool),
) callconv(.{ .x86_64_sysv = .{} }) @Vector(32, u16);

/// The bytes of `v` that `idx` names, each index below 16.
inline fn shuffleBytes(v: B16, idx: B16) B16 {
    return switch (builtin.cpu.arch) {
        .x86_64 => @"llvm.x86.ssse3.pshuf.b.128"(v, idx),
        .aarch64 => @"llvm.aarch64.neon.tbl1.v16i8"(v, idx),
        else => unreachable,
    };
}

extern fn @"llvm.x86.avx2.pshuf.b"(@Vector(32, u8), @Vector(32, u8)) callconv(.{ .x86_64_sysv = .{} }) @Vector(32, u8);

/// Whether `shufflePair` is one AVX2 `vpshufb`.
const wide_shuffle = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

/// Each 16-byte half of `v` shuffled by its own indices, `lo` and `hi`:
/// with AVX2 one shuffle, which takes as long as one of 16 bytes.
inline fn shufflePair(v: @Vector(32, u8), lo: B16, hi: B16) [2]B16 {
    if (wide_shuffle) return @bitCast(@"llvm.x86.avx2.pshuf.b"(v, @bitCast([2]B16{ lo, hi })));
    const h: [2]B16 = @bitCast(v);
    return .{ shuffleBytes(h[0], lo), shuffleBytes(h[1], hi) };
}

/// Shuffle indices for each group of eight 16-bit lanes: entry `n`
/// lists the bytes to keep, in order, then zeros; `keep(n, b)` says
/// whether byte `b` (0 to 15) of the group is kept.
fn packTable(comptime keep: fn (u8, u4) bool) [256]B16 {
    @setEvalBranchQuota(10_000);
    var t: [256]B16 = undefined;
    for (&t, 0..) |*e, n| {
        var idx: [16]u8 = @splat(0);
        var k: usize = 0;
        for (0..16) |b| {
            if (keep(n, b)) {
                idx[k] = b;
                k += 1;
            }
        }
        e.* = idx;
    }
    return t;
}

/// Eight code points below U+0800 as two bytes each, lead then trail:
/// bit `i` of `n` is set for each that is ASCII and keeps only its lead.
const pack_narrow = packTable(struct {
    fn keep(n: u8, b: u4) bool {
        return b % 2 == 0 or n >> (b / 2) & 1 == 0;
    }
}.keep);

/// Packs `words`, two bytes for each of `16 * n` code points below
/// U+0800, where bit `i` of `a` is set for each that is ASCII, to `d` with
/// the byte shuffle, eight code points at a time, and returns the bytes
/// written.
inline fn shuffleNarrow(comptime n: usize, words: [n]@Vector(32, u8), a: u32, d: []u8) usize {
    var o: usize = 0;
    inline for (words, 0..) |w, h| {
        const m: [2]u32 = .{ a >> (16 * h) & 0xFF, a >> (16 * h + 8) & 0xFF };
        const p = shufflePair(w, pack_narrow[m[0]], pack_narrow[m[1]]);
        inline for (p, m) |q, k| {
            d[o..][0..16].* = q;
            o += 16 - @as(usize, @popCount(k));
        }
    }
    return o;
}

/// Eight UTF-16 units: bit `i` of `n` is set for each to keep.
const pack_units = packTable(struct {
    fn keep(n: u8, b: u4) bool {
        return n >> (b / 2) & 1 == 1;
    }
}.keep);

/// Four code points as four bytes each, of which they take one to three:
/// entry `n` for code points `j` taking `1 + (n >> 2 * j & 1) + (n >> 2 *
/// j + 1 & 1)` bytes (the second bit set only with the first), and in
/// `lens` the bytes all four take.
const pack_quads: struct { shuffles: [256]B16, lens: [256]u8 } = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256]B16 = undefined;
    var l: [256]u8 = undefined;
    for (&t, &l, 0..) |*e, *len, n| {
        var idx: [16]u8 = @splat(0);
        var k: usize = 0;
        for (0..4) |j| {
            for (0..1 + (n >> 2 * j & 1) + (n >> 2 * j + 1 & 1)) |b| {
                idx[k] = 4 * j + b;
                k += 1;
            }
        }
        e.* = idx;
        len.* = k;
    }
    break :blk .{ .shuffles = t, .lens = l };
};

/// The UTF-16 units a decoder that has no SIMD UTF-8 path of its own
/// (single_byte.zig, x_user_defined.zig) stages at a time: it decodes up
/// to this many to UTF-16 a block at a time, then `bmpToUtf8` transcodes
/// them.
pub const stage_len = 256;

/// What `bmpToUtf8`, `utf8ToBmp`, and `encodeStaged` did: the units they
/// read and the units they wrote.
pub const Converted = struct { read: usize, written: usize };

/// The room a step of `bmpToUtf8` needs: three bytes for each of 16 code
/// points or two for each of 32, and the eight-byte stores past them.
const pack_room = 4 * ascii_block;

/// Transcodes `src`, UTF-16 in the machine's byte order with no
/// surrogates, to UTF-8 at the start of `dst`, as many characters as fit
/// whole: 32 code points at a time while they are all below U+0800, else
/// 16, then one at a time.
pub fn bmpToUtf8(src: []const u16, dst: []u8) Converted {
    const N = @Vector(2 * ascii_block, u16);
    var i: usize = 0;
    var o: usize = 0;
    while (src.len - i >= ascii_block and dst.len - o >= pack_room) {
        var blocks: usize = 1;
        if (src.len - i >= 2 * ascii_block) {
            const c: N = src[i..][0 .. 2 * ascii_block].*;
            // The stage holds the ASCII blocks between the others, which
            // the byte shuffle and the stores are slower at than this;
            // `vpcompressb` is not.
            if (pack != .compress and @reduce(.And, c < @as(N, @splat(0x80)))) {
                dst[o..][0 .. 2 * ascii_block].* = @as(@Vector(2 * ascii_block, u8), @truncate(c));
                o += 2 * ascii_block;
                i += 2 * ascii_block;
                continue;
            }
            if (@reduce(.And, c < @as(N, @splat(0x800)))) {
                o += packNarrow(c, dst[o..][0..pack_room]);
                i += 2 * ascii_block;
                continue;
            }
            // Both blocks, not testing the second on its own again.
            blocks = 2;
        }
        for (0..blocks) |_| {
            if (dst.len - o < pack_room) break;
            o += bmpBlockToUtf8(src[i..][0..ascii_block].*, dst[o..][0..pack_room]);
            i += ascii_block;
        }
    }
    while (i < src.len) : (i += 1) {
        o += tryPut(u8, dst, o, src[i]) orelse break;
    }
    return .{ .read = i, .written = o };
}

/// Writes `c`, 32 code points below U+0800, as UTF-8 at the start of `d`
/// and returns the bytes written; it may write anything to the rest of
/// `d`. Each code point is two bytes in a 16-bit lane, lead then trail,
/// of which ASCII keeps the first.
inline fn packNarrow(c: @Vector(2 * ascii_block, u16), d: *[pack_room]u8) usize {
    const N = @Vector(2 * ascii_block, u16);
    const ascii = c < @as(N, @splat(0x80));
    const trail = c & @as(N, @splat(0x3F)) | @as(N, @splat(0x80));
    const two = (c >> @splat(6) | @as(N, @splat(0xC0))) | trail << @splat(8);
    const words = @select(u16, ascii, c, two);
    const bits: u32 = @bitCast(ascii);
    const a = if (native_endian == .little) bits else @bitReverse(bits);
    switch (pack) {
        .compress => {
            // Every lead byte, and every trail byte but ASCII's zero.
            const bytes: @Vector(64, u8) = @bitCast(words);
            const keep: u64 = @as(u64, @bitCast(bytes != @as(@Vector(64, u8), @splat(0)))) | 0x5555_5555_5555_5555;
            d.* = @"llvm.x86.avx512.mask.compress.v64i8"(bytes, @splat(0), @bitCast(keep));
            return 64 - @as(usize, @popCount(a));
        },
        .shuffle => return shuffleNarrow(2, @bitCast(words), a, d),
        .store => {
            // Eight lanes at a time: all ASCII, one store, as in Latin
            // text with the odd accented letter; else a store a lane.
            const groups: [4]@Vector(8, u16) = @bitCast(words);
            var o: usize = 0;
            inline for (groups, 0..) |g, h| {
                const m = a >> (8 * h) & 0xFF;
                if (m == 0xFF) {
                    d[o..][0..8].* = @as(@Vector(8, u8), @truncate(g));
                    o += 8;
                } else {
                    const ws: [8]u16 = g;
                    inline for (ws, 0..) |w, j| {
                        std.mem.writeInt(u16, d[o..][0..2], w, .little);
                        o += 2 - (m >> j & 1);
                    }
                }
            }
            return o;
        },
    }
}

/// `@shuffle` indices that interleave the 16-bit lanes of two vectors of
/// `ascii_block`, `first + k` and `first + 8 + k` for `k` below 4: lane
/// from the first vector, then from the second.
fn interleave(first: i32) [ascii_block]i32 {
    var x: [ascii_block]i32 = undefined;
    for (&x, 0..) |*e, j| {
        const lane = first + @as(i32, @intCast(j / 8 * 8 + j % 8 / 2));
        e.* = if (j % 2 == 0) lane else ~lane;
    }
    return x;
}

/// Writes `u`, a block of code points below U+10000 that are not
/// surrogates, as UTF-8 at the start of `d`, and returns the bytes it
/// wrote, `ascii_block` to `3 * ascii_block`; it may write anything to
/// the rest of `d`. For the decoders whose code points all come from a
/// block of UTF-16 (single_byte.zig, x_user_defined.zig). Each code
/// point's UTF-8 is built in a 32-bit lane, all at once, then packed as
/// `pack` says; a block below U+0800 packs 16-bit lanes.
inline fn bmpBlockToUtf8(u: @Vector(ascii_block, u16), d: *[pack_room]u8) usize {
    const U = @Vector(ascii_block, u32);
    const c: U = u;
    const low: U = c & @as(U, @splat(0x3F)) | @as(U, @splat(0x80));
    const mid: U = c >> @splat(6) & @as(U, @splat(0x3F)) | @as(U, @splat(0x80));
    const two = (c >> @splat(6) | @as(U, @splat(0xC0))) | low << @splat(8);
    const three = (c >> @splat(12) | @as(U, @splat(0xE0))) | mid << @splat(8) | low << @splat(16);
    const ascii = c < @as(U, @splat(0x80));
    const narrow = c < @as(U, @splat(0x800));
    const words = @select(u32, ascii, c, @select(u32, narrow, two, three));
    const lens = @select(u32, ascii, @as(U, @splat(1)), @select(u32, narrow, @as(U, @splat(2)), @as(U, @splat(3))));
    switch (pack) {
        .compress => {
            // Every lane's first byte, and the others but zeros: only
            // ASCII has a zero byte, and the leads and trails of longer
            // characters none.
            const bytes: @Vector(64, u8) = @bitCast(words);
            const keep: u64 = @as(u64, @bitCast(bytes != @as(@Vector(64, u8), @splat(0)))) | 0x1111_1111_1111_1111;
            d.* = @"llvm.x86.avx512.mask.compress.v64i8"(bytes, @splat(0), @bitCast(keep));
            return @popCount(keep);
        },
        .shuffle => {
            // The bytes in 16-bit lanes, as many lanes as a register holds:
            // `lo` a code point's first two, `hi` its third.
            const H = @Vector(ascii_block, u16);
            const ascii16 = u < @as(H, @splat(0x80));
            const narrow16 = u < @as(H, @splat(0x800));
            const trail = u & @as(H, @splat(0x3F)) | @as(H, @splat(0x80));
            const two16 = (u >> @splat(6) | @as(H, @splat(0xC0))) | trail << @splat(8);
            // Two bits a code point, in a byte of its own: from U+0080,
            // and from U+0800; four code points' bits are a table index.
            const kind = @select(u16, ascii16, @as(H, @splat(0)), @select(
                u16,
                narrow16,
                @as(H, @splat(0x00FF)),
                @as(H, @splat(0xFFFF)),
            ));
            const S = @Vector(2 * ascii_block, i8);
            const kinds: u32 = @bitCast(@as(S, @bitCast(kind)) < @as(S, @splat(0)));
            if (kinds & 0xAAAA_AAAA == 0) {
                // Two bytes a lane, the second dropped for ASCII.
                return shuffleNarrow(1, @bitCast(@select(u16, ascii16, u, two16)), highBits(ascii16), d);
            }
            const mid16 = u >> @splat(6) & @as(H, @splat(0x3F)) | @as(H, @splat(0x80));
            const three16 = (u >> @splat(12) | @as(H, @splat(0xE0))) | mid16 << @splat(8);
            const lo = @select(u16, ascii16, u, @select(u16, narrow16, two16, three16));
            const hi = @select(u16, narrow16, @as(H, @splat(0)), trail);
            // Four bytes a code point, `lo` then `hi`, four a shuffle:
            // `qa` holds code points 0 to 3 and 8 to 11, `qb` the others,
            // which interleaves within each 16 bytes of an AVX2 register.
            const qa: @Vector(32, u8) = @bitCast(@shuffle(u16, lo, hi, interleave(0)));
            const qb: @Vector(32, u8) = @bitCast(@shuffle(u16, lo, hi, interleave(4)));
            var idx: [4]u32 = undefined;
            inline for (&idx, 0..) |*x, g| x.* = kinds >> (8 * g) & 0xFF;
            const t = &pack_quads.shuffles;
            const pa = shufflePair(qa, t[idx[0]], t[idx[2]]);
            const pb = shufflePair(qb, t[idx[1]], t[idx[3]]);
            var o: usize = 0;
            inline for (.{ pa[0], pb[0], pa[1], pb[1] }, idx) |q, x| {
                d[o..][0..16].* = q;
                o += pack_quads.lens[x];
            }
            return o;
        },
        .store => {
            // Each word stored four bytes wide, overwritten by the next.
            const ws: [ascii_block]u32 = words;
            const ls: [ascii_block]u32 = lens;
            var o: usize = 0;
            inline for (ws, ls) |w, n| {
                std.mem.writeInt(u32, d[o..][0..4], w, .little);
                o += n;
            }
            return o;
        },
    }
}

/// The bytes `utf8ToBmp` reads at a time: a register of AVX-512, or two
/// of SSE or NEON, one of AVX2.
pub const window = if (pack == .compress) 4 * ascii_block else 2 * ascii_block;

/// A bit for each lane of `mask`, lane 0 in the lowest bit.
inline fn windowBits(mask: @Vector(window, bool)) u64 {
    const bits: @Int(.unsigned, window) = @bitCast(mask);
    return if (native_endian == .little) bits else @bitReverse(bits);
}

/// Writes the lanes of `units` whose bit is set in `keep` to the start of
/// `d`, in order, and returns how many; it may write anything to the rest.
inline fn packUnits(units: @Vector(window, u16), keep: u64, d: *[window]u16) usize {
    switch (pack) {
        .compress => {
            // 32 units at a time, the second half after the first's.
            const halves: [2]@Vector(32, u16) = @bitCast(units);
            const lo: u32 = @truncate(keep);
            const hi: u32 = @truncate(keep >> 32);
            d[0..32].* = @"llvm.x86.avx512.mask.compress.v32i16"(halves[0], @splat(0), @bitCast(lo));
            d[@popCount(lo)..][0..32].* = @"llvm.x86.avx512.mask.compress.v32i16"(halves[1], @splat(0), @bitCast(hi));
        },
        .shuffle => {
            const octets: [window / 8]B16 = @bitCast(units);
            var o: usize = 0;
            inline for (octets, 0..) |v, h| {
                const m = keep >> (8 * h) & 0xFF;
                d[o..][0..8].* = @bitCast(shuffleBytes(v, pack_units[m]));
                o += @popCount(m);
            }
        },
        .store => {
            // Each unit stored, then overwritten by the next unless kept.
            const us: [window]u16 = units;
            var o: usize = 0;
            inline for (us, 0..) |unit, j| {
                d[o] = unit;
                o += @intCast(keep >> j & 1);
            }
        },
    }
    return @popCount(keep);
}

/// Transcodes UTF-8 from the start of `src` to UTF-16 in the machine's
/// byte order at the start of `dst`, `window` bytes at a time, while `src`
/// has two more bytes than that left and `dst` room for as many units.
/// Stops at the first byte that does not begin ASCII or a well-formed two-
/// or three-byte sequence: a four-byte sequence, which the stage does not
/// hold, or ill-formed UTF-8, which the caller reads a character at a
/// time. Every unit it writes is below U+10000 and not a surrogate. Each
/// byte's unit is computed from it and the two after it on every lane at
/// once, and `packUnits` keeps the units of the bytes that start a
/// character.
pub inline fn utf8ToBmp(src: []const u8, dst: []u16) Converted {
    const B = @Vector(window, u8);
    const U = @Vector(window, u16);
    var r: usize = 0;
    var w: usize = 0;
    // The bytes at the start of the window that end the last character of
    // the window before. Windows start every `window` bytes, so that the
    // next one's loads do not wait on this one's masks.
    var carry: u32 = 0;
    while (src.len - r >= window + 2 and dst.len - w >= window) {
        const b: B = src[r..][0..window].*;
        const n1: B = src[r + 1 ..][0..window].*;
        const n2: B = src[r + 2 ..][0..window].*;
        // Masks of 0xFF and 0, so that they combine as vectors and shift
        // by lanes, and only four become bits.
        const cont1 = ones(n1 & @as(B, @splat(0xC0)) == @as(B, @splat(0x80)));
        const cont2 = ones(n2 & @as(B, @splat(0xC0)) == @as(B, @splat(0x80)));
        // C2 to DF, then E0 to EF less E0's overlong forms (second byte
        // below A0) and ED's surrogates (second byte from A0).
        const lead2 = ones(b -% @as(B, @splat(0xC2)) < @as(B, @splat(0x1E)));
        const lead3 = ones(b & @as(B, @splat(0xF0)) == @as(B, @splat(0xE0)));
        const low = ones(n1 < @as(B, @splat(0xA0)));
        const e0 = ones(b == @as(B, @splat(0xE0))) & low;
        const ed = ones(b == @as(B, @splat(0xED))) & ~low;
        const two = lead2 & cont1;
        const three = lead3 & cont1 & cont2 & ~e0 & ~ed;
        const start = ones(b < @as(B, @splat(0x80))) | two | three;
        // A continuation byte is good only as the tail of the character
        // before it.
        const cont = ones(b & @as(B, @splat(0xC0)) == @as(B, @splat(0x80)));
        const tail = cont & (lanesUp(two | three, 1) | lanesUp(three, 2));
        const good = windowBits((start | tail) != @as(B, @splat(0))) | (@as(u64, 1) << @intCast(carry)) - 1;
        const end = @ctz(~good);
        const starts = windowBits(start != @as(B, @splat(0))) & std.math.shl(u64, 1, end) -% 1;
        // Each lane's unit as its low and high bytes, from the lane's byte
        // and the two after it, then the two interleaved in the machine's
        // byte order.
        const ascii = b < @as(B, @splat(0x80));
        const is3 = b >= @as(B, @splat(0xE0));
        const lo2 = b << @splat(6) | (n1 & @as(B, @splat(0x3F)));
        const lo3 = n1 << @splat(6) | (n2 & @as(B, @splat(0x3F)));
        const hi2 = b >> @splat(2) & @as(B, @splat(0x07));
        const hi3 = b << @splat(4) | (n1 >> @splat(2) & @as(B, @splat(0x0F)));
        const lo = @select(u8, ascii, b, @select(u8, is3, lo3, lo2));
        const hi = @select(u8, ascii, @as(B, @splat(0)), @select(u8, is3, hi3, hi2));
        const units: U = @bitCast(@shuffle(u8, lo, hi, blk: {
            var x: [2 * window]i32 = undefined;
            const low_first = native_endian == .little;
            for (&x, 0..) |*e, j| e.* = if ((j % 2 == 0) == low_first) j / 2 else ~@as(i32, j / 2);
            break :blk x;
        }));
        w += packUnits(units, starts, dst[w..][0..window]);
        if (end != window) return .{ .read = r + end, .written = w };
        // The last character may end in the next window's first two
        // bytes: every byte here is good, so its lead says how many. From
        // the bytes, not the masks, which costs SSE a lane at a time.
        const last = src[r + window - 1];
        const prev = src[r + window - 2];
        carry = @as(u32, @intFromBool(last >= 0xC0)) + @intFromBool(last >= 0xE0) +
            @intFromBool(last < 0xC0 and prev >= 0xE0);
        r += window;
    }
    return .{ .read = r + carry, .written = w };
}

/// 0xFF in each lane where `c` holds, 0 elsewhere.
inline fn ones(c: @Vector(window, bool)) @Vector(window, u8) {
    return @select(u8, c, @as(@Vector(window, u8), @splat(0xFF)), @as(@Vector(window, u8), @splat(0)));
}

/// `m` moved `n` lanes up, zeros below.
inline fn lanesUp(m: @Vector(window, u8), comptime n: usize) @Vector(window, u8) {
    const idx = comptime blk: {
        var x: [window]i32 = undefined;
        for (&x, 0..) |*e, j| e.* = if (j >= n) j - n else -1;
        break :blk x;
    };
    return @shuffle(u8, m, @as(@Vector(window, u8), @splat(0)), idx);
}

/// The input below which `encodeStaged` is not worth a call: four blocks,
/// and at least what `utf8ToBmp` reads at a time.
pub const staged_min = @max(4 * ascii_block, window + 2);

/// Whether `s`, UTF-8, holds three or more characters from U+0080, or
/// two from U+0800: more than `encodeStaged` costs to start. Sparser
/// text, as Latin with the odd accented letter, goes faster a character
/// at a time between ASCII runs.
pub inline fn denseUtf8(s: *const [ascii_block]u8) bool {
    const v: @Vector(ascii_block, u8) = s.*;
    return @popCount(highBits(v >= @as(@Vector(ascii_block, u8), @splat(0x80)))) >= 6;
}

/// Encodes UTF-8 from the start of `src` into `dst` through UTF-16, for
/// an encoder whose characters are one byte each and that has no SIMD
/// UTF-8 path of its own: `utf8ToBmp` transcodes up to `stage_len`
/// bytes, and `coder` encodes the units, `coder.encodeBlock(s, d)` a
/// block at a time (the lane of the first unit it cannot map, or
/// `ascii_block`) and `coder.byteOf(u)` one non-ASCII unit at a time (0
/// for none). In html mode a character the encoding lacks becomes a
/// numeric character reference here too, so that a run of them does not
/// go back to the caller one at a time. Stops at the first such character
/// in fatal mode, where `utf8ToBmp` stops (a four-byte or ill-formed
/// sequence, or the last `window + 1` bytes of `src`), and when `dst` is full;
/// returns the bytes read and written.
pub noinline fn encodeStaged(coder: anytype, src: []const u8, dst: []u8, mode: EncoderMode) Converted {
    const W = @Vector(ascii_block, u16);
    var stage: [stage_len]u16 = undefined;
    // Enough input that the last window can fill the stage.
    const units = utf8ToBmp(src[0..@min(src.len, stage.len + window + 2)], &stage).written;
    var k: usize = 0;
    var r: usize = 0;
    var w: usize = 0;
    while (k < units) {
        if (units - k >= ascii_block and dst.len - w >= ascii_block) {
            const a = asciiBlocksOut(u16, stage[k..units], dst[w..]);
            if (a != 0) {
                k += a;
                r += a;
                w += a;
                continue;
            }
            const u: W = stage[k..][0..ascii_block].*;
            const n = coder.encodeBlock(stage[k..][0..ascii_block], dst[w..][0..ascii_block]);
            // A unit from U+0080 took two bytes of UTF-8, from U+0800 three.
            const done: u16 = if (n == ascii_block) 0xFFFF else (@as(u16, 1) << @intCast(n)) - 1;
            r += n + @as(usize, @popCount(highBits(u >= @as(W, @splat(0x80))) & done)) +
                @popCount(highBits(u >= @as(W, @splat(0x800))) & done);
            k += n;
            w += n;
            if (n == ascii_block) continue;
        } else {
            const u = stage[k];
            const b: u8 = if (u < 0x80) @intCast(u) else coder.byteOf(u);
            if (b != 0 or u == 0) {
                if (w == dst.len) break;
                dst[w] = b;
                w += 1;
                k += 1;
                r += unitsOf(u8, u);
                continue;
            }
        }
        // `stage[k]` is a character the encoding lacks.
        if (mode == .fatal) break;
        const u = stage[k];
        w += putNcr(dst, w, u) orelse break;
        k += 1;
        r += unitsOf(u8, u);
    }
    return .{ .read = r, .written = w };
}

/// A scalar value an encoder read, and the units it took, as plain
/// integers. The code point is a `u32`, not a `u21`: LLVM merges a `u21`
/// from two paths through a three-byte store and a four-byte load, a
/// store-forwarding stall on every character.
pub const Read = struct { cp: u32, len: u32 };

/// The scalar value at `src[i]`, `src[i] >= 0x80`, as `readScalar` reads
/// it, with well-formed two- and three-byte UTF-8 sequences inline.
/// `first` is the length the caller sees most, whose check comes first:
/// 2 for the Latin, Greek, Cyrillic, Hebrew, and Arabic text of the
/// single-byte encodings, 3 for CJK. Each check costs the other's
/// characters a compare and a branch, which on short characters shows.
pub inline fn read(comptime Unit: type, src: []const Unit, i: usize, comptime first: u2) Read {
    if (Unit == u8) {
        const c = src[i];
        inline for (if (first == 2) .{ 2, 3 } else .{ 3, 2 }) |n| {
            if (n == 2 and c >= 0xC2 and c <= 0xDF and src.len - i >= 2) {
                const c1 = src[i + 1];
                if (c1 & 0xC0 == 0x80) return .{ .cp = @as(u32, c & 0x1F) << 6 | (c1 & 0x3F), .len = 2 };
            }
            // E0 needs second bytes from A0 (no overlong forms), ED up to
            // 9F (no surrogates), the others any continuation byte; E0
            // second, as only scripts below U+1000 have it.
            if (n == 3 and src.len - i >= 3) {
                const c1 = src[i + 1];
                const c2 = src[i + 2];
                const tail = c1 & 0xC0 == 0x80 and c2 & 0xC0 == 0x80;
                if ((c >= 0xE1 and c <= 0xEF and c != 0xED and tail) or (c == 0xE0 and c1 >= 0xA0 and tail)) {
                    return .{ .cp = @as(u32, c & 0xF) << 12 | @as(u32, c1 & 0x3F) << 6 | (c2 & 0x3F), .len = 3 };
                }
            }
        }
    } else {
        const u = src[i];
        if (u < 0xD800 or u > 0xDFFF) return .{ .cp = u, .len = 1 };
    }
    const s = readScalar(Unit, src, i);
    return .{ .cp = s.cp, .len = @intCast(s.len) };
}

test "put and unitsOf agree with std.unicode" {
    const cps = [_]u21{ 0, 0x41, 0x7F, 0x80, 0x7FF, 0x800, 0xFFFD, 0xFFFF, 0x10000, 0x10FFFF };
    for (cps) |cp| {
        var buf: [4]u8 = undefined;
        const n = put(u8, &buf, 0, cp);
        var want: [4]u8 = undefined;
        const m = try std.unicode.utf8Encode(cp, &want);
        try std.testing.expectEqualSlices(u8, want[0..m], buf[0..n]);
        try std.testing.expectEqual(n, unitsOf(u8, cp));
        var w: [2]u16 = undefined;
        const k = put(u16, &w, 0, cp);
        try std.testing.expectEqual(k, unitsOf(u16, cp));
        try std.testing.expectEqual(cp, readScalar(u16, w[0..k], 0).cp);
        try std.testing.expectEqual(cp, readScalar(u8, buf[0..n], 0).cp);
    }
}

test "read agrees with readScalar on every two- and three-byte prefix" {
    var buf: [3]u8 = undefined;
    for (0x80..0x100) |a| for (0..0x100) |b| for (0..0x100) |c| {
        if (c != 0 and (a < 0xE0 or a > 0xEF)) break;
        buf = .{ @intCast(a), @intCast(b), @intCast(c) };
        // With the third byte and without it, so a cut sequence is seen.
        for ([_][]const u8{ buf[0..3], buf[0..2] }) |s| {
            const want = readScalar(u8, s, 0);
            inline for (.{ 2, 3 }) |first| {
                const got = read(u8, s, 0, first);
                try std.testing.expectEqual(@as(u32, want.cp), got.cp);
                try std.testing.expectEqual(want.len, got.len);
            }
        }
    };
}

test "putNcr writes the shortest decimal" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("&#0;", buf[0..putNcr(&buf, 0, 0).?]);
    try std.testing.expectEqualStrings("&#8364;", buf[0..putNcr(&buf, 0, 0x20AC).?]);
    try std.testing.expectEqualStrings("&#1114111;", buf[0..putNcr(&buf, 0, 0x10FFFF).?]);
    try std.testing.expectEqual(@as(?usize, null), putNcr(buf[0..6], 0, 0x20AC));
}

test "putBmp writes two or three bytes, or nothing when they do not fit" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("\xDF\xBF", buf[0..putBmp(u8, &buf, 0, 0x7FF)]);
    try std.testing.expectEqualStrings("\xE0\xA0\x80", buf[0..putBmp(u8, &buf, 0, 0x800)]);
    try std.testing.expectEqual(@as(usize, 0), putBmp(u8, &buf, 2, 0x800));
    try std.testing.expectEqual(@as(usize, 2), putBmp(u8, &buf, 2, 0x7FF));
    var units: [1]u16 = undefined;
    try std.testing.expectEqual(@as(usize, 1), putBmp(u16, &units, 0, 0xFFFF));
    try std.testing.expectEqual(@as(usize, 0), putBmp(u16, &units, 1, 0xFFFF));
}

test "bmpToUtf8 writes every BMP code point as put does, and as many as fit" {
    var rng: std.Random.DefaultPrng = .init(1);
    var cp: u32 = 0;
    while (cp < 0x10000) {
        // 53 code points: a step of 32, one of 16, and five alone.
        // Consecutive ones, so that every code point comes at every
        // offset, with a few of each length put among them at random.
        var u: [53]u16 = undefined;
        for (&u) |*x| {
            while (cp >= 0xD800 and cp <= 0xDFFF) cp += 1;
            x.* = @intCast(cp % 0x10000);
            cp += 1;
        }
        for (0..4) |_| {
            const lane = rng.random().uintLessThan(usize, u.len);
            u[lane] = ([_]u16{ 0, 0x41, 0x3B1, 0x20AC })[rng.random().uintLessThan(usize, 4)];
        }
        var want: [3 * u.len]u8 = undefined;
        var ends: [u.len + 1]usize = undefined;
        ends[0] = 0;
        for (u, 0..) |x, k| ends[k + 1] = ends[k] + put(u8, &want, ends[k], x);
        var got: [3 * u.len + pack_room]u8 = undefined;
        const room = rng.random().uintAtMost(usize, got.len);
        const r = bmpToUtf8(&u, got[0..room]);
        // Whole characters only, and all that fit.
        try std.testing.expectEqual(ends[r.read], r.written);
        try std.testing.expect(r.read == u.len or ends[r.read + 1] > room);
        try std.testing.expectEqualSlices(u8, want[0..r.written], got[0..r.written]);
    }
}

test "utf8ToBmp stops at the first character it does not take, wherever it is" {
    // Every two-byte sequence from a byte from 0x80, and with a byte from
    // E0 a set of third bytes, at every offset of the first window and
    // across into the next, in a buffer of ASCII and Greek: the units must
    // be what `utf8Step` reads up to where it stops, and it may stop only
    // at a four-byte or ill-formed sequence or within `window + 2` bytes
    // of the end.
    const thirds = [_]u8{ 0x41, 0x7F, 0x80, 0x9F, 0xA0, 0xBF, 0xC0, 0xC2, 0xE0, 0xED, 0xF0, 0xFF };
    const greek = " \xCE\xB1\xCE\xB1";
    var buf: [2 * window + 8]u8 = undefined;
    var units: [buf.len]u16 = undefined;
    for (0x8000..0x10000) |ab| for (thirds) |c| for (0..window + 3) |at| {
        if (ab >> 8 < 0xE0 and c != thirds[0]) break;
        for (&buf, 0..) |*x, k| x.* = greek[k % greek.len];
        // Character boundaries before and after the sequence.
        if (at > 0 and buf[at - 1] == 0xCE) buf[at - 1] = 0x20;
        if (buf[at + 3] == 0xB1) buf[at + 3] = 0x20;
        buf[at..][0..3].* = .{ @intCast(ab >> 8), @truncate(ab), c };
        const r = utf8ToBmp(&buf, &units);
        var i: usize = 0;
        var w: usize = 0;
        while (i < r.read) {
            const s = switch (utf8Step(buf[i..])) {
                .scalar => |s| s,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expect(s.cp < 0x10000);
            try std.testing.expectEqual(@as(u16, @intCast(s.cp)), units[w]);
            i += s.len;
            w += 1;
        }
        try std.testing.expectEqual(r.read, i);
        try std.testing.expectEqual(r.written, w);
        if (buf.len - r.read >= window + 2) switch (utf8Step(buf[r.read..])) {
            .scalar => |s| try std.testing.expect(s.cp >= 0x10000),
            else => {},
        };
    };
}

test "utf8Step follows the standard's maximal subparts" {
    const T = std.testing;
    try T.expectEqual(Utf8Step{ .invalid = 1 }, utf8Step("\x80"));
    try T.expectEqual(Utf8Step{ .invalid = 1 }, utf8Step("\xC0\x80"));
    try T.expectEqual(Utf8Step{ .invalid = 1 }, utf8Step("\xE0\x80\x80"));
    try T.expectEqual(Utf8Step{ .invalid = 2 }, utf8Step("\xE0\xA0\x41"));
    try T.expectEqual(Utf8Step{ .invalid = 1 }, utf8Step("\xED\xA0\x80"));
    try T.expectEqual(Utf8Step{ .incomplete = 2 }, utf8Step("\xF0\x90"));
    try T.expectEqual(Utf8Step{ .invalid = 3 }, utf8Step("\xF0\x90\x80\x41"));
    try T.expectEqual(Utf8Step{ .invalid = 1 }, utf8Step("\xF5\x80"));
    try T.expectEqual(@as(u21, 0x10FFFF), utf8Step("\xF4\x8F\xBF\xBF").scalar.cp);
    try T.expectEqual(@as(usize, 2), incompleteTail(u8, "ab\xF0\x90"));
    try T.expectEqual(@as(usize, 0), incompleteTail(u8, "ab\xF0\x90\x80\x80"));
    try T.expectEqual(@as(usize, 0), incompleteTail(u8, "ab\xC0"));
    try T.expectEqual(@as(usize, 1), incompleteTail(u16, &.{ 0x41, 0xD800 }));
}
