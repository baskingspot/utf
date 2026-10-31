//! Base64 encoding and decoding with SIMD, after Muła and Lemire, "Faster
//! Base64 Encoding and Decoding Using AVX2 Instructions" (2018). Each step
//! of the main loops turns 48 bytes into 64 characters or back. Decoding
//! skips ASCII whitespace as WHATWG's forgiving-base64 does: a block with
//! whitespace has it compressed out into a staging buffer, which is decoded
//! once it holds 64 characters. The scalar reference in `scalar_base64.zig`
//! handles what the loops leave, and every path here returns exactly what it
//! returns.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const simd = @import("simd.zig");
const result = @import("result.zig");
const Result = result.Result;

pub const scalar = @import("scalar_base64.zig");
pub const Alphabet = scalar.Alphabet;
pub const LastChunk = scalar.LastChunk;
pub const EncodeOptions = scalar.EncodeOptions;
pub const DecodeOptions = scalar.DecodeOptions;
pub const encodedLen = scalar.encodedLen;
pub const maxDecodedLen = scalar.maxDecodedLen;

/// Encodes `src` into `dst` and returns the number of characters written,
/// `encodedLen(src.len, options)`. `dst` must hold that many.
pub fn encode(dst: []u8, src: []const u8, options: EncodeOptions) usize {
    return switch (options.alphabet) {
        inline else => |a| encodeWith(native, a, dst, src, options.padding),
    };
}

/// Decodes base64 `src` into `dst`, skipping ASCII whitespace (tab, LF, FF,
/// CR, and space), with padding optional unless `options.last_chunk` is
/// `.strict`.
///
/// On success `count` is the number of bytes written. On failure it is a
/// position in `src`: for `invalid_base64_character`, the offending
/// character, which includes a misplaced `=`; for `base64_input_remainder`
/// and `base64_extra_bits`, the end of the encoded data; for
/// `output_buffer_too_small`, the first character of the chunk that does not
/// fit, where decoding can resume with more room. A `dst` of
/// `maxDecodedLen(src.len)` bytes always fits. On failure the contents of
/// `dst` are unspecified.
pub fn decode(dst: []u8, src: []const u8, options: DecodeOptions) Result {
    return switch (options.alphabet) {
        inline else => |a| decodeWith(native, a, dst, src, options.last_chunk),
    };
}

/// The instruction sets with a kernel here. `generic` is plain `@Vector`
/// code for any target; the others call LLVM intrinsics for byte lookups and
/// multiply-adds, so they need the LLVM backend.
pub const Isa = enum {
    generic,
    ssse3,
    avx2,
    neon,

    /// Whether this build can run the kernel.
    pub fn supported(isa: Isa) bool {
        const llvm = builtin.zig_backend == .stage2_llvm;
        const cpu = builtin.cpu;
        return switch (isa) {
            .generic => true,
            .ssse3 => llvm and cpu.arch == .x86_64 and cpu.has(.x86, .ssse3),
            .avx2 => llvm and cpu.arch == .x86_64 and cpu.has(.x86, .avx2),
            .neon => llvm and cpu.arch.isAARCH64() and cpu.has(.aarch64, .neon),
        };
    }
};

/// The kernel `encode` and `decode` use: the widest the target supports.
pub const native: Isa = for ([_]Isa{ .avx2, .ssse3, .neon }) |isa| {
    if (isa.supported()) break isa;
} else .generic;

pub fn encodeWith(comptime isa: Isa, comptime alphabet: Alphabet, dst: []u8, src: []const u8, padding: bool) usize {
    const options: EncodeOptions = .{ .alphabet = alphabet, .padding = padding };
    std.debug.assert(dst.len >= encodedLen(src.len, options));
    const K = Kernel(isa, alphabet);
    const K16 = Kernel(if (isa == .avx2) .ssse3 else isa, alphabet);
    const n = K.lanes;
    const bytes = n / 4 * 3;
    var i: usize = 0;
    var o: usize = 0;
    // The wide kernel reads from `K.skip` bytes before its input, so the
    // first 12 bytes go through the narrow one.
    if (K.skip > 0 and src.len >= 16) {
        dst[0..16].* = K16.encode(src[0..16]);
        i = 12;
        o = 16;
    }
    // Each vector reads `n` bytes and encodes `bytes` of them.
    while (src.len - i >= 48 - bytes + n - K.skip) : ({
        i += 48;
        o += 64;
    }) {
        inline for (0..64 / n) |k| {
            dst[o + k * n ..][0..n].* = K.encode(src[i - K.skip + k * bytes ..][0..n]);
        }
    }
    while (src.len - i >= 16) : ({
        i += 12;
        o += 16;
    }) {
        dst[o..][0..16].* = K16.encode(src[i..][0..16]);
    }
    return o + scalar.encode(dst[o..], src[i..], options);
}

