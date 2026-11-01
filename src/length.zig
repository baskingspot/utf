//! How many code units each conversion writes, and how many code points an
//! input holds. Each function is defined on any input, valid or not, and
//! returns exactly what its counterpart in `scalar_convert.zig` returns; on
//! valid input that is simdutf's answer. An output buffer of the size a
//! length function gives always fits the matching checked conversion, even
//! when the input turns out to be invalid.

const std = @import("std");
const Endian = std.builtin.Endian;
const scalar = @import("scalar_convert.zig");
const simd = @import("simd.zig");
const dispatch = @import("dispatch.zig");
const builtin = @import("builtin");

const native = builtin.cpu.arch.endian();

/// With AVX-512, a comparison gives a mask register, so a block's count is
/// a popcount: one shuffle-port operation per 64 bytes, where widening the
/// mask to a vector to add it up takes two.
const k_masks = simd.isa == .avx512;

/// Code points in UTF-8: the bytes that are not continuation bytes.
pub fn countUtf8(src: []const u8) usize {
    return dispatch.call(@src(), countUtf8Kernel, .{src});
}
fn countUtf8Kernel(src: []const u8) usize {
    if (k_masks) return popBlocks(u8, struct {
        fn f(v: simd.Block(u8), live: u64) usize {
            return @as(usize, @popCount(simd.bitmask(notContinuation(v)) & live));
        }
    }.f, src);
    const sum, const p = sumBlocks(u8, 1, 0, struct {
        fn f(v: anytype) @TypeOf(v) {
            return ones(u8, notContinuation(v));
        }
    }.f, src);
    return sum + scalar.countUtf8(src[p..]);
}

/// Code points in UTF-16LE: the code units that are not low surrogates.
pub fn countUtf16le(src: []const u16) usize {
    return dispatch.call(@src(), countUtf16leKernel, .{src});
}
fn countUtf16leKernel(src: []const u16) usize {
    return countUtf16(.little, src);
}

/// Code points in UTF-16BE: the code units that are not low surrogates.
pub fn countUtf16be(src: []const u16) usize {
    return dispatch.call(@src(), countUtf16beKernel, .{src});
}
fn countUtf16beKernel(src: []const u16) usize {
    return countUtf16(.big, src);
}

/// UTF-16 code units for UTF-8: one per character, two per four-byte one.
pub fn utf16FromUtf8(src: []const u8) usize {
    return dispatch.call(@src(), utf16FromUtf8Kernel, .{src});
}
fn utf16FromUtf8Kernel(src: []const u8) usize {
    if (k_masks) return popBlocks(u8, struct {
        fn f(v: simd.Block(u8), live: u64) usize {
            return @as(usize, @popCount(simd.bitmask(notContinuation(v)) & live)) +
                @popCount(simd.bitmask(v >= @as(@TypeOf(v), @splat(0xF0))) & live);
        }
    }.f, src);
    const sum, const p = sumBlocks(u8, 2, 0, struct {
        fn f(v: anytype) @TypeOf(v) {
            return ones(u8, notContinuation(v)) + ones(u8, v >= @as(@TypeOf(v), @splat(0xF0)));
        }
    }.f, src);
    return sum + scalar.utf16FromUtf8(src[p..]);
}

