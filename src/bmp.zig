//! The kernels of `convert.bmpToUtf8` and `convert.utf8ToBmp`: UTF-16 in
//! the machine's byte order that holds only code points below U+10000, and
//! no surrogates, to and from UTF-8. Without surrogate pairs neither
//! direction has a four-byte path, which keeps them small enough for a
//! caller that stages text through UTF-16, such as a single-byte decoder,
//! where the general converters' tables would outweigh the caller.
//!
//! How characters of different lengths are packed together is chosen at
//! compile time from the target, so each tier of the run-time dispatch has
//! its own (`pack`): AVX-512 VBMI2's `vpcompressb` and `vpcompressw`; a byte
//! shuffle (SSSE3's `pshufb`, two groups at once with AVX2's `vpshufb`,
//! NEON's `tbl`) indexed by tables of 256 shuffles for each eight 16-bit
//! lanes or four 32-bit lanes, 8,448 bytes for `bmpToUtf8` and 4,096 for
//! `utf8ToBmp`; or, with neither, a store a character.

const std = @import("std");
const builtin = @import("builtin");
const simd = @import("simd.zig");
const BmpResult = @import("result.zig").BmpResult;
const dispatch = @import("dispatch.zig");

const native = builtin.cpu.arch.endian();
const llvm = builtin.zig_backend == .stage2_llvm;

const Pack = enum { compress, shuffle, store };

const pack: Pack = if (!llvm or native != .little)
    .store
else if (simd.has_vbmi2)
    .compress
else switch (simd.isa) {
    .avx512, .avx2, .sse, .neon => .shuffle,
    .generic => .store,
};

/// The code units the vector paths take at a time.
const block = 16;

const B16 = @Vector(16, u8);

/// Each 16-byte half of `v` shuffled by its own indices, `lo` and `hi`:
/// with AVX2 one `vpshufb`, which takes as long as one of 16 bytes.
inline fn shufflePair(v: @Vector(32, u8), lo: B16, hi: B16) [2]B16 {
    return @bitCast(simd.shuffleLanes(v, @as(@Vector(32, u8), @bitCast([2]B16{ lo, hi }))));
}

/// Shuffle indices for each group of eight 16-bit lanes: entry `n` lists
/// the bytes to keep, in order, then zeros; `keep(n, b)` says whether byte
/// `b` (0 to 15) of the group is kept. Arrays, not vectors, so that
/// `dispatch.shared` can export them.
fn packTable(comptime keep: fn (u8, u4) bool) [256][16]u8 {
    @setEvalBranchQuota(10_000);
    var t: [256][16]u8 = undefined;
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

/// Eight code points below U+0800 as two bytes each, lead then trail: bit
/// `i` of `n` is set for each that is ASCII and keeps only its lead.
const pack_narrow = dispatch.shared("bmp_pack_narrow", packTable(struct {
    fn keep(n: u8, b: u4) bool {
        return b % 2 == 0 or n >> (b / 2) & 1 == 0;
    }
}.keep));

/// Eight UTF-16 units: bit `i` of `n` is set for each to keep.
const pack_units = dispatch.shared("bmp_pack_units", packTable(struct {
    fn keep(n: u8, b: u4) bool {
        return n >> (b / 2) & 1 == 1;
    }
}.keep));

/// Four code points as four bytes each, of which they take one to three:
/// entry `n` for code points `j` taking `1 + (n >> 2 * j & 1) + (n >> 2 *
/// j + 1 & 1)` bytes (the second bit set only with the first), and in
/// `lens` the bytes all four take.
const quads: extern struct { shuffles: [256][16]u8, lens: [256]u8 } = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256][16]u8 = undefined;
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
const pack_quads = dispatch.shared("bmp_pack_quads", quads);

/// Packs `words`, two bytes for each of `16 * n` code points below U+0800,
/// where bit `i` of `a` is set for each that is ASCII, to `d` with the byte
/// shuffle, eight code points at a time, and returns the bytes written.
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

/// The room a step of `bmpToUtf8` needs: three bytes for each of 16 code
/// points or two for each of 32, and the stores past them.
const pack_room = 4 * block;