pub fn decodeWith(
    comptime isa: Isa,
    comptime alphabet: Alphabet,
    dst: []u8,
    src: []const u8,
    last_chunk: LastChunk,
) Result {
    const options: DecodeOptions = .{ .alphabet = alphabet, .last_chunk = last_chunk };
    const K = Kernel(isa, alphabet);
    const t = scalar.trim(src);
    if (t.len < 64) return decodeRest(isa, alphabet, dst, src, t, 0, 0, options);
    var i: usize = 0;
    var o: usize = 0;
    // The 6-bit values of blocks with whitespace, compressed, not yet
    // decoded. They are decoded four blocks at a time, well after they are
    // stored, so loads do not wait on the stores: fewer than 256 between
    // steps, one more block, and 8-byte stores past the end.
    var stage: [336]u8 align(32) = undefined;
    var staged: usize = 0;
    blocks: while (true) {
        // Blocks without whitespace go straight to `dst`.
        while (t.len - i >= 64 and dst.len - o >= 48 + K.slack) : ({
            i += 64;
            o += 48;
        }) {
            const c = K.classifyBlock(src[i..][0..64]);
            if (c.anyBad()) break;
            K.packBlock(c.values, dst[o..][0 .. 48 + K.slack]);
        }
        // From the first with whitespace, all go through `stage`.
        while (t.len - i >= 64 and dst.len - o >= 48 * (staged / 64 + 1) + K.slack) {
            const block = src[i..][0..64];
            const c = K.classifyBlock(block);
            if (!c.anyBad()) {
                stage[staged..][0..64].* = @bitCast(c.values);
            } else {
                const space = K.spaceMask(block);
                if (c.badMask() & ~space != 0) break :blocks;
                K.compress(c.values, space, stage[staged..][0..72]);
            }
            staged += 64 - @popCount(c.badMask());
            i += 64;
            if (staged >= 256) {
                var done: usize = 0;
                while (staged - done >= 64) : (done += 64) {
                    K.packBlock(@bitCast(stage[done..][0..64].*), dst[o..][0 .. 48 + K.slack]);
                    o += 48;
                }
                stage[0..64].* = stage[done..][0..64].*;
                staged -= done;
                if (staged == 0) continue :blocks;
            }
        }
        break;
    }

    if (staged == 0) return decodeRest(isa, alphabet, dst, src, t, i, o, options);

    // Decode the staged blocks and whole chunks that fit, then hand the
    // scalar decoder the input from the first character still undecoded.
    var done: usize = 0;
    while (staged - done >= 64 and dst.len - o >= 48 + K.slack) : (done += 64) {
        K.packBlock(@bitCast(stage[done..][0..64].*), dst[o..][0 .. 48 + K.slack]);
        o += 48;
    }
    const whole = (staged - done) / 4 * 4;
    if (dst.len - o >= whole / 4 * 3) {
        for (0..whole / 4) |_| {
            const v = stage[done..][0..4];
            const w = @as(u32, v[0]) << 18 | @as(u32, v[1]) << 12 | @as(u32, v[2]) << 6 | v[3];
            dst[o..][0..3].* = .{ @truncate(w >> 16), @truncate(w >> 8), @truncate(w) };
            o += 3;
            done += 4;
        }
    }
    var start = i;
    var keep = staged - done;
    while (keep > 0) {
        start -= 1;
        if (!scalar.isSpace(src[start])) keep -= 1;
    }
    return scalar.decodeFrom(dst, src, t, start, o, options);
}

