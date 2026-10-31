//! Base64 encoding and decoding with SIMD, after Muła and Lemire, "Faster
//! Base64 Encoding and Decoding Using AVX2 Instructions" (2018), and "Base64
//! encoding and decoding at almost the speed of a memory copy" (2020) for
//! AVX-512 VBMI. Each step of the main loops turns 48 bytes into 64
//! characters or back; the last step works on a zero-padded block and writes
//! only what the input fills, so short inputs take the same vector code.
//! Decoding skips ASCII whitespace as WHATWG's forgiving-base64 does: a
//! block with whitespace has it compressed out into a staging buffer, which
//! is decoded once it holds 64 characters. The scalar reference in
//! `scalar_base64.zig` takes over at errors and at an output buffer too
//! small to finish in vectors, and every path here returns exactly what it
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
/// code for any target; the others call LLVM intrinsics for byte lookups,
/// permutes, and multiply-adds, so they need the LLVM backend.
pub const Isa = enum {
    generic,
    ssse3,
    avx2,
    /// AVX-512 with VBMI (`vpermb`, `vpermi2b`, `vpmultishiftqb`); with
    /// VBMI2 it also compresses whitespace out with `vpcompressb`.
    avx512vbmi,
    neon,

    /// Whether this build can run the kernel.
    pub fn supported(isa: Isa) bool {
        const llvm = builtin.zig_backend == .stage2_llvm;
        const cpu = builtin.cpu;
        return switch (isa) {
            .generic => true,
            .ssse3 => llvm and cpu.arch == .x86_64 and cpu.has(.x86, .ssse3),
            .avx2 => llvm and cpu.arch == .x86_64 and cpu.has(.x86, .avx2),
            .avx512vbmi => llvm and cpu.arch == .x86_64 and cpu.has(.x86, .avx512bw) and cpu.has(.x86, .avx512vbmi),
            .neon => llvm and cpu.arch.isAARCH64() and cpu.has(.aarch64, .neon),
        };
    }
};

/// The kernel `encode` and `decode` use: the widest the target supports.
pub const native: Isa = for ([_]Isa{ .avx512vbmi, .avx2, .ssse3, .neon }) |isa| {
    if (isa.supported()) break isa;
} else .generic;