/// Transcodes `src` to UTF-8 at the start of `dst`, as many characters as
/// fit whole: 32 code points at a time while they are all below U+0800,
/// else 16, then one at a time.
pub fn bmpToUtf8(src: []const u16, dst: []u8) BmpResult {
    // For the tier objects' shuffles, whatever this build's `pack`.
    comptime {
        _ = pack_narrow;
        _ = pack_quads;
    }
    const N = @Vector(2 * block, u16);
    var i: usize = 0;
    var o: usize = 0;
    while (src.len - i >= block and dst.len - o >= pack_room) {
        var blocks: usize = 1;
        if (src.len - i >= 2 * block) {
            const c: N = src[i..][0 .. 2 * block].*;
            // ASCII between other text, which the byte shuffle and the
            // stores are slower at than this; `vpcompressb` is not.
            if (pack != .compress and @reduce(.And, c < @as(N, @splat(0x80)))) {
                dst[o..][0 .. 2 * block].* = @as(@Vector(2 * block, u8), @truncate(c));
                o += 2 * block;
                i += 2 * block;
                continue;
            }
            if (@reduce(.And, c < @as(N, @splat(0x800)))) {
                o += packNarrow(c, dst[o..][0..pack_room]);
                i += 2 * block;
                continue;
            }
            // Both blocks, not testing the second on its own again.
            blocks = 2;
        }
        for (0..blocks) |_| {
            if (dst.len - o < pack_room) break;
            o += blockToUtf8(src[i..][0..block].*, dst[o..][0..pack_room]);
            i += block;
        }
    }
    while (i < src.len) : (i += 1) {
        const c = src[i];
        const n: usize = if (c < 0x80) 1 else if (c < 0x800) 2 else 3;
        if (dst.len - o < n) break;
        switch (n) {
            1 => dst[o] = @intCast(c),
            // `&` and `|` share a precedence: the trail's bits first.
            2 => dst[o..][0..2].* = .{ @intCast(0xC0 | c >> 6), @intCast(0x80 | (c & 0x3F)) },
            else => dst[o..][0..3].* = .{
                @intCast(0xE0 | c >> 12),
                @intCast(0x80 | (c >> 6 & 0x3F)),
                @intCast(0x80 | (c & 0x3F)),
            },
        }
        o += n;
    }
    return .{ .read = i, .written = o };
}