/// Decodes `src[i..]` into `dst[o..]` sixteen characters at a time while
/// they are all in the alphabet, then hands the scalar decoder the rest.
fn decodeRest(
    comptime isa: Isa,
    comptime alphabet: Alphabet,
    dst: []u8,
    src: []const u8,
    t: scalar.Trim,
    start: usize,
    out: usize,
    options: DecodeOptions,
) Result {
    const K16 = Kernel(if (isa == .avx2) .ssse3 else isa, alphabet);
    var i = start;
    var o = out;
    while (t.len - i >= 16 and dst.len - o >= 12) : ({
        i += 16;
        o += 12;
    }) {
        const c = K16.classify(src[i..][0..16].*);
        if (@reduce(.Or, c.bad)) break;
        dst[o..][0..12].* = @as([16]u8, K16.pack(c.values))[0..12].*;
    }
    return scalar.decodeFrom(dst, src, t, i, o, options);
}

fn Kernel(comptime isa: Isa, comptime alphabet: Alphabet) type {
    if (!isa.supported()) @compileError("this build cannot run the " ++ @tagName(isa) ++ " kernel");
    return struct {
        const lanes = if (isa == .avx2) 32 else 16;
        const V = @Vector(lanes, u8);
        const blocks = 64 / lanes;
        const chars = alphabet.chars();

        inline fn splat(x: u8) V {
            return @splat(x);
        }

        /// How many bytes before its input `encode` reads.
        const skip = if (lanes == 32) 4 else 0;

        /// Encodes `src[skip..][0 .. lanes / 4 * 3]`.
        inline fn encode(src: *const [lanes]u8) [lanes]u8 {
            // Gather each group of three bytes a, b, c into the 32-bit lane
            // b a c b (a b b c on big-endian targets), so that 16-bit lanes
            // hold a:b and b:c. A
            // 32-byte vector starts 4 bytes early, so that each 16-byte lane
            // holds its 12 bytes: Muła and Lemire's trick to shuffle only
            // within lanes.
            // The load is volatile so that LLVM keeps it whole: it would
            // split the vector it does not use all of into three loads.
            const in = @as(*align(1) const volatile V, @ptrCast(src)).*;
            const spread = @shuffle(u8, in, undefined, blk: {
                var m: [lanes]i32 = undefined;
                for (0..lanes / 4) |g| {
                    const base = g / 4 * 16 + g % 4 * 3 + (if (g < 4) skip else 0);
                    m[g * 4 ..][0..4].* = if (big)
                        .{ base, base + 1, base + 1, base + 2 }
                    else
                        .{ base + 1, base, base + 2, base + 1 };
                }
                break :blk m;
            });
            // Pull the four 6-bit indices into the low bits of each byte:
            // a>>2 and the low 6 bits of c with shifts within 16-bit
            // lanes, the two in the middle across them. The shifts are
            // multiplies, as the paper has them: one instruction each on
            // x86, where shifts by lane need two and a blend.
            const W = @Vector(lanes / 2, u16);
            const w: W = @bitCast(spread);
            const t0 = w & rep(W, .{ 0xfc00, 0x0fc0 });
            const t1 = mulhi(t0, rep(W, .{ 0x0040, 0x0400 }));
            const t2 = w & rep(W, .{ 0x03f0, 0x003f });
            const t3 = t2 *% rep(W, .{ 0x0010, 0x0100 });
            // Each 16-bit lane holds two indices, the first in its low byte.
            const idx: V = @bitCast(if (big) @byteSwap(t1 | t3) else t1 | t3);
            return idx +% offsets(idx);
        }

        inline fn mulhi(a: @Vector(lanes / 2, u16), b: @Vector(lanes / 2, u16)) @Vector(lanes / 2, u16) {
            return switch (isa) {
                .ssse3 => @"llvm.x86.sse2.pmulhu.w"(a, b),
                .avx2 => @"llvm.x86.avx2.pmulhu.w"(a, b),
                .generic, .neon => @truncate((@as(@Vector(lanes / 2, u32), a) * b) >> @splat(16)),
            };
        }

        /// What to add to each index to get its character.
        inline fn offsets(idx: V) V {
            const o_lower: u8 = 'a' - 26;
            const o_digit: u8 = @bitCast(@as(i8, '0' - 52));
            const o_62: u8 = chars[62] -% 62;
            const o_63: u8 = chars[63] -% 63;
            if (isa == .generic) {
                const lower = @select(u8, idx < splat(52), splat(o_lower), splat(o_digit));
                const tail = @select(u8, idx == splat(62), splat(o_62), splat(o_63));
                const above = @select(u8, idx < splat(62), lower, tail);
                return @select(u8, idx < splat(26), splat('A'), above);
            }
            // Indices 0..51 become 0, 52..63 become 1..12, and 0..25 then
            // become 13: one table entry per offset.
            const signed: @Vector(lanes, i8) = @bitCast(idx);
            const reduced = @select(u8, signed < @as(@Vector(lanes, i8), @splat(26)), splat(13), idx -| splat(51));
            const table: [16]u8 = .{o_lower} ++ .{o_digit} ** 10 ++ .{ o_62, o_63, 'A', 0, 0 };
            return simd.lookup16(table, reduced);
        }

        const Classified = struct { values: V, bad: @Vector(lanes, bool) };

        /// Each character's 6-bit value, and whether it is outside the
        /// alphabet (whitespace included).
        inline fn classify(in: V) Classified {
            if (isa == .generic) {
                const upper = in -% splat('A') < splat(26);
                const lower = in -% splat('a') < splat(26);
                const digit = in -% splat('0') < splat(10);
                const is62 = in == splat(chars[62]);
                const is63 = in == splat(chars[63]);
                var v = @select(u8, upper, in -% splat('A'), splat(0));
                v = @select(u8, lower, in -% splat('a' - 26), v);
                v = @select(u8, digit, in +% splat(52 - '0'), v);
                v = @select(u8, is62, splat(62), v);
                v = @select(u8, is63, splat(63), v);
                const good = anyTrue(anyTrue(upper, lower), anyTrue(digit, anyTrue(is62, is63)));
                return .{ .values = v, .bad = !good };
            }
            const hi = in >> @splat(4);
            const lo = in & splat(0x0f);
            const bad = simd.lookup16(tables.lo, lo) & simd.lookup16(tables.hi, hi) != splat(0);
            // The character whose offset differs from the rest of its high
            // nibble's takes a slot of its own, above 7.
            const slot = hi | (@select(u8, in == splat(tables.special), splat(8), splat(0)));
            return .{ .values = in +% simd.lookup16(tables.roll, slot), .bad = bad };
        }

        /// Which characters are ASCII whitespace.
        inline fn isSpace(in: V) @Vector(lanes, bool) {
            if (isa == .generic) {
                const ctl = in -% splat('\t') < splat(5);
                return anyTrue(in == splat(' '), bothTrue(ctl, in != splat(0x0b)));
            }
            // Each whitespace character is the only ASCII byte with its low
            // nibble that the table maps to itself; 0x80 matches none, and
            // bytes from 0x80 look up 0.
            const x = 0x80;
            const table: [16]u8 = .{ ' ', x, x, x, x, x, x, x, x, '\t', '\n', x, '\x0c', '\r', x, x };
            return simd.lookup16(table, in & splat(0x8f)) == in;
        }

        const Block = struct {
            values: [blocks]V,
            bad: [blocks]@Vector(lanes, bool),

            inline fn anyBad(b: Block) bool {
                var any = b.bad[0];
                inline for (b.bad[1..]) |x| any = anyTrue(any, x);
                return @reduce(.Or, any);
            }

            /// Bit k is set when character k is outside the alphabet.
            inline fn badMask(b: Block) u64 {
                var m: u64 = 0;
                inline for (b.bad, 0..) |x, k| m |= @as(u64, simd.bitmask(x)) << (k * lanes);
                return m;
            }
        };

        inline fn classifyBlock(src: *const [64]u8) Block {
            var b: Block = undefined;
            const in: [blocks]V = @bitCast(simd.load(u8, src));
            inline for (0..blocks) |k| {
                const c = classify(in[k]);
                b.values[k] = c.values;
                b.bad[k] = c.bad;
            }
            return b;
        }

        /// Turns 64 6-bit values into 48 bytes.
        /// How many bytes past its 48 `packBlock` writes.
        const slack = lanes / 4;

        /// Turns 64 6-bit values into 48 bytes, and writes `slack` more.
        inline fn packBlock(values: [blocks]V, out: *[48 + slack]u8) void {
            // Whole vectors, each overwriting the slack of the one before.
            // The stores are volatile so that LLVM keeps them whole: it
            // would merge them with more shuffles than it saves.
            inline for (0..blocks) |k| {
                const p: *align(1) volatile V = @ptrCast(out[k * lanes / 4 * 3 ..][0..lanes]);
                p.* = pack(values[k]);
            }
        }

        /// Bit k is set when character k is ASCII whitespace.
        inline fn spaceMask(src: *const [64]u8) u64 {
            var m: u64 = 0;
            const in: [blocks]V = @bitCast(simd.load(u8, src));
            inline for (0..blocks) |k| m |= @as(u64, simd.bitmask(isSpace(in[k]))) << (k * lanes);
            return m;
        }

        /// Copies the bytes of `src` not in `space` to the front of `out`. It
        /// may write all of `out`.
        inline fn compress(values: [blocks]V, space: u64, out: *[72]u8) void {
            // Line breaks put one or two whitespace characters in most
            // blocks: remove each by shifting what follows it down a lane,
            // the last first.
            if (@popCount(space) <= 2) {
                var v = values;
                var rest = space;
                while (rest != 0) {
                    const pos: u8 = 63 - @clz(rest);
                    rest &= ~(@as(u64, 1) << @intCast(pos));
                    inline for (0..blocks) |k| {
                        const next = if (k + 1 < blocks) v[k + 1] else v[k];
                        const shifted = @shuffle(u8, v[k], next, blk: {
                            var m: [lanes]i32 = undefined;
                            for (&m, 1..) |*x, j| x.* = if (j < lanes) j else ~@as(i32, 0);
                            break :blk m;
                        });
                        const below = std.simd.iota(u8, lanes) + splat(k * lanes) < splat(pos);
                        v[k] = @select(u8, below, v[k], shifted);
                    }
                }
                out[0..64].* = @bitCast(v);
                return;
            }
            const src: [64]u8 = @bitCast(values);
            var n: usize = 0;
            if (isa == .generic) {
                for (src, 0..) |c, k| {
                    out[n] = c;
                    n += @intFromBool(space >> @intCast(k) & 1 == 0);
                }
                return;
            }
            // Each 16 bytes: one shuffle packs the kept bytes of each half
            // to the front of that half, by a table indexed by the half's
            // keep mask, and two 8-byte stores join the halves.
            inline for (0..4) |k| {
                const keep: u16 = ~@as(u16, @truncate(space >> (k * 16)));
                const lo: u8 = @truncate(keep);
                const hi: u8 = @truncate(keep >> 8);
                const halves = [2]u64{ compress_table[lo], compress_table[hi] + 0x0808080808080808 };
                const idx: @Vector(16, u8) = @bitCast(halves);
                const v: @Vector(16, u8) = src[k * 16 ..][0..16].*;
                const packed_: [16]u8 = simd.lookup16(v, idx);
                out[n..][0..8].* = packed_[0..8].*;
                n += @popCount(lo);
                out[n..][0..8].* = packed_[8..16].*;
                n += @popCount(hi);
            }
        }

        /// Turns 6-bit values into bytes: each four into three, in the
        /// first three quarters of the result.
        inline fn pack(values: V) V {
            const D = @Vector(lanes / 4, u32);
            const w: D = switch (isa) {
                // a*64 + b in 16-bit lanes, then ab*4096 + cd in 32-bit ones.
                .ssse3 => @bitCast(@"llvm.x86.sse2.pmadd.wd"(
                    @"llvm.x86.ssse3.pmadd.ub.sw.128"(values, @bitCast(rep(@Vector(8, u16), .{0x0140}))),
                    @bitCast(rep(@Vector(4, u32), .{0x00011000})),
                )),
                .avx2 => @bitCast(@"llvm.x86.avx2.pmadd.wd"(
                    @"llvm.x86.avx2.pmadd.ub.sw"(values, @bitCast(rep(@Vector(16, u16), .{0x0140}))),
                    @bitCast(rep(@Vector(8, u32), .{0x00011000})),
                )),
                .generic, .neon => blk: {
                    const x: D = @bitCast(values);
                    // The four values are the bytes of x, the first lowest on
                    // little-endian targets and highest on big-endian ones.
                    break :blk if (big)
                        ((x >> @splat(6)) & rep(D, .{0xfc0000})) |
                            ((x >> @splat(4)) & rep(D, .{0x3f000})) |
                            ((x >> @splat(2)) & rep(D, .{0xfc0})) |
                            (x & rep(D, .{0x3f}))
                    else
                        ((x & rep(D, .{0x3f})) << @splat(18)) |
                            ((x & rep(D, .{0x3f00})) << @splat(4)) |
                            ((x >> @splat(10)) & rep(D, .{0xfc0})) |
                            (x >> @splat(24));
                },
            };
            // Each 32-bit lane holds its three bytes in its low 24 bits.
            const bytes: V = @bitCast(w);
            return @shuffle(u8, bytes, undefined, blk: {
                var m: [lanes]i32 = undefined;
                for (0..lanes / 4) |g| m[g * 3 ..][0..3].* = if (big)
                    .{ g * 4 + 1, g * 4 + 2, g * 4 + 3 }
                else
                    .{ g * 4 + 2, g * 4 + 1, g * 4 };
                break :blk m;
            });
        }

        const tables = decodeTables(alphabet);
    };
}