pub fn encodeWith(comptime isa: Isa, comptime alphabet: Alphabet, dst: []u8, src: []const u8, padding: bool) usize {
    const options: EncodeOptions = .{ .alphabet = alphabet, .padding = padding };
    std.debug.assert(dst.len >= encodedLen(src.len, options));
    const K = Kernel(isa, alphabet);
    const n = K.lanes;
    const bytes = n / 4 * 3;
    var i: usize = 0;
    var o: usize = 0;
    if (src.len >= 64) {
        // The wide kernel reads from `K.skip` bytes before its input, so the
        // first 12 bytes go through the narrow one.
        if (K.skip > 0) {
            const N = Kernel(.ssse3, alphabet);
            dst[0..16].* = N.encode(src[0..16], N.mulConst());
            i = 12;
            o = 16;
        }
        // Each vector reads `n` bytes and encodes `bytes` of them.
        const mul = K.mulConst();
        while (src.len - i >= 48 - bytes + n - K.skip) : ({
            i += 48;
            o += 64;
        }) {
            inline for (0..64 / n) |k| {
                dst[o + k * n ..][0..n].* = K.encode(src[i - K.skip + k * bytes ..][0..n], mul);
            }
        }
    }
    // The rest, fewer than 64 bytes, in zero-padded blocks of up to 48.
    if (src.len - i > 48) {
        o += K.encodeLast(dst[o..], src[i..][0..48], padding);
        i += 48;
    }
    return o + K.encodeLast(dst[o..], src[i..], padding);
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
    var i: usize = 0;
    var o: usize = 0;
    // The 6-bit values of blocks with whitespace, compressed, not yet
    // decoded. They are decoded four blocks at a time, well after they are
    // stored, so loads do not wait on the stores: fewer than 256 between
    // steps, one more block, and 8-byte stores past the end.
    var stage: [336]u8 align(64) = undefined;
    var staged: usize = 0;
    blocks: while (true) {
        // Blocks without whitespace go straight to `dst`, as many as fit
        // with the slack.
        var clean = @min((t.len - i) / 64, ((dst.len - o) -| K.slack) / 48);
        // Two at a time, with one test for both.
        while (clean >= 2) : (clean -= 2) {
            const a = K.classifyBlock(src[i..][0..64]);
            const b = K.classifyBlock(src[i + 64 ..][0..64]);
            if (a.anyBadWith(b)) break;
            K.packBlock(a.values, dst[o..][0 .. 48 + K.slack]);
            K.packBlock(b.values, dst[o + 48 ..][0 .. 48 + K.slack]);
            i += 128;
            o += 96;
        }
        while (clean > 0) : (clean -= 1) {
            const c = K.classifyBlock(src[i..][0..64]);
            if (c.anyBad()) break;
            K.packBlock(c.values, dst[o..][0 .. 48 + K.slack]);
            i += 64;
            o += 48;
        }
        // From the first with whitespace, all go through `stage`.
        while (t.len - i >= 64 and dst.len - o >= 48 * (staged / 64 + 1) + K.slack) {
            const block = src[i..][0..64];
            const c = K.classifyBlock(block);
            if (!c.anyBad()) {
                stage[staged..][0..64].* = @bitCast(c.values);
            } else {
                const space = K.spaceMask(simd.load(u8, block));
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

    // A block without whitespace that fits only without the slack.
    if (staged == 0 and t.len - i >= 64 and dst.len - o >= 48) {
        const c = K.classifyBlock(src[i..][0..64]);
        if (!c.anyBad()) {
            K.storePartial(dst[o..], K.packAll(c.values), 48);
            i += 64;
            o += 48;
        }
    }
    // The input from `end` on is not yet staged or decoded.
    var end = i;
    if (t.len - i < 64) {
        // The last block, fewer than 64 characters, zero-padded.
        const n = t.len - i;
        const live = lowBits(n);
        const block = K.loadPartial(src[i..t.len]);
        const c = K.classifyBlock(block);
        const bad = c.badMask() & live;
        if (bad == 0 and staged == 0) {
            if (K.finish(c.values, n, dst[o..], t, last_chunk)) |len| return .ok(o + len);
            return scalar.decodeFrom(dst, src, t, i, o, options);
        }
        const space = if (bad == 0) 0 else K.spaceMask(block) & live;
        if (bad & ~space == 0) {
            if (space == 0) {
                stage[staged..][0..64].* = @bitCast(c.values);
            } else {
                K.compress(c.values, space, stage[staged..][0..72]);
            }
            staged += n - @popCount(space);
            end = t.len;
        }
    }

    // Decode the staged blocks that fit, and the last one if the input is
    // all staged. Otherwise hand the scalar decoder the input from the
    // first value still undecoded.
    var done: usize = 0;
    while (staged - done >= 64 and dst.len - o >= 48) : (done += 64) {
        const values: [K.blocks]K.V = @bitCast(stage[done..][0..64].*);
        if (dst.len - o >= 48 + K.slack) {
            K.packBlock(values, dst[o..][0 .. 48 + K.slack]);
        } else {
            K.storePartial(dst[o..], K.packAll(values), 48);
        }
        o += 48;
    }
    if (end == t.len and staged - done < 64) {
        const values: [K.blocks]K.V = @bitCast(stage[done..][0..64].*);
        if (K.finish(values, staged - done, dst[o..], t, last_chunk)) |len| return .ok(o + len);
    }
    var start = end;
    var keep = staged - done;
    while (keep > 0) {
        start -= 1;
        if (!scalar.isSpace(src[start])) keep -= 1;
    }
    return scalar.decodeFrom(dst, src, t, start, o, options);
}

/// The low `n` bits set, for `n` up to 64.
inline fn lowBits(n: usize) u64 {
    return if (n >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(n)) - 1;
}

fn Kernel(comptime isa: Isa, comptime alphabet: Alphabet) type {
    if (!isa.supported()) @compileError("this build cannot run the " ++ @tagName(isa) ++ " kernel");
    return struct {
        const lanes = switch (isa) {
            .avx512vbmi => 64,
            .avx2 => 32,
            .generic, .ssse3, .neon => 16,
        };
        const V = @Vector(lanes, u8);
        const V64 = @Vector(64, u8);
        const blocks = 64 / lanes;
        const chars = alphabet.chars();
        const avx512 = isa == .avx512vbmi;

        inline fn splat(x: u8) V {
            return @splat(x);
        }

        /// How many bytes before its input `encode` reads.
        const skip = if (lanes == 32) 4 else 0;

        /// Encodes `src[skip..][0 .. lanes / 4 * 3]`.
        inline fn encode(src: *const [lanes]u8, mul: Mul) [lanes]u8 {
            // The load is volatile so that LLVM keeps it whole: it would
            // split the vector it does not use all of into three loads.
            const in = @as(*align(1) const volatile V, @ptrCast(src)).*;
            return translate(@shuffle(u8, in, undefined, spreadMask(!avx512, 0)), mul);
        }

        /// Encodes the first 48 bytes of a block.
        inline fn encodeBlock(in: V64) V64 {
            var out: [blocks]V = undefined;
            inline for (0..blocks) |k| {
                out[k] = translate(@shuffle(u8, in, undefined, spreadMask(false, k * lanes / 4)), undefined);
            }
            return @bitCast(out);
        }

        /// Encodes `src`, at most 48 bytes, writing only its
        /// `encodedLen` characters.
        inline fn encodeLast(dst: []u8, src: []const u8, padding: bool) usize {
            if (avx512) {
                const len = encodedLen(src.len, .{ .padding = padding });
                if (src.len == 0) return 0;
                return storeLast(dst, encodeBlock(loadPartial(src)), src.len, len);
            }
            // 12 bytes at a time with 16-byte vectors, then one or two
            // vectors from a zero-padded load of what is left.
            const N = Kernel(if (isa == .avx2) .ssse3 else isa, alphabet);
            const mul = N.mulConst();
            var i: usize = 0;
            var o: usize = 0;
            while (src.len - i >= 16) : ({
                i += 12;
                o += 16;
            }) dst[o..][0..16].* = N.encode(src[i..][0..16], mul);
            const r = src.len - i;
            const len = encodedLen(r, .{ .padding = padding });
            // Up to two groups and a partial one, the scalar code inline is
            // faster.
            const options: EncodeOptions = .{ .alphabet = alphabet, .padding = padding };
            if (r <= 7) return o + @call(.always_inline, scalar.encode, .{ dst[o..], src[i..], options });
            const in = std.simd.extract(simd.loadPartial(u8, src[i..]), 0, 16);
            const a = N.translate(@shuffle(u8, in, undefined, N.spreadMask(false, 0)), mul);
            // Bytes 12 to 14, and zeros.
            const b = if (r <= 12) a else N.translate(@shuffle(u8, in, @as(@Vector(16, u8), @splat(0)), blk: {
                var m = N.spreadMask(false, 4);
                for (&m) |*x| if (x.* >= 16) {
                    x.* = -1;
                };
                break :blk m;
            }), mul);
            return o + storeLast(dst[o..], std.simd.join(a, b), r, len);
        }

        /// Stores the `len` characters that encode `n` bytes, from a vector
        /// that encodes them followed by zeros: the characters past the
        /// data's are padding.
        inline fn storeLast(dst: []u8, out: anytype, n: usize, len: usize) usize {
            const lanes_ = @typeInfo(@TypeOf(out)).vector.len;
            const data: u8 = @intCast((n * 4 + 2) / 3);
            const pad = std.simd.iota(u8, lanes_) >= @as(@TypeOf(out), @splat(data));
            storePartial(dst, @select(u8, pad, @as(@TypeOf(out), @splat('=')), out), len);
            return len;
        }

        /// The shuffle that gathers each group of three bytes a, b, c into
        /// the 32-bit lane b a c b (a b b c on big-endian targets), so that
        /// 16-bit lanes hold a:b and b:c, for `lanes / 4` groups from group
        /// `first`. Groups follow each other, or with `split`, each 16-byte
        /// lane holds 12 bytes of a vector loaded `skip` bytes early: Muła
        /// and Lemire's trick to shuffle only within lanes.
        fn spreadMask(comptime split: bool, comptime first: usize) [lanes]i32 {
            var m: [lanes]i32 = undefined;
            for (0..lanes / 4) |g| {
                const base = if (split) g / 4 * 16 + g % 4 * 3 + (if (g < 4) skip else 0) else (first + g) * 3;
                m[g * 4 ..][0..4].* = if (big)
                    .{ base, base + 1, base + 1, base + 2 }
                else
                    .{ base + 1, base, base + 2, base + 1 };
            }
            return m;
        }

        /// Turns each spread group into its four characters.
        inline fn translate(spread: V, mul: Mul) V {
            if (avx512) {
                // Each byte takes the 8 bits from its shift in its 64-bit
                // lane, and `vpermb` looks up the low 6 of them.
                const shifts = rep(V, .{ 10, 4, 22, 16, 42, 36, 54, 48 });
                const idx = @"llvm.x86.avx512.pmultishift.qb.512"(shifts, spread);
                return @"llvm.x86.avx512.permvar.qi.512"(chars.*, idx);
            }
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
            const t3 = t2 *% mul;
            // Each 16-bit lane holds two indices, the first in its low byte.
            const idx: V = @bitCast(if (big) @byteSwap(t1 | t3) else t1 | t3);
            return idx +% offsets(idx);
        }

        const Mul = @Vector(lanes / 2, u16);

        /// The multiplier that moves the two middle indices into place,
        /// hidden from LLVM on x86, where it would turn the multiply into
        /// two shifts and a blend, which costs a shuffle-port instruction
        /// more than `pmullw`. Made once, before a loop.
        inline fn mulConst() Mul {
            const m = rep(Mul, .{ 0x0010, 0x0100 });
            if (isa != .ssse3 and isa != .avx2) return m;
            return asm (""
                : [ret] "=x" (-> Mul),
                : [m] "0" (m),
            );
        }

        inline fn mulhi(a: @Vector(lanes / 2, u16), b: @Vector(lanes / 2, u16)) @Vector(lanes / 2, u16) {
            return switch (isa) {
                .ssse3 => @"llvm.x86.sse2.pmulhu.w"(a, b),
                .avx2 => @"llvm.x86.avx2.pmulhu.w"(a, b),
                .generic, .neon, .avx512vbmi => @truncate((@as(@Vector(lanes / 2, u32), a) * b) >> @splat(16)),
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
            // Indices 0..51 become 0 and 52..63 become 1..12, then all from
            // 26 one more: one table entry per offset, from three
            // single-cycle instructions.
            const I = @Vector(lanes, i8);
            const ge26 = @as(I, @bitCast(idx)) > @as(I, @splat(25));
            const above: V = @bitCast(@select(i8, ge26, @as(I, @splat(-1)), @as(I, @splat(0))));
            const reduced = (idx -| splat(51)) -% above;
            const table: [16]u8 = .{ 'A', o_lower } ++ .{o_digit} ** 10 ++ .{ o_62, o_63, 0, 0 };
            return simd.lookup16(table, reduced);
        }

        const Classified = struct { values: V, bad: @Vector(lanes, bool) };

        /// Each character's 6-bit value, and whether it is outside the
        /// alphabet (whitespace included).
        inline fn classify(in: V) Classified {
            if (avx512) {
                // One 128-entry table, indexed by the low 7 bits; bytes from
                // 0x80 are flagged by their own top bit.
                const table = comptime blk: {
                    var t: [128]u8 = @splat(0x80);
                    for (chars, 0..) |c, v| t[c] = v;
                    break :blk t;
                };
                const v = @"llvm.x86.avx512.vpermi2var.qi.512"(table[0..64].*, in, table[64..].*);
                return .{ .values = v, .bad = (v | in) >= splat(0x80) };
            }
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

            inline fn anyBadWith(a: Block, b: Block) bool {
                var any = a.bad[0];
                inline for (a.bad[1..] ++ b.bad) |x| any = anyTrue(any, x);
                return @reduce(.Or, any);
            }

            /// Bit k is set when character k is outside the alphabet.
            inline fn badMask(b: Block) u64 {
                var m: u64 = 0;
                inline for (b.bad, 0..) |x, k| m |= @as(u64, simd.bitmask(x)) << (k * lanes);
                return m;
            }
        };

        /// Classifies a block, from memory or a vector.
        inline fn classifyBlock(src: anytype) Block {
            const in: [blocks]V = @bitCast(if (@TypeOf(src) == V64) src else simd.load(u8, src));
            var b: Block = undefined;
            inline for (0..blocks) |k| {
                const c = classify(in[k]);
                b.values[k] = c.values;
                b.bad[k] = c.bad;
            }
            return b;
        }

        /// How many bytes past its 48 `packBlock` writes: none with AVX-512,
        /// whose masked store writes exactly 48.
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

        /// Turns 64 6-bit values into 48 bytes, the first 48 of the result.
        inline fn packAll(values: [blocks]V) V64 {
            var p: [blocks]V = undefined;
            inline for (0..blocks) |k| p[k] = pack(values[k]);
            if (blocks == 1) return @bitCast(p);
            return @shuffle(u8, @as(V64, @bitCast(p)), undefined, blk: {
                var m: [64]i32 = @splat(0);
                for (0..48) |j| m[j] = j / (lanes / 4 * 3) * lanes + j % (lanes / 4 * 3);
                break :blk m;
            });
        }

        /// Decodes the last `count` values, fewer than 64, by the last-chunk
        /// rules, into `dst`, and returns the number of bytes written. Null
        /// when the scalar decoder must finish: at an error, at a partial
        /// chunk the rules leave to it, or when `dst` is too small.
        inline fn finish(values: [blocks]V, count: usize, dst: []u8, t: scalar.Trim, last: LastChunk) ?usize {
            const rest = count % 4;
            const tail: usize = switch (rest) {
                0 => if (t.padding == 0) 0 else return null,
                1 => return null,
                else => if (t.padding == 0) switch (last) {
                    .loose => rest - 1,
                    .stop_before_partial => 0,
                    .strict => return null,
                } else if (@as(usize, t.padding) + rest == 4) rest - 1 else return null,
            };
            const len = count / 4 * 3 + tail;
            if (dst.len < len) return null;
            // Zeros past the data, so that a partial chunk decodes with zero
            // bits after it, and the byte after its data holds its extra bits.
            const live = std.simd.iota(u8, 64) < @as(V64, @splat(@intCast(count)));
            const out = packAll(@bitCast(@select(u8, live, @as(V64, @bitCast(values)), @as(V64, @splat(0)))));
            if (last == .strict and tail != 0 and @as([64]u8, out)[len] != 0) return null;
            storePartial(dst, out, len);
            return len;
        }

        /// Bit k is set when character k is ASCII whitespace.
        inline fn spaceMask(block: V64) u64 {
            const in: [blocks]V = @bitCast(block);
            var m: u64 = 0;
            inline for (0..blocks) |k| m |= @as(u64, simd.bitmask(isSpace(in[k]))) << (k * lanes);
            return m;
        }

        /// Copies the bytes of `src` not in `space` to the front of `out`. It
        /// may write all of `out`.
        inline fn compress(values: [blocks]V, space: u64, out: *[72]u8) void {
            if (avx512 and simd.has_vbmi2) {
                const keep: @Vector(64, bool) = @bitCast(~space);
                out[0..64].* = @"llvm.x86.avx512.mask.compress.v64i8"(values[0], @splat(0), keep);
                return;
            }
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
                .avx512vbmi => @bitCast(@"llvm.x86.avx512.pmaddw.d.512"(
                    @"llvm.x86.avx512.pmaddubs.w.512"(values, @bitCast(rep(@Vector(32, u16), .{0x0140}))),
                    @bitCast(rep(@Vector(16, u32), .{0x00011000})),
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
                var m: [lanes]i32 = @splat(0);
                for (0..lanes / 4) |g| m[g * 3 ..][0..3].* = if (big)
                    .{ g * 4 + 1, g * 4 + 2, g * 4 + 3 }
                else
                    .{ g * 4 + 2, g * 4 + 1, g * 4 };
                break :blk m;
            });
        }

        /// Loads `s`, shorter than a block, zero-padded, without reading
        /// past it.
        inline fn loadPartial(s: []const u8) V64 {
            if (avx512) return @"llvm.masked.load.v64i8.p0"(s.ptr, 1, @bitCast(lowBits(s.len)), @splat(0));
            return simd.loadPartial(u8, s);
        }

        /// Stores the first `len` bytes of `v`, a vector of 16, 32, or 64
        /// bytes, without writing past them.
        inline fn storePartial(dst: []u8, v: anytype, len: usize) void {
            const n = @typeInfo(@TypeOf(v)).vector.len;
            std.debug.assert(len <= n and dst.len >= len);
            if (avx512 and n == 64) return @"llvm.masked.store.v64i8.p0"(v, dst.ptr, 1, @bitCast(lowBits(len)));
            // Whole 16-byte pieces, then the last part of one in two
            // overlapping integer stores.
            const pieces: [n / 16]@Vector(16, u8) = @bitCast(v);
            const full = len / 16;
            inline for (0..n / 16) |k| {
                if (k < full) dst[k * 16 ..][0..16].* = pieces[k];
            }
            if (full == n / 16) return;
            // A switch here compiles to a gather of 16 single bytes.
            var piece = pieces[0];
            inline for (1..n / 16) |k| {
                if (full == k) piece = pieces[k];
            }
            const x = std.mem.littleToNative(u128, @bitCast(piece));
            const d = dst[full * 16 ..];
            const r = len % 16;
            if (r >= 8) {
                std.mem.writeInt(u64, d[0..8], @truncate(x), .little);
                std.mem.writeInt(u64, d[r - 8 ..][0..8], @truncate(x >> @intCast(8 * (r - 8))), .little);
            } else if (r >= 4) {
                std.mem.writeInt(u32, d[0..4], @truncate(x), .little);
                std.mem.writeInt(u32, d[r - 4 ..][0..4], @truncate(x >> @intCast(8 * (r - 4))), .little);
            } else if (r >= 2) {
                std.mem.writeInt(u16, d[0..2], @truncate(x), .little);
                std.mem.writeInt(u16, d[r - 2 ..][0..2], @truncate(x >> @intCast(8 * (r - 2))), .little);
            } else if (r == 1) {
                d[0] = @truncate(x);
            }
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
extern fn @"llvm.x86.avx512.pmaddubs.w.512"(@Vector(64, u8), @Vector(64, u8)) @Vector(32, i16);
extern fn @"llvm.x86.avx512.pmaddw.d.512"(@Vector(32, i16), @Vector(32, i16)) @Vector(16, i32);
extern fn @"llvm.x86.avx512.pmultishift.qb.512"(@Vector(64, u8), @Vector(64, u8)) @Vector(64, u8);
extern fn @"llvm.x86.avx512.permvar.qi.512"(@Vector(64, u8), @Vector(64, u8)) @Vector(64, u8);
extern fn @"llvm.x86.avx512.vpermi2var.qi.512"(@Vector(64, u8), @Vector(64, u8), @Vector(64, u8)) @Vector(64, u8);
extern fn @"llvm.x86.avx512.mask.compress.v64i8"(@Vector(64, u8), @Vector(64, u8), @Vector(64, bool)) @Vector(64, u8);
extern fn @"llvm.masked.load.v64i8.p0"(*const anyopaque, i32, @Vector(64, bool), @Vector(64, u8)) @Vector(64, u8);
extern fn @"llvm.masked.store.v64i8.p0"(@Vector(64, u8), *anyopaque, i32, @Vector(64, bool)) void;

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