/// Writes `c`, 32 code points below U+0800, as UTF-8 at the start of `d`
/// and returns the bytes written; it may write anything to the rest of
/// `d`. Each code point is two bytes in a 16-bit lane, lead then trail, of
/// which ASCII keeps the first.
inline fn packNarrow(c: @Vector(2 * block, u16), d: *[pack_room]u8) usize {
    const N = @Vector(2 * block, u16);
    const ascii = c < @as(N, @splat(0x80));
    const trail = c & @as(N, @splat(0x3F)) | @as(N, @splat(0x80));
    const two = (c >> @splat(6) | @as(N, @splat(0xC0))) | trail << @splat(8);
    const words = @select(u16, ascii, c, two);
    const a: u32 = simd.bitmask(ascii);
    switch (pack) {
        .compress => {
            // Every lead byte, and every trail byte but ASCII's zero.
            const bytes: @Vector(64, u8) = @bitCast(words);
            const keep = simd.bitmask(bytes != @as(@Vector(64, u8), @splat(0))) | 0x5555_5555_5555_5555;
            d.* = simd.compress(bytes, keep);
            return 64 - @as(usize, @popCount(a));
        },
        .shuffle => return shuffleNarrow(2, @bitCast(words), a, d),
        .store => {
            // Eight lanes at a time: all ASCII, one store, as in Latin text
            // with the odd accented letter; else a store a lane.
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
/// `block`, `first + k` and `first + 8 + k` for `k` below 4: lane from the
/// first vector, then from the second.
fn interleave(first: i32) [block]i32 {
    var x: [block]i32 = undefined;
    for (&x, 0..) |*e, j| {
        const lane = first + @as(i32, @intCast(j / 8 * 8 + j % 8 / 2));
        e.* = if (j % 2 == 0) lane else ~lane;
    }
    return x;
}

/// Writes `u`, a block of code points below U+10000 that are not
/// surrogates, as UTF-8 at the start of `d`, and returns the bytes it
/// wrote, `block` to `3 * block`; it may write anything to the rest of `d`.
/// Each code point's UTF-8 is built in a 32-bit lane, all at once, then
/// packed as `pack` says; on the shuffle targets in 16-bit lanes, and a
/// block below U+0800 as two bytes a lane.
inline fn blockToUtf8(u: @Vector(block, u16), d: *[pack_room]u8) usize {
    switch (pack) {
        .compress, .store => {
            const U = @Vector(block, u32);
            const c: U = u;
            const low: U = c & @as(U, @splat(0x3F)) | @as(U, @splat(0x80));
            const mid: U = c >> @splat(6) & @as(U, @splat(0x3F)) | @as(U, @splat(0x80));
            const two = (c >> @splat(6) | @as(U, @splat(0xC0))) | low << @splat(8);
            const three = (c >> @splat(12) | @as(U, @splat(0xE0))) | mid << @splat(8) | low << @splat(16);
            const ascii = c < @as(U, @splat(0x80));
            const narrow = c < @as(U, @splat(0x800));
            const words = @select(u32, ascii, c, @select(u32, narrow, two, three));
            if (pack == .compress) {
                // Every lane's first byte, and the others but zeros: only
                // ASCII has a zero byte, and the leads and trails of longer
                // characters none.
                const bytes: @Vector(64, u8) = @bitCast(words);
                const keep = simd.bitmask(bytes != @as(@Vector(64, u8), @splat(0))) | 0x1111_1111_1111_1111;
                d.* = simd.compress(bytes, keep);
                return @popCount(keep);
            }
            // Each word stored four bytes wide, overwritten by the next.
            const one: U = @splat(1);
            const lens = @select(u32, ascii, one, @select(u32, narrow, one + one, one + one + one));
            const ws: [block]u32 = words;
            const ls: [block]u32 = lens;
            var o: usize = 0;
            inline for (ws, ls) |w, n| {
                std.mem.writeInt(u32, d[o..][0..4], w, .little);
                o += n;
            }
            return o;
        },
        .shuffle => {
            // `lo` a code point's first two bytes, `hi` its third.
            const H = @Vector(block, u16);
            const ascii = u < @as(H, @splat(0x80));
            const narrow = u < @as(H, @splat(0x800));
            const trail = u & @as(H, @splat(0x3F)) | @as(H, @splat(0x80));
            const two = (u >> @splat(6) | @as(H, @splat(0xC0))) | trail << @splat(8);
            // Two bits a code point, in a byte of its own: from U+0080, and
            // from U+0800; four code points' bits are a table index.
            const kind = @select(u16, ascii, @as(H, @splat(0)), @select(
                u16,
                narrow,
                @as(H, @splat(0x00FF)),
                @as(H, @splat(0xFFFF)),
            ));
            const S = @Vector(2 * block, i8);
            const kinds: u32 = simd.bitmask(@as(S, @bitCast(kind)) < @as(S, @splat(0)));
            if (kinds & 0xAAAA_AAAA == 0) {
                // Two bytes a lane, the second dropped for ASCII.
                return shuffleNarrow(1, @bitCast(@select(u16, ascii, u, two)), simd.bitmask(ascii), d);
            }
            const mid = u >> @splat(6) & @as(H, @splat(0x3F)) | @as(H, @splat(0x80));
            const three = (u >> @splat(12) | @as(H, @splat(0xE0))) | mid << @splat(8);
            if (kinds == 0xFFFF_FFFF) {
                // Three bytes each, as Thai or Chinese text is: the same
                // shuffle for every group, without the table's loads in the
                // way (Thai 1.16x with SSSE3, 1.27x with AVX2).
                const qa: @Vector(32, u8) = @bitCast(@shuffle(u16, three, trail, interleave(0)));
                const qb: @Vector(32, u8) = @bitCast(@shuffle(u16, three, trail, interleave(4)));
                const s = comptime quads.shuffles[0xFF];
                const pa = shufflePair(qa, s, s);
                const pb = shufflePair(qb, s, s);
                inline for (.{ pa[0], pb[0], pa[1], pb[1] }, 0..) |q, g| d[12 * g ..][0..16].* = q;
                return 3 * block;
            }
            const lo = @select(u16, ascii, u, @select(u16, narrow, two, three));
            const hi = @select(u16, narrow, @as(H, @splat(0)), trail);
            // Four bytes a code point, `lo` then `hi`, four a shuffle: `qa`
            // holds code points 0 to 3 and 8 to 11, `qb` the others, which
            // interleaves within each 16 bytes of an AVX2 register.
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
    }
}

/// The bytes `utf8ToBmp` reads at a time: a register of AVX-512, or two of
/// SSE or NEON, one of AVX2.
const window = if (pack == .compress) 4 * block else 2 * block;
const Mask = @Int(.unsigned, window);

/// Writes the lanes of `units` whose bit is set in `keep` to the start of
/// `d`, in order; it may write anything to the rest.
inline fn packUnits(units: @Vector(window, u16), keep: Mask, d: *[window]u16) void {
    switch (pack) {
        .compress => {
            // 32 units at a time, the second half after the first's.
            const halves: [2]@Vector(32, u16) = @bitCast(units);
            const lo: u32 = @truncate(keep);
            const hi: u32 = @truncate(keep >> 32);
            d[0..32].* = simd.compress(halves[0], lo);
            d[@popCount(lo)..][0..32].* = simd.compress(halves[1], hi);
        },
        .shuffle => {
            const octets: [window / 8]B16 = @bitCast(units);
            var o: usize = 0;
            inline for (octets, 0..) |v, h| {
                const m: u8 = @truncate(keep >> (8 * h));
                d[o..][0..8].* = @bitCast(simd.shuffleLanes(v, pack_units[m]));
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
}

/// What one window of UTF-8 gives: each lane's unit, a bit for each lane
/// that starts a character to keep, and the first lane that is not good.
const Window = struct { units: @Vector(window, u16), starts: Mask, end: usize };

/// Decodes the window `b`, whose next bytes are `n1` and `n2` (its bytes
/// one and two lanes on), of which the first `limit` lanes are input and
/// the first `carry` end the character before the window. Each lane's unit
/// is computed from its byte and the two after it on every lane at once; a
/// lane is good where it starts ASCII or a well-formed two- or three-byte
/// sequence, or continues one.
inline fn decodeWindow(
    b: @Vector(window, u8),
    n1: @Vector(window, u8),
    n2: @Vector(window, u8),
    carry: u32,
    limit: usize,
) Window {
    const B = @Vector(window, u8);
    // Masks of 0xFF and 0, so that they combine as vectors and shift by
    // lanes, and only four become bits.
    const cont1 = ones(n1 & @as(B, @splat(0xC0)) == @as(B, @splat(0x80)));
    const cont2 = ones(n2 & @as(B, @splat(0xC0)) == @as(B, @splat(0x80)));
    // C2 to DF, then E0 to EF less E0's overlong forms (second byte below
    // A0) and ED's surrogates (second byte from A0).
    const lead2 = ones(b -% @as(B, @splat(0xC2)) < @as(B, @splat(0x1E)));
    const lead3 = ones(b & @as(B, @splat(0xF0)) == @as(B, @splat(0xE0)));
    const low = ones(n1 < @as(B, @splat(0xA0)));
    const e0 = ones(b == @as(B, @splat(0xE0))) & low;
    const ed = ones(b == @as(B, @splat(0xED))) & ~low;
    const two = lead2 & cont1;
    const three = lead3 & cont1 & cont2 & ~e0 & ~ed;
    const start = ones(b < @as(B, @splat(0x80))) | two | three;
    // A continuation byte is good only as the tail of the character before
    // it.
    const cont = ones(b & @as(B, @splat(0xC0)) == @as(B, @splat(0x80)));
    const tail = cont & (lanesUp(two | three, 1) | lanesUp(three, 2));
    var good = simd.bitmask((start | tail) != @as(B, @splat(0))) | (@as(Mask, 1) << @intCast(carry)) - 1;
    if (limit < window) good &= (@as(Mask, 1) << @intCast(limit)) - 1;
    const end = @ctz(~good);
    const starts = simd.bitmask(start != @as(B, @splat(0))) & std.math.shl(Mask, 1, end) -% 1;
    // Each lane's unit as its low and high bytes, from the lane's byte and
    // the two after it, then the two interleaved in the machine's byte
    // order.
    const ascii = b < @as(B, @splat(0x80));
    const is3 = b >= @as(B, @splat(0xE0));
    const lo2 = b << @splat(6) | (n1 & @as(B, @splat(0x3F)));
    const lo3 = n1 << @splat(6) | (n2 & @as(B, @splat(0x3F)));
    const hi2 = b >> @splat(2) & @as(B, @splat(0x07));
    const hi3 = b << @splat(4) | (n1 >> @splat(2) & @as(B, @splat(0x0F)));
    const lo = @select(u8, ascii, b, @select(u8, is3, lo3, lo2));
    const hi = @select(u8, ascii, @as(B, @splat(0)), @select(u8, is3, hi3, hi2));
    const units: @Vector(window, u16) = @bitCast(@shuffle(u8, lo, hi, blk: {
        var x: [2 * window]i32 = undefined;
        for (&x, 0..) |*e, j| e.* = if ((j % 2 == 0) == (native == .little)) j / 2 else ~@as(i32, j / 2);
        break :blk x;
    }));
    return .{ .units = units, .starts = starts, .end = end };
}

/// The bytes at the start of the next window that end the last character
/// of the window ending at `src[at]`, every byte of which is good, so its
/// lead says how many. From the bytes, not the masks, which costs SSE a
/// lane at a time.
inline fn carryAt(src: []const u8, at: usize) u32 {
    const last = src[at - 1];
    const prev = src[at - 2];
    return @as(u32, @intFromBool(last >= 0xC0)) + @intFromBool(last >= 0xE0) +
        @intFromBool(last < 0xC0 and prev >= 0xE0);
}

/// Transcodes UTF-8 from the start of `src` to UTF-16 at the start of
/// `dst` while each character is ASCII or a well-formed two- or three-byte
/// sequence and fits, `window` bytes at a time: `packUnits` keeps the
/// units of the bytes that start a character. Windows start every `window`
/// bytes, so that the next one's loads do not wait on this one's masks.
/// The last window of input is zero-padded, and where `dst` has room for
/// fewer than `window` units a window goes through a buffer, as many of
/// whose units as fit are copied out: one loop for all of it, so the body
/// is there once.
pub fn utf8ToBmp(src: []const u8, dst: []u16) BmpResult {
    // For the tier objects' shuffles, whatever this build's `pack`.
    comptime {
        _ = pack_units;
    }
    const B = @Vector(window, u8);
    var r: usize = 0;
    var w: usize = 0;
    var carry: u32 = 0;
    var spare: [window]u16 = undefined;
    while (r + carry < src.len and w < dst.len) {
        const left = src.len - r;
        const x = if (left >= window + 2)
            decodeWindow(src[r..][0..window].*, src[r + 1 ..][0..window].*, src[r + 2 ..][0..window].*, carry, window)
        else if (simd.has_masked) blk: {
            // Masked loads, which read nothing past the input.
            const b = simd.loadShort(u8, src[r..][0..@min(left, window)]);
            const n1 = simd.loadShort(u8, src[r + 1 ..][0..@min(left - 1, window)]);
            const n2: B = if (left >= 2) simd.loadShort(u8, src[r + 2 ..][0..@min(left - 2, window)]) else @splat(0);
            break :blk decodeWindow(b, n1, n2, carry, @min(left, window));
        } else blk: {
            // The rest in one zero-padded block built in registers, and the
            // window and its next bytes moved out of it: built in a buffer,
            // the loads waited for the copy's stores (16-byte inputs now
            // 1.8x faster with AVX2, 1.2x with SSSE3 and SSE2).
            const rest = simd.loadPartial(u8, src[r..]);
            const limit = @min(left, window);
            break :blk decodeWindow(lanesFrom(rest, 0), lanesFrom(rest, 1), lanesFrom(rest, 2), carry, limit);
        };
        const room = dst.len - w;
        const n = @popCount(x.starts);
        packUnits(x.units, x.starts, if (room >= window) dst[w..][0..window] else &spare);
        if (room < window) {
            @memcpy(dst[w..][0..@min(n, room)], spare[0..@min(n, room)]);
            if (n > room) {
                // The input up to the first character that does not fit:
                // the lead of the start after the first `room`.
                var rest = x.starts;
                for (0..room) |_| rest &= rest - 1;
                return .{ .read = r + @ctz(rest), .written = dst.len };
            }
        }
        w += n;
        if (x.end != window) return .{ .read = r + x.end, .written = w };
        carry = carryAt(src, r + window);
        r += window;
    }
    return .{ .read = r + carry, .written = w };
}

/// The `window` lanes of the block `v` from lane `k`.
inline fn lanesFrom(v: simd.Block(u8), comptime k: usize) @Vector(window, u8) {
    return @shuffle(u8, v, undefined, std.simd.iota(i32, window) + @as(@Vector(window, i32), @splat(k)));
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

const testing = std.testing;
const convert = @import("convert.zig");
const scalar = @import("scalar_convert.zig");
const ConvertResult = @import("result.zig").ConvertResult;

/// The UTF-8 of `u` as `bmpToUtf8` writes it: a surrogate as the three
/// bytes it would take as a code point.
fn encodeUnit(u: u16, out: *[3]u8) usize {
    if (u >= 0xD800 and u <= 0xDFFF) {
        out.* = .{ @intCast(0xE0 | u >> 12), @intCast(0x80 | (u >> 6 & 0x3F)), @intCast(0x80 | (u & 0x3F)) };
        return 3;
    }
    return std.unicode.utf8Encode(u, out) catch unreachable;
}

/// Runs `convert.bmpToUtf8` on `src` into `size` bytes and expects the
/// whole characters that fit, from `std.unicode`, nothing written past
/// them, and, where all of `src` fits and has no surrogate, the output of
/// the general converter.
fn expectToUtf8(src: []const u16, size: usize) !void {
    var want: [3 * 1024]u8 = undefined;
    var n: usize = 0;
    var read: usize = 0;
    var surrogates = false;
    for (src) |u| {
        surrogates = surrogates or (u >= 0xD800 and u <= 0xDFFF);
        var b: [3]u8 = undefined;
        const k = encodeUnit(u, &b);
        if (n + k > size) break;
        @memcpy(want[n..][0..k], b[0..k]);
        n += k;
        read += 1;
    }
    var got: [3 * 1024 + 64]u8 = undefined;
    @memset(&got, 0xAA);
    const r = convert.bmpToUtf8(src, got[0..size]);
    errdefer std.debug.print("bmpToUtf8: {d} units into {d} bytes: want {d}/{d}, got {d}/{d}\n", .{
        src.len, size, read, n, r.read, r.written,
    });
    try testing.expectEqual(BmpResult{ .read = read, .written = n }, r);
    try testing.expectEqualSlices(u8, want[0..n], got[0..n]);
    for (got[size..]) |b| try testing.expectEqual(0xAA, b);
    if (read == src.len and !surrogates and native == .little) {
        var general: [3 * 1024]u8 = undefined;
        try testing.expectEqual(n, convert.validUtf16leToUtf8(src, &general));
        try testing.expectEqualSlices(u8, general[0..n], got[0..n]);
    }
}

/// Runs `convert.utf8ToBmp` on `src` into `size` units and expects what
/// the scalar reference gives up to the first error it reports or the
/// first four-byte character, whichever comes first, as many of those
/// characters as fit, and nothing written past them.
fn expectFromUtf8(src: []const u8, size: usize) !void {
    var want: [1024]u16 = undefined;
    const checked = scalar.utf8ToUtf16(native, src, &want);
    var stop = if (checked.err == .none) src.len else checked.count;
    // Before the error the input is well-formed, so a byte from 0xF0 leads
    // a four-byte character.
    for (src[0..stop], 0..) |c, i| {
        if (c >= 0xF0) {
            stop = i;
            break;
        }
    }
    var n = scalar.validUtf8ToUtf16(native, src[0..stop], &want);
    if (n > size) {
        // As many characters as fit: the input up to the lead after them.
        n = size;
        var i: usize = 0;
        for (0..size) |_| i += std.unicode.utf8ByteSequenceLength(src[i]) catch unreachable;
        stop = i;
    }
    var got: [1024 + 64]u16 = undefined;
    @memset(&got, 0xAAAA);
    const r = convert.utf8ToBmp(src, got[0..size]);
    errdefer std.debug.print("utf8ToBmp: {d} bytes into {d} units: want {d}/{d}, got {d}/{d}\n", .{
        src.len, size, stop, n, r.read, r.written,
    });
    try testing.expectEqual(BmpResult{ .read = stop, .written = n }, r);
    try testing.expectEqualSlices(u16, want[0..n], got[0..n]);
    for (got[size..]) |u| try testing.expectEqual(0xAAAA, u);
    if (native == .little and stop == src.len) {
        var general: [1024]u16 = undefined;
        const g = convert.utf8ToUtf16le(src, &general);
        try testing.expectEqual(ConvertResult.ok(n), g);
        try testing.expectEqualSlices(u16, general[0..n], got[0..n]);
    }
}

/// A code point below U+10000 that is not a surrogate, of a length of
/// UTF-8 `kind` picks: 1, 2, or 3 bytes; 0 any of them; 4 one or two, 5 one
/// or three, 6 two or three.
fn randomBmp(r: std.Random, kind: u8) u16 {
    const len: u8 = switch (kind) {
        0 => r.intRangeAtMost(u8, 1, 3),
        1, 2, 3 => kind,
        4 => r.intRangeAtMost(u8, 1, 2),
        5 => if (r.boolean()) 1 else 3,
        else => r.intRangeAtMost(u8, 2, 3),
    };
    return switch (len) {
        1 => r.uintLessThan(u16, 0x80),
        2 => r.intRangeLessThan(u16, 0x80, 0x800),
        else => blk: {
            const u = r.intRangeLessThan(u16, 0x800, 0x10000 - 0x800);
            break :blk if (u >= 0xD800) u + 0x800 else u;
        },
    };
}

/// Fills `text` with `prefix` code points of the lengths `kind` picks
/// (`randomBmp`), then `cps`.
fn bmpText(r: std.Random, text: []u16, prefix: usize, kind: u8, cps: []const u16) []u16 {
    for (text[0..prefix]) |*u| u.* = randomBmp(r, kind);
    @memcpy(text[prefix..][0..cps.len], cps);
    return text[0 .. prefix + cps.len];
}

test "bmpToUtf8 writes every BMP code point at every block offset, as many as fit" {
    try dispatch.forEachLevel(toUtf8Cases, .{});
}

fn toUtf8Cases() !void {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    var cps: [97]u16 = undefined;
    var text: [256]u16 = undefined;
    // Every code point, 97 at a time, after 0 to 66 others of each length,
    // so each falls at every lane of a block and of a pair of blocks.
    var next: u32 = 0;
    var k: usize = 0;
    while (next < 0x10000) : (k += 1) {
        for (&cps) |*u| {
            if (next == 0xD800) next = 0xE000;
            u.* = @intCast(next % 0x10000);
            next += 1;
        }
        const src = bmpText(r, &text, k % 67, @intCast(k % 7), &cps);
        try expectToUtf8(src, 3 * src.len);
        try expectToUtf8(src, r.uintAtMost(usize, 3 * src.len));
    }
    // Text of each mix at every length to 200, into every room around the
    // exact size and a random one, so each stop lands in every lane.
    for (0..7) |kind| {
        for (0..200) |n| {
            const src = bmpText(r, &text, n, @intCast(kind), &.{});
            var need: usize = 0;
            for (src) |u| need += if (u < 0x80) 1 else if (u < 0x800) @as(usize, 2) else 3;
            for (need -| 70..need + 1) |size| try expectToUtf8(src, size);
            try expectToUtf8(src, r.uintAtMost(usize, need));
        }
    }
    // U+0000 at every lane, where AVX-512 keeps a byte for being nonzero.
    for (0..7) |kind| {
        for (0..70) |at| {
            const src = bmpText(r, &text, 70, @intCast(kind), &.{});
            src[at] = 0;
            try expectToUtf8(src, 3 * src.len);
            try utf8NulCase(src);
        }
    }
    // Surrogates come out as three bytes each, in a block and alone.
    for ([_]u16{ 0xD800, 0xDBFF, 0xDC00, 0xDFFF }) |s| {
        for (0..40) |at| {
            const src = bmpText(r, &text, 40, 0, &.{});
            src[at] = s;
            try expectToUtf8(src, 3 * src.len);
        }
    }
}

/// `utf8ToBmp` on `text`, which holds a U+0000, as UTF-8.
fn utf8NulCase(text: []const u16) !void {
    var buf: [1024]u8 = undefined;
    const src = utf8Of(text, &buf);
    try expectFromUtf8(src, src.len);
}

/// `text` as UTF-8 in `buf`.
fn utf8Of(text: []const u16, buf: []u8) []u8 {
    return buf[0..scalar.validUtf16ToUtf8(native, text, buf)];
}

test "utf8ToBmp reads every BMP code point at every window offset, as many as fit" {
    try dispatch.forEachLevel(fromUtf8Cases, .{});
}

fn fromUtf8Cases() !void {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    var cps: [97]u16 = undefined;
    var text: [256]u16 = undefined;
    var buf: [1024]u8 = undefined;
    var next: u32 = 0;
    var k: usize = 0;
    while (next < 0x10000) : (k += 1) {
        for (&cps) |*u| {
            if (next == 0xD800) next = 0xE000;
            u.* = @intCast(next % 0x10000);
            next += 1;
        }
        const src = utf8Of(bmpText(r, &text, k % 67, @intCast(k % 7), &cps), &buf);
        try expectFromUtf8(src, src.len);
        try expectFromUtf8(src, r.uintAtMost(usize, src.len));
    }
    // Text of each mix at every length to 200 bytes or so, into every room
    // up to the units it needs, so a short room falls in every lane of a
    // window and the input ends at every lane.
    for (0..7) |kind| {
        for (0..140) |n| {
            const src = utf8Of(bmpText(r, &text, n, @intCast(kind), &.{}), &buf);
            for (0..n + 1) |size| try expectFromUtf8(src, size);
        }
    }
}

test "utf8ToBmp stops at every two- and three-byte sequence it does not take, wherever it is" {
    try dispatch.forEachLevel(stopCases, .{});
}

/// Every lead from 0x80 and every second byte, and for E0 to F4 a grid of
/// third (and fourth) bytes, after text of each length that puts them at
/// each lane around the first and second window boundaries (32 and 64 bytes
/// on SSE and AVX2, 64 and 128 on AVX-512) and the end of the input.
fn stopCases() !void {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    var text: [256]u16 = undefined;
    var fill: [512]u8 = undefined;
    var buf: [1024]u8 = undefined;
    const thirds = [_]u8{ 0x00, 0x41, 0x7F, 0x80, 0x9F, 0xA0, 0xBF, 0xC0, 0xE0, 0xFF };
    const offsets = [_]usize{
        0,  1,  2,  3,  29, 30, 31,  32,  33,  34,  35,  61,
        62, 63, 64, 65, 66, 67, 125, 126, 127, 128, 129, 130,
    };
    for (offsets, 0..) |at, j| {
        // `at` bytes of text of one length, padded with ASCII to land the
        // sequence at byte `at`, then the sequence, then text again.
        const before = utf8Of(bmpText(r, &text, at, @intCast(j % 7), &.{}), &fill);
        var head: usize = 0;
        while (head < before.len) {
            const len = std.unicode.utf8ByteSequenceLength(before[head]) catch unreachable;
            if (head + len > at) break;
            head += len;
        }
        @memcpy(buf[0..head], before[0..head]);
        @memset(buf[head..at], 'a');
        const after = utf8Of(bmpText(r, &text, 40, @intCast((j + 1) % 7), &.{}), fill[256..]);
        var lead: u16 = 0x80;
        while (lead <= 0xFF) : (lead += 1) {
            var second: u16 = 0;
            while (second <= 0xFF) : (second += 1) {
                buf[at] = @intCast(lead);
                buf[at + 1] = @intCast(second);
                const cont = second >= 0x80 and second <= 0xBF;
                const tails: []const u8 = if (lead >= 0xE0 and lead <= 0xF4 and cont) &thirds else thirds[3..4];
                for (tails) |third| {
                    buf[at + 2] = third;
                    buf[at + 3] = 0x80;
                    @memcpy(buf[at + 4 ..][0..after.len], after);
                    const n = at + 4 + after.len;
                    try expectFromUtf8(buf[0..n], n);
                    // The input ending inside the sequence and just after.
                    if (second % 64 == 0x80 % 64) for (at + 1..at + 4) |end| try expectFromUtf8(buf[0..end], end);
                }
            }
        }
    }
}

test "utf8ToBmp stops at every error kind and four-byte character at every position" {
    try dispatch.forEachLevel(errorCases, .{});
}

fn errorCases() !void {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    var text: [256]u16 = undefined;
    var clean: [1024]u8 = undefined;
    var buf: [1024]u8 = undefined;
    const patterns = [_][]const u8{
        "\x80",             "\xbf",         "\xf8",             "\xff",
        "\xc0\x80",         "\xc1\xbf",     "\xe0\x80\x80",     "\xe0\x9f\xbf",
        "\xed\xa0\x80",     "\xed\xbf\xbf", "\xf0\x9f\x98\x80", "\xf4\x8f\xbf\xbf",
        "\xf4\x90\x80\x80", "\xc2A",        "\xe2\x82A",        "\xe2\x82",
        "\xc2",
    };
    for (0..7) |kind| {
        const src = utf8Of(bmpText(r, &text, 150, @intCast(kind), &.{}), &clean);
        for (0..src.len) |i| for (patterns) |p| {
            @memcpy(buf[0..src.len], src);
            const n = @min(p.len, src.len - i);
            @memcpy(buf[i..][0..n], p[0..n]);
            try expectFromUtf8(buf[0..src.len], src.len);
            try expectFromUtf8(buf[0..src.len], r.uintAtMost(usize, src.len));
        };
    }
}