/// Lookup tables for the nibble classification: `lo[c & 15] & hi[c >> 4]`
/// is nonzero exactly for the bytes outside the alphabet, and
/// `c + roll[c >> 4]` is the value of an alphabet character other than
/// `special`, whose offset is at `roll[(special >> 4) | 8]`.
fn decodeTables(comptime alphabet: Alphabet) struct { lo: [16]u8, hi: [16]u8, roll: [16]u8, special: u8 } {
    @setEvalBranchQuota(10000);
    const chars = alphabet.chars();
    const special = chars[63];
    // The set of low nibbles outside the alphabet, for each high nibble;
    // each distinct set gets a bit.
    var invalid: [16]u16 = @splat(0xffff);
    for (chars) |c| invalid[c >> 4] &= ~(@as(u16, 1) << (c & 15));
    var sets: [8]u16 = undefined;
    var n_sets: usize = 0;
    var lo: [16]u8 = @splat(0);
    var hi: [16]u8 = @splat(0);
    for (invalid, 0..) |set, h| {
        if (set == 0) continue;
        const bit = for (sets[0..n_sets], 0..) |s, k| {
            if (s == set) break k;
        } else blk: {
            sets[n_sets] = set;
            n_sets += 1;
            break :blk n_sets - 1;
        };
        hi[h] = 1 << bit;
        for (0..16) |l| {
            if (set >> l & 1 != 0) lo[l] |= 1 << bit;
        }
    }
    var roll: [16]u8 = @splat(0);
    var seen: [16]bool = @splat(false);
    for (chars, 0..) |c, v| {
        const slot = if (c == special) (c >> 4) | 8 else c >> 4;
        const off: u8 = @as(u8, v) -% c;
        if (seen[slot] and roll[slot] != off) @compileError("two offsets for one high nibble");
        roll[slot] = off;
        seen[slot] = true;
    }
    return .{ .lo = lo, .hi = hi, .roll = roll, .special = special };
}