/// UTF-16 code units for UTF-32: one per code point, two above U+FFFF.
pub fn utf16FromUtf32(src: []const u32) usize {
    return dispatch.call(@src(), utf16FromUtf32Kernel, .{src});
}
fn utf16FromUtf32Kernel(src: []const u32) usize {
    if (k_masks) return src.len + popBlocks(u32, struct {
        fn f(v: simd.Block(u32), live: u16) usize {
            return @as(usize, @popCount(simd.bitmask(v > @as(@TypeOf(v), @splat(0xFFFF))) & live));
        }
    }.f, src);
    const sum, const p = sumBlocks(u32, 1, 0, struct {
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
    return dispatch.call(@src(), utf32FromUtf8Kernel, .{src});
}
fn utf32FromUtf8Kernel(src: []const u8) usize {
    return countUtf8Kernel(src);
}

/// UTF-32 code units for UTF-16LE: one per code point.
pub fn utf32FromUtf16le(src: []const u16) usize {
    return dispatch.call(@src(), utf32FromUtf16leKernel, .{src});
}
fn utf32FromUtf16leKernel(src: []const u16) usize {
    return countUtf16(.little, src);
}

/// UTF-32 code units for UTF-16BE: one per code point.
pub fn utf32FromUtf16be(src: []const u16) usize {
    return dispatch.call(@src(), utf32FromUtf16beKernel, .{src});
}
fn utf32FromUtf16beKernel(src: []const u16) usize {
    return countUtf16(.big, src);
}

/// UTF-32 code units for Latin-1: one per byte.
pub fn utf32FromLatin1(src: []const u8) usize {
    return src.len;
}

/// UTF-8 bytes for UTF-16LE: a surrogate counts two, so a pair counts four.
pub fn utf8FromUtf16le(src: []const u16) usize {
    return dispatch.call(@src(), utf8FromUtf16leKernel, .{src});
}
fn utf8FromUtf16leKernel(src: []const u16) usize {
    return utf8FromUtf16(.little, src);
}

/// UTF-8 bytes for UTF-16BE: a surrogate counts two, so a pair counts four.
pub fn utf8FromUtf16be(src: []const u16) usize {
    return dispatch.call(@src(), utf8FromUtf16beKernel, .{src});
}
fn utf8FromUtf16beKernel(src: []const u16) usize {
    return utf8FromUtf16(.big, src);
}

/// UTF-8 bytes for UTF-32: one to four per code point.
pub fn utf8FromUtf32(src: []const u32) usize {
    return dispatch.call(@src(), utf8FromUtf32Kernel, .{src});
}
fn utf8FromUtf32Kernel(src: []const u32) usize {
    if (k_masks) return src.len + popBlocks(u32, struct {
        fn f(v: simd.Block(u32), live: u16) usize {
            const V = @TypeOf(v);
            return @as(usize, @popCount(simd.bitmask(v >= @as(V, @splat(0x80))) & live)) +
                @popCount(simd.bitmask(v >= @as(V, @splat(0x800))) & live) +
                @popCount(simd.bitmask(v >= @as(V, @splat(0x10000))) & live);
        }
    }.f, src);
    const sum, const p = sumBlocks(u32, 4, 4, struct {
        fn f(v: anytype) @TypeOf(v) {
            const V = @TypeOf(v);
            const S = @Vector(@typeInfo(V).vector.len, i32);
            // Four, less one below each of U+0080, U+0800, and U+10000,
            // each in one signed compare, where an unsigned one takes two
            // without AVX-512, both on the two ports compares share; a
            // value at or above 2^31, below all three as signed, counts
            // four.
            const c: S = @bitCast(v);
            const below = mask(u32, c < @as(S, @splat(0x80))) +% mask(u32, c < @as(S, @splat(0x800))) +%
                mask(u32, c < @as(S, @splat(0x10000)));
            return below & ~@as(V, @bitCast(c >> @splat(31)));
        }
    }.f, src);
    return sum + scalar.utf8FromUtf32(src[p..]);
}

/// UTF-8 bytes for Latin-1: one per byte below 0x80, two above.
pub fn utf8FromLatin1(src: []const u8) usize {
    return dispatch.call(@src(), utf8FromLatin1Kernel, .{src});
}
fn utf8FromLatin1Kernel(src: []const u8) usize {
    if (k_masks) return src.len + popBlocks(u8, struct {
        fn f(v: simd.Block(u8), live: u64) usize {
            return @as(usize, @popCount(simd.bitmask(v >= @as(@TypeOf(v), @splat(0x80))) & live));
        }
    }.f, src);
    const sum, const p = sumBlocks(u8, 1, 0, struct {
        fn f(v: anytype) @TypeOf(v) {
            return ones(u8, v >= @as(@TypeOf(v), @splat(0x80)));
        }
    }.f, src);
    return p + sum + scalar.utf8FromLatin1(src[p..]);
}

/// Latin-1 bytes for UTF-8: one per character.
pub fn latin1FromUtf8(src: []const u8) usize {
    return dispatch.call(@src(), latin1FromUtf8Kernel, .{src});
}
fn latin1FromUtf8Kernel(src: []const u8) usize {
    return countUtf8Kernel(src);
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
    if (k_masks) return src.len - popBlocks(u16, struct {
        fn f(v: simd.Block(u16), live: u32) usize {
            const V = @TypeOf(v);
            const lows = swap(e, v) & @as(V, @splat(0xFC00)) == @as(V, @splat(0xDC00));
            return @as(usize, @popCount(simd.bitmask(lows) & live));
        }
    }.f, src);
    const lows, const p = sumBlocks(u16, 1, 0, struct {
        fn f(v: anytype) @TypeOf(v) {
            const V = @TypeOf(v);
            return ones(u16, swap(e, v) & @as(V, @splat(0xFC00)) == @as(V, @splat(0xDC00)));
        }
    }.f, src);
    return p - lows + scalar.countUtf16(e, src[p..]);
}

fn utf8FromUtf16(comptime e: Endian, src: []const u16) usize {
    if (k_masks) return src.len + popBlocks(u16, struct {
        fn f(raw: simd.Block(u16), live: u32) usize {
            const V = @TypeOf(raw);
            const v = swap(e, raw);
            return @as(usize, @popCount(simd.bitmask(v >= @as(V, @splat(0x80))) & live)) +
                @popCount(simd.bitmask(v >= @as(V, @splat(0x800))) & live) -
                @popCount(simd.bitmask(v & @as(V, @splat(0xF800)) == @as(V, @splat(0xD800))) & live);
        }
    }.f, src);
    const sum, const p = sumBlocks(u16, 3, 3, struct {
        fn f(v: anytype) @TypeOf(v) {
            const V = @TypeOf(v);
            // Three, less one below U+0800, one more below U+0080, and
            // one for a surrogate: each compare's all-ones lane added, with
            // the three added once per run of blocks. Without AVX-512 an
            // unsigned compare takes two operations, and turning it into
            // a one a third (westmere 0.83-0.88 of simdutf). Each is a
            // masked equality, so the other byte order swaps the
            // constants, not the units.
            const c = struct {
                fn f(x: u16) V {
                    return @splat(if (e == native) x else @byteSwap(x));
                }
            }.f;
            const high = v & c(0xF800);
            return mask(u16, v & c(0xFF80) == c(0)) +% mask(u16, high == c(0)) +% mask(u16, high == c(0xD800));
        }
    }.f, src);
    return sum + scalar.utf8FromUtf16(e, src[p..]);
}

/// The LLVM intrinsics below resolve only under the LLVM backend.
const llvm = builtin.zig_backend == .stage2_llvm;

extern fn @"llvm.aarch64.neon.uaddlv.i32.v16i8"(@Vector(16, u8)) u32;
extern fn @"llvm.aarch64.neon.uaddlv.i32.v8i8"(@Vector(8, u8)) u32;

/// Lanes that hold a byte other than a UTF-8 continuation byte.
inline fn notContinuation(v: anytype) @Vector(@typeInfo(@TypeOf(v)).vector.len, bool) {
    const S = @Vector(@typeInfo(@TypeOf(v)).vector.len, i8);
    return @as(S, @bitCast(v)) >= @as(S, @splat(-64));
}

inline fn ones(comptime T: type, b: anytype) @Vector(@typeInfo(@TypeOf(b)).vector.len, T) {
    const V = @Vector(@typeInfo(@TypeOf(b)).vector.len, T);
    return @select(T, b, @as(V, @splat(1)), @as(V, @splat(0)));
}

/// All ones in each lane `b` sets: added, it subtracts one.
inline fn mask(comptime T: type, b: anytype) @Vector(@typeInfo(@TypeOf(b)).vector.len, T) {
    const V = @Vector(@typeInfo(@TypeOf(b)).vector.len, T);
    return @select(T, b, @as(V, @splat(~@as(T, 0))), @as(V, @splat(0)));
}

inline fn swap(comptime e: Endian, v: anytype) @TypeOf(v) {
    return if (e == native) v else @byteSwap(v);
}

/// The units of `src` before the first `size`-byte boundary, 0 if it
/// starts on one. The units must be naturally aligned, as slices of them are.
inline fn alignHead(comptime T: type, comptime size: usize, src: []const T) usize {
    const addr = @intFromPtr(src.ptr);
    return (std.mem.alignForward(usize, addr, size) - addr) / @sizeOf(T);
}

/// Sums `f(block, live)` over the 64-byte blocks of `src`: `live` has a
/// bit for each lane of the block to count. The last partial block is the
/// whole one that ends with `src`, with the lanes already counted left out
/// of `live`; an input shorter than a block is one masked load
/// (`simd.loadShort`), where 16-byte vectors and the scalar code took
/// 0.8-2.2 ns more at 16 bytes (docs/slop/results/calls-20261031.md).
inline fn popBlocks(comptime T: type, comptime f: anytype, src: []const T) usize {
    const lanes = simd.block_len / @sizeOf(T);
    const M = @Int(.unsigned, lanes);
    if (src.len <= lanes) {
        // The zero padding counts only for `countUtf8`'s kind of `f`, so
        // only there does `live` need its own mask.
        const pad_counts = comptime f(@as(simd.Block(T), @splat(0)), ~@as(M, 0)) != 0;
        return f(simd.loadShort(T, src), if (pad_counts) simd.lowBits(M, src.len) else ~@as(M, 0));
    }
    var sum: usize = 0;
    var p: usize = 0;
    // From the second block on, loads are aligned: a load that crosses a
    // cache line costs two, which shows once the input is out of L1.
    if (src.len >= 2 * lanes) {
        p = alignHead(T, simd.block_len, src);
        if (p > 0) sum += f(simd.load(T, src), ~(~@as(M, 0) << @intCast(p)));
    }
    while (src.len - p >= lanes) : (p += lanes) sum += f(simd.load(T, src[p..]), ~@as(M, 0));
    if (p < src.len) sum += f(simd.load(T, src[src.len - lanes ..]), ~@as(M, 0) << @intCast(lanes - (src.len - p)));
    return sum;
}

/// Sums `base + f`, at most `max` per lane, over `src`: in 64-byte vectors,
/// or in 16-byte ones when `src` is shorter than 64 bytes, and on NEON
/// without a loop up to two 64-byte vectors' worth. `f`'s lanes may
/// wrap: `base` is added once per run of blocks, not once per block. Returns the sum and the
/// number of code units it covers, all of `src` unless it is shorter than 16
/// bytes.
inline fn sumBlocks(
    comptime T: type,
    comptime max: comptime_int,
    comptime base: comptime_int,
    comptime f: anytype,
    src: []const T,
) struct { usize, usize } {
    if (src.len >= 64 / @sizeOf(T)) {
        if (fold and src.len <= 128 / @sizeOf(T))
            return .{ sumChunks(T, 64 / @sizeOf(T), 2, max, base, f, src), src.len };
        return sumVectors(T, 64 / @sizeOf(T), max, base, f, src);
    }
    if (src.len >= 16 / @sizeOf(T)) {
        if (fold) return .{ sumChunks(T, 16 / @sizeOf(T), 4, max, base, f, src), src.len };
        return sumVectors(T, 16 / @sizeOf(T), max, base, f, src);
    }
    return .{ 0, 0 };
}

/// On NEON, sums keep their lanes in one accumulator to the end: the head
/// and the last vector join the run they border, and the lanes are summed
/// once, in lanes twice as wide (`uaddlv` and widening adds). Summed alone,
/// LLVM turned each masked vector into a lane mask and a popcount, and
/// 8-bit lanes summed in 64 bits took 60 instructions, which a 64-byte
/// input paid in full. Inputs up to two vectors' worth take `sumChunks`.
const fold = simd.isa == .neon;

/// `sumBlocks` for `src` of `n` to `k * n` units, without a loop: the
/// first `n` units, then up to `k - 1` vectors more, from each multiple of
/// `n` short of the end or else the last `n` units, masked to the lanes no
/// earlier vector counted. In `sumVectors` one block and a partial one
/// cost five branches and a loop's setup; with all `k` vectors loaded
/// every time and no branches, the 16-byte rows lost 12-38%.
inline fn sumChunks(
    comptime T: type,
    comptime n: usize,
    comptime k: usize,
    comptime max: comptime_int,
    comptime base: comptime_int,
    comptime f: anytype,
    src: []const T,
) usize {
    const V = @Vector(n, T);
    const A = @typeInfo(@TypeOf(f(@as(V, @splat(0))))).vector.child;
    const W = @Vector(n, A);
    var acc: W = @as(W, @splat(base)) +% f(@as(V, src[0..n].*));
    inline for (1..k) |i| {
        if (src.len > i * n) {
            const fresh = lastLanes(W, @min(src.len - i * n, n));
            acc +%= (@as(W, @splat(base)) +% f(@as(V, src[@min(i * n, src.len - n)..][0..n].*))) & fresh;
        }
    }
    return sumLanes(acc, k * max);
}

/// The sum of `acc`'s lanes, each at most `bound`: its halves added while
/// the lanes hold the sums and the vector is wider than a register, then
/// the lanes summed in lanes twice as wide.
inline fn sumLanes(acc: anytype, comptime bound: comptime_int) usize {
    const len = @typeInfo(@TypeOf(acc)).vector.len;
    const A = @typeInfo(@TypeOf(acc)).vector.child;
    if (len * @sizeOf(A) > 16 and 2 * bound <= std.math.maxInt(A)) {
        const lo = @shuffle(A, acc, undefined, std.simd.iota(i32, len / 2));
        const upper = std.simd.iota(i32, len / 2) + @as(@Vector(len / 2, i32), @splat(len / 2));
        const hi = @shuffle(A, acc, undefined, upper);
        // Wrapping, as the bound allows: the checked add reported overflow
        // on lanes of 0-2 in aarch64 ReleaseSafe builds, a miscompiled
        // check (the wrapping sums were right).
        return sumLanes(lo +% hi, 2 * bound);
    }
    // One `uaddlv`, where LLVM may widen in pairs first and add after.
    if (llvm and A == u8 and len == 16) return @"llvm.aarch64.neon.uaddlv.i32.v16i8"(acc);
    if (llvm and A == u8 and len == 8) return @"llvm.aarch64.neon.uaddlv.i32.v8i8"(acc);
    return @reduce(.Add, @as(@Vector(len, @Int(.unsigned, 2 * @bitSizeOf(A))), acc));
}

/// A `W` whose last `i` lanes are all ones and the rest zero, from a
/// window of `tail_mask`: one or two loads, where comparing an index took
/// three instructions per 16 bytes.
inline fn lastLanes(comptime W: type, i: usize) W {
    const A = @typeInfo(W).vector.child;
    const bytes = @typeInfo(W).vector.len * @sizeOf(A);
    return @bitCast(@as(*align(1) const [bytes]u8, tail_mask[64 - bytes + i * @sizeOf(A) ..][0..bytes]).*);
}

/// 64 zero bytes, then 64 of all ones.
const tail_mask = [_]u8{0} ** 64 ++ [_]u8{0xFF} ** 64;

/// `sumBlocks` in vectors of `n` units, for `src` at least that long,
/// accumulating in lanes as wide as `T`. The last partial vector is a whole one that ends with
/// `src`, with the lanes already counted masked off.
inline fn sumVectors(
    comptime T: type,
    comptime n: usize,
    comptime max: comptime_int,
    comptime base: comptime_int,
    comptime f: anytype,
    src: []const T,
) struct { usize, usize } {
    const V = @Vector(n, T);
    const A = @typeInfo(@TypeOf(f(@as(V, @splat(0))))).vector.child;
    const W = @Vector(n, A);
    // 16-bit lanes sum in 32 bits, which takes half the widening.
    const S = @Vector(n, if (fold) @Int(.unsigned, 2 * @bitSizeOf(A)) else if (A == u16) u32 else u64);
    var sum: usize = 0;
    var p: usize = 0;
    var acc: W = @splat(0);
    // Aligned loads from the second vector on, as in `popBlocks`, once
    // the input is long enough to pay for the extra sum (from 16 vectors:
    // at 256 bytes the head cost AVX2 20-35%).
    if (src.len >= 16 * n) {
        p = alignHead(T, n * @sizeOf(T), src);
        if (p > 0) {
            const head = std.simd.iota(A, n) < @as(W, @splat(@intCast(p)));
            const first = @select(A, head, @as(W, @splat(base)) +% f(@as(V, src[0..n].*)), @as(W, @splat(0)));
            if (fold) acc = first else sum += @reduce(.Add, @as(S, first));
        }
    }
    while (src.len - p >= n) {
        // usize, where `@min` would narrow it and `base * blocks` with it.
        // Folding leaves room for the head and the last vector.
        const blocks: usize = @min((src.len - p) / n, std.math.maxInt(A) / max - if (fold) 2 else 0);
        for (0..blocks) |_| {
            acc +%= f(@as(V, src[p..][0..n].*));
            p += n;
        }
        if (base != 0) acc +%= @splat(@intCast(base * blocks));
        if (!fold or src.len - p >= n) {
            sum += @reduce(.Add, @as(S, acc));
            acc = @splat(0);
        }
    }
    if (p < src.len) {
        if (fold) {
            const last = @as(W, @splat(base)) +% f(@as(V, src[src.len - n ..][0..n].*));
            acc +%= last & lastLanes(W, src.len - p);
        } else {
            const fresh = std.simd.iota(A, n) >= @as(W, @splat(@intCast(n - (src.len - p))));
            const last = @as(W, @splat(base)) +% f(@as(V, src[src.len - n ..][0..n].*));
            sum += @reduce(.Add, @as(S, @select(A, fresh, last, @as(W, @splat(0)))));
        }
    }
    if (fold) sum += sumLanes(acc, std.math.maxInt(A));
    return .{ sum, src.len };
}

test "every length function matches the scalar reference on any input" {
    try dispatch.forEachLevel(anyInputCases, .{});
}

fn anyInputCases() !void {
    const testing = std.testing;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    var buf8: [1400]u8 = undefined;
    var buf16: [700]u16 = undefined;
    var buf32: [360]u32 = undefined;
    for (0..2000) |_| {
        // A random start, so the blocks fall at every alignment.
        const n8 = r.uintLessThan(usize, buf8.len - 64);
        const n16 = r.uintLessThan(usize, buf16.len - 32);
        const n32 = r.uintLessThan(usize, buf32.len - 16);
        const at8 = r.uintLessThan(usize, 64);
        const at16 = r.uintLessThan(usize, 32);
        const at32 = r.uintLessThan(usize, 16);
        // Bytes and units of every class, surrogates and invalid values
        // included, most of the time ASCII so the blocks vary.
        for (buf8[at8..][0..n8]) |*b| b.* = if (r.boolean()) r.uintLessThan(u8, 0x80) else r.int(u8);
        for (buf16[at16..][0..n16]) |*u| u.* = switch (r.uintLessThan(u8, 4)) {
            0 => r.uintLessThan(u16, 0x80),
            1 => 0xD800 + r.uintLessThan(u16, 0x800),
            else => r.int(u16),
        };
        for (buf32[at32..][0..n32]) |*u| u.* = switch (r.uintLessThan(u8, 4)) {
            0 => r.uintLessThan(u32, 0x80),
            1 => r.uintLessThan(u32, 0x110000),
            else => r.int(u32) >> r.int(u5),
        };
        const s8 = buf8[at8..][0..n8];
        const s16 = buf16[at16..][0..n16];
        const s32 = buf32[at32..][0..n32];
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
    try dispatch.forEachLevel(overflowCases, .{});
}

fn overflowCases() !void {
    const testing = std.testing;
    // Every byte and unit counts the most it can, for more blocks than one
    // accumulator holds.
    const leads = [_]u8{0xF4} ** (64 * 300 + 5);
    try testing.expectEqual(leads.len, countUtf8(&leads));
    try testing.expectEqual(2 * leads.len, utf16FromUtf8(&leads));
    try testing.expectEqual(2 * leads.len, utf8FromLatin1(&leads));
    // U+0808 reads the same in either byte order.
    const units = [_]u16{0x0808} ** (32 * 100 + 3);
    try testing.expectEqual(3 * units.len, utf8FromUtf16le(&units));
    try testing.expectEqual(3 * units.len, utf8FromUtf16be(&units));
    // So does U+DCDC, a low surrogate.
    const lows = [_]u16{0xDCDC} ** (32 * 300 + 5);
    try testing.expectEqual(0, countUtf16le(&lows));
    try testing.expectEqual(0, countUtf16be(&lows));
    try testing.expectEqual(2 * lows.len, utf8FromUtf16be(&lows));
    // Past the 21845 blocks of 32 units one 16-bit accumulator holds at
    // three a lane.
    const many = try testing.allocator.alloc(u16, 32 * 21845 + 35);
    defer testing.allocator.free(many);
    @memset(many, 0x0808);
    try testing.expectEqual(3 * many.len, utf8FromUtf16le(many));
    const cps = [_]u32{0x10000} ** (16 * 100 + 7);
    try testing.expectEqual(4 * cps.len, utf8FromUtf32(&cps));
    try testing.expectEqual(2 * cps.len, utf16FromUtf32(&cps));
}