/// For each 8-bit mask, the indices of its set bits in order, a byte each
/// in memory order.
const compress_table: [256]u64 = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]u64 = undefined;
    for (0..256) |mask| {
        var idx: [8]u8 = @splat(0);
        var n: usize = 0;
        for (0..8) |b| {
            if (mask >> b & 1 != 0) {
                idx[n] = b;
                n += 1;
            }
        }
        t[mask] = @bitCast(idx);
    }
    break :blk t;
};

const big = builtin.cpu.arch.endian() == .big;

/// A vector of `pattern` repeated.
inline fn rep(comptime T: type, comptime pattern: anytype) T {
    return comptime blk: {
        const n = @typeInfo(T).vector.len;
        const E = @typeInfo(T).vector.child;
        const p: [pattern.len]E = pattern;
        var a: [n]E = undefined;
        for (&a, 0..) |*x, k| x.* = p[k % p.len];
        break :blk a;
    };
}

inline fn anyTrue(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return @select(bool, a, a, b);
}

inline fn bothTrue(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return @select(bool, a, b, a);
}

extern fn @"llvm.x86.ssse3.pmadd.ub.sw.128"(@Vector(16, u8), @Vector(16, u8)) @Vector(8, i16);
extern fn @"llvm.x86.avx2.pmadd.ub.sw"(@Vector(32, u8), @Vector(32, u8)) @Vector(16, i16);
extern fn @"llvm.x86.sse2.pmadd.wd"(@Vector(8, i16), @Vector(8, i16)) @Vector(4, i32);
extern fn @"llvm.x86.avx2.pmadd.wd"(@Vector(16, i16), @Vector(16, i16)) @Vector(8, i32);
extern fn @"llvm.x86.sse2.pmulhu.w"(@Vector(8, u16), @Vector(8, u16)) @Vector(8, u16);
extern fn @"llvm.x86.avx2.pmulhu.w"(@Vector(16, u16), @Vector(16, u16)) @Vector(16, u16);

const test_isas = blk: {
    var isas: []const Isa = &.{};
    for (std.enums.values(Isa)) |isa| {
        if (isa.supported()) isas = isas ++ .{isa};
    }
    break :blk isas;
};

const all_last_chunks = std.enums.values(LastChunk);

/// Decodes `src` with every kernel and expects the scalar reference's
/// result and bytes.
fn expectSameDecode(dst_len: usize, src: []const u8, options: DecodeOptions) !void {
    var want_buf: [2400]u8 = undefined;
    var got_buf: [2400]u8 = undefined;
    const want = scalar.decode(want_buf[0..dst_len], src, options);
    inline for (test_isas) |isa| {
        const got = switch (options.alphabet) {
            inline else => |a| decodeWith(isa, a, got_buf[0..dst_len], src, options.last_chunk),
        };
        if (!std.meta.eql(want, got)) {
            std.debug.print("{t} {any} dst_len={d} src=\"{f}\"\n", .{ isa, options, dst_len, std.zig.fmtString(src) });
        }
        try testing.expectEqual(want, got);
        if (want.err == .none) try testing.expectEqualSlices(u8, want_buf[0..want.count], got_buf[0..got.count]);
    }
}

fn randomAlphabet(rand: std.Random) Alphabet {
    return if (rand.boolean()) .standard else .url;
}

test "every kernel encodes as the scalar reference and std.base64 do" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const rand = prng.random();
    var src: [600]u8 = undefined;
    var want: [800]u8 = undefined;
    var got: [800]u8 = undefined;
    for (0..src.len) |n| {
        rand.bytes(src[0..n]);
        inline for (.{ Alphabet.standard, Alphabet.url }) |alphabet| {
            inline for (.{ true, false }) |padding| {
                const options: EncodeOptions = .{ .alphabet = alphabet, .padding = padding };
                const len = scalar.encode(&want, src[0..n], options);
                const codecs = switch (alphabet) {
                    .standard => if (padding) std.base64.standard else std.base64.standard_no_pad,
                    .url => if (padding) std.base64.url_safe else std.base64.url_safe_no_pad,
                };
                try testing.expectEqualStrings(codecs.Encoder.encode(&got, src[0..n]), want[0..len]);
                inline for (test_isas) |isa| {
                    try testing.expectEqual(len, encodeWith(isa, alphabet, &got, src[0..n], padding));
                    try testing.expectEqualStrings(want[0..len], got[0..len]);
                }
            }
        }
    }
}

test "every kernel decodes valid input as the scalar reference and std.base64 do" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const rand = prng.random();
    var raw: [700]u8 = undefined;
    var enc: [1000]u8 = undefined;
    var buf: [700]u8 = undefined;
    for (0..raw.len) |n| {
        rand.bytes(raw[0..n]);
        const alphabet = randomAlphabet(rand);
        const padding = rand.boolean();
        const len = scalar.encode(&enc, raw[0..n], .{ .alphabet = alphabet, .padding = padding });
        const codecs = switch (alphabet) {
            .standard => if (padding) std.base64.standard else std.base64.standard_no_pad,
            .url => if (padding) std.base64.url_safe else std.base64.url_safe_no_pad,
        };
        try codecs.Decoder.decode(buf[0..n], enc[0..len]);
        try testing.expectEqualSlices(u8, raw[0..n], buf[0..n]);
        for (all_last_chunks) |last| {
            const options: DecodeOptions = .{ .alphabet = alphabet, .last_chunk = last };
            try expectSameDecode(maxDecodedLen(len), enc[0..len], options);
        }
        try testing.expectEqual(Result.ok(n), decode(&buf, enc[0..len], .{ .alphabet = alphabet }));
        try testing.expectEqualSlices(u8, raw[0..n], buf[0..n]);
    }
}

test "every kernel skips whitespace and finds invalid characters at every position" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const rand = prng.random();
    var raw: [150]u8 = undefined;
    var enc: [256]u8 = undefined;
    var mutated: [300]u8 = undefined;
    // Lengths around one, two, and three 64-character blocks.
    for ([_]usize{ 1, 2, 3, 47, 48, 49, 50, 95, 96, 97, 98, 143, 144, 145 }) |n| {
        rand.bytes(raw[0..n]);
        const alphabet = randomAlphabet(rand);
        const len = scalar.encode(&enc, raw[0..n], .{ .alphabet = alphabet, .padding = rand.boolean() });
        const options: DecodeOptions = .{ .alphabet = alphabet, .last_chunk = rand.enumValue(LastChunk) };
        for (0..len + 1) |pos| {
            // Inserted: whitespace, `=`, and a byte outside the alphabet.
            for ([_]u8{ ' ', '\t', '\n', '\x0c', '\r', '=', 0x0b, '*', 0x80, if (alphabet == .url) '+' else '-' }) |c| {
                @memcpy(mutated[0..pos], enc[0..pos]);
                mutated[pos] = c;
                @memcpy(mutated[pos + 1 .. len + 1], enc[pos..len]);
                try expectSameDecode(maxDecodedLen(len + 1), mutated[0 .. len + 1], options);
                // And replacing the character there.
                if (pos < len) try expectSameDecode(maxDecodedLen(len), mutated[0..len], options);
            }
        }
    }
}

test "every kernel classifies every byte value at every position of two blocks" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const rand = prng.random();
    var raw: [96]u8 = undefined;
    rand.bytes(&raw);
    var enc: [128]u8 = undefined;
    var mutated: [129]u8 = undefined;
    for ([_]Alphabet{ .standard, .url }) |alphabet| {
        _ = scalar.encode(&enc, &raw, .{ .alphabet = alphabet });
        for (0..256) |c| {
            for (0..enc.len) |pos| {
                @memcpy(mutated[0..pos], enc[0..pos]);
                mutated[pos] = @intCast(c);
                @memcpy(mutated[pos + 1 ..], enc[pos..]);
                try expectSameDecode(96, &mutated, .{ .alphabet = alphabet });
            }
        }
    }
}

test "every kernel decodes line-wrapped and space-strewn input" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const rand = prng.random();
    var raw: [600]u8 = undefined;
    var enc: [800]u8 = undefined;
    var spaced: [3200]u8 = undefined;
    for (0..300) |_| {
        const n = rand.uintLessThan(usize, raw.len);
        rand.bytes(raw[0..n]);
        const alphabet = randomAlphabet(rand);
        const len = scalar.encode(&enc, raw[0..n], .{ .alphabet = alphabet, .padding = rand.boolean() });
        // Lines of a random width, or whitespace at random, in runs.
        const width = rand.intRangeAtMost(usize, 1, 100);
        const odds = rand.intRangeAtMost(usize, 2, 70);
        var m: usize = 0;
        for (enc[0..len], 0..) |c, k| {
            const wrap = if (rand.boolean()) k % width == 0 else rand.uintLessThan(usize, odds) == 0;
            if (wrap) {
                for (0..rand.intRangeAtMost(usize, 1, 3)) |_| {
                    spaced[m] = " \t\n\x0c\r"[rand.uintLessThan(usize, 5)];
                    m += 1;
                }
            }
            spaced[m] = c;
            m += 1;
        }
        for (all_last_chunks) |last| {
            const options: DecodeOptions = .{ .alphabet = alphabet, .last_chunk = last };
            try expectSameDecode(maxDecodedLen(m), spaced[0..m], options);
            // A random mutation anywhere, and a short output buffer.
            const saved = spaced[m / 2];
            spaced[rand.uintLessThan(usize, m + 1) -| 1] = rand.int(u8);
            try expectSameDecode(maxDecodedLen(m), spaced[0..m], options);
            spaced[m / 2] = saved;
            try expectSameDecode(rand.uintAtMost(usize, maxDecodedLen(m)), spaced[0..m], options);
        }
    }
}
