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
const compat = @import("compat.zig");
const builtin = @import("builtin");
const testing = std.testing;
const simd = @import("simd.zig");
const dispatch = @import("dispatch.zig");
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
    return dispatch.call(@src(), encodeKernel, .{ dst, src, options });
}

fn encodeKernel(dst: []u8, src: []const u8, options: EncodeOptions) usize {
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
///
/// `dst` may start where `src` does, to decode in place, with the same
/// result as decoding into a buffer of its own; on failure the contents of
/// `src` are then unspecified too. Otherwise the two must not overlap.
pub fn decode(dst: []u8, src: []const u8, options: DecodeOptions) Result {
    return dispatch.call(@src(), decodeKernel, .{ dst, src, options });
}

fn decodeKernel(dst: []u8, src: []const u8, options: DecodeOptions) Result {
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

/// The kernel `encode` and `decode` use: the widest the target supports, or
/// with runtime dispatch, the widest the tier they run in supports.
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
    if (K.avx512 and src.len >= 64) {
        // After the first block, each step encodes the 48 bytes at the top
        // of the 64 ending with them, so that the loop runs while 48 are
        // left and one partial block finishes.
        simd.storeVolatile(dst, @as(K.V, K.encode(src[0..64], undefined)));
        i = 48;
        o = 64;
        // The step is hidden from LLVM, which unrolled the loop four times
        // with a remainder loop that costs more at 100 to 256 bytes.
        while (src.len - i >= 48) : ({
            i = asm (""
                : [ret] "=r" (-> usize),
                : [i] "0" (i + 48),
            );
            o += 64;
        }) {
            simd.storeVolatile(dst[o..], @as(K.V, K.encodeTop(src[i - 16 ..][0..64])));
        }
        return o + K.encodeLast(dst[o..], src, i, src.len, padding);
    }
    if (K.structured and src.len >= 48) {
        while (src.len - i >= 48) : ({
            i += 48;
            o += 64;
        }) K.encodeStructured(src[i..][0..48], dst[o..][0..64]);
        return o + K.encodeLast(dst[o..], src, i, src.len, padding);
    }
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
            // Volatile, so that LLVM keeps each store whole: it split the
            // AVX-512 one in two.
            inline for (0..64 / n) |k| {
                simd.storeVolatile(dst[o + k * n ..], @as(K.V, K.encode(src[i - K.skip + k * bytes ..][0..n], mul)));
            }
        }
    }
    // The rest, fewer than 64 bytes, in zero-padded blocks of up to 48.
    if (src.len - i > 48) {
        o += K.encodeLast(dst[o..], src, i, i + 48, padding);
        i += 48;
    }
    return o + K.encodeLast(dst[o..], src, i, src.len, padding);
}

pub fn decodeWith(
    comptime isa: Isa,
    comptime alphabet: Alphabet,
    dst: []u8,
    src: []const u8,
    last_chunk: LastChunk,
) Result {
    const t = scalar.trim(src);
    // A block or more inline, registers saved and all: out of line in the
    // tier objects, as `validate.utf8`'s long path is, the call cost 88
    // and 344 characters 7-12 TSC ticks for 2 saved at 24
    // (docs/slop/results/short-20261101.md).
    if (t.len >= 64) return decodeBlocks(isa, alphabet, dst, src, t, last_chunk);
    if (decodeShort(isa, alphabet, dst, src, t, last_chunk)) |len| return .ok(len);
    return fromWords(decodeShortRest(isa, alphabet, dst, src, last_chunk));
}

/// Fewer than 64 characters, clean, by the last-chunk rules, and with
/// room: the bytes written. Null for anything else, which
/// `decodeShortRest` finishes out of line, off the common path.
inline fn decodeShort(
    comptime isa: Isa,
    comptime alphabet: Alphabet,
    dst: []u8,
    src: []const u8,
    t: scalar.Trim,
    last_chunk: LastChunk,
) ?usize {
    const K = Kernel(isa, alphabet);
    const n = t.len;
    if (n == 0 and t.padding == 0) return 0;
    const live = simd.lowBits(u64, n);
    // On AVX-512 one masked load, where `loadTail` built the block from
    // integer loads: with `decodeShortRest` out of line, 24 characters
    // went from 34.9 to 26.9 TSC ticks a call dispatched
    // (docs/slop/results/short-20261101.md).
    const block = if (K.avx512) simd.loadShort(u8, src[0..n]) else simd.loadTail(src, 0, n);
    if (K.blocks > 1 and n <= 32) {
        // Classify and pack only the first half of the block, one vector
        // on AVX2 and two on SSE and NEON
        // (docs/slop/results/calls-20261031.md).
        const in: [K.blocks]K.V = @bitCast(block);
        var values: [K.blocks / 2]K.V = undefined;
        var bad: u64 = 0;
        inline for (&values, 0..) |*v, k| {
            const c = K.classify(in[k]);
            v.* = c.values;
            bad |= @as(u64, simd.bitmask(c.bad)) << (k * K.lanes);
        }
        if (bad & live != 0) return null;
        return K.finish(values, n, dst, t, last_chunk);
    }
    const c = K.classifyBlock(block);
    if (c.badMask() & live != 0) return null;
    return K.finish(c.values, n, dst, t, last_chunk);
}

noinline fn decodeShortRest(
    comptime isa: Isa,
    comptime alphabet: Alphabet,
    dst: []u8,
    src: []const u8,
    last_chunk: LastChunk,
) Words {
    return toWords(decodeLast(isa, alphabet, dst, src, scalar.trim(src), 0, 0, last_chunk));
}

/// `decodeWith` from the first block, for at least one.
inline fn decodeBlocks(
    comptime isa: Isa,
    comptime alphabet: Alphabet,
    dst: []u8,
    src: []const u8,
    t: scalar.Trim,
    last_chunk: LastChunk,
) Result {
    const K = Kernel(isa, alphabet);
    var i: usize = 0;
    var o: usize = 0;
    // Where the current run of characters between whitespace starts, after
    // whole chunks; `i` is whole blocks from it.
    var run: usize = 0;
    // Tested first, so that a short input skips the loop and the
    // constants LLVM loads before it.
    while (t.len - i >= 64) {
        // Blocks without whitespace go straight to `dst`, as many as fit
        // with `packClean`'s slack.
        var clean = @min((t.len - i) / 64, ((dst.len - o) -| K.clean_slack) / 48);
        // Two at a time, with one test for both.
        while (clean >= 2) : (clean -= 2) {
            const a = K.classifyClean(src[i..][0..64]);
            const b = K.classifyClean(src[i + 64 ..][0..64]);
            if (a.anyBadWith(b)) {
                if (!a.anyBad()) {
                    K.packClean(a.values, dst[o..][0 .. 48 + K.clean_slack]);
                    i += 64;
                    o += 48;
                }
                break;
            }
            K.packClean(a.values, dst[o..][0 .. 48 + K.clean_slack]);
            K.packClean(b.values, dst[o + 48 ..][0 .. 48 + K.clean_slack]);
            i += 128;
            o += 96;
        } else if (clean == 1) {
            const c = K.classifyClean(src[i..][0..64]);
            if (!c.anyBad()) {
                K.packClean(c.values, dst[o..][0 .. 48 + K.clean_slack]);
                i += 64;
                o += 48;
            }
        }
        if (t.len - i < 64) break;
        // A whole block with whitespace or an error, or without room for
        // the slack. Where each run of characters between whitespace is a
        // multiple of four long and at least a block, as MIME's and PEM's
        // lines are, the block that ends a run is decoded from `src`,
        // overlapping what the run's earlier blocks wrote, and the
        // whitespace skipped: nothing to compress. Anything else goes
        // through `decodeStaged`.
        if (dst.len - o < 48 + K.slack) break;
        const c = K.classifyBlock(src[i..][0..64]);
        const bad = c.badMask();
        const space = c.spaceMask();
        const p: u6 = @truncate(@ctz(bad));
        if (space >> p & 1 == 0) break;
        // The run ends at `i + p`.
        const len = i - run + p;
        if (p != 0) {
            if (len % 4 != 0 or i == run) break;
            const end = i + p;
            if (untouched(dst, src, end - 64, o + K.slack)) {
                const ending = K.classifyClean(src[end - 64 ..][0..64]);
                K.packClean(ending.values, dst[o + p / 4 * 3 - 48 ..][0 .. 48 + K.clean_slack]);
            } else {
                // Decoding in place has written over that block's start:
                // the run's end from this block instead, without the slack,
                // which would overwrite the characters after it.
                simd.storePartial(dst[o..], K.packAll(c.values), p / 4 * 3);
            }
            o += p / 4 * 3;
        }
        const k = @ctz(~(space >> p));
        i += @min(64, @as(usize, p) + k);
        run = i;
        if (len < 64 or len % 4 != 0 or k > 4 or p + k == 64) continue;
        // Then lines of `len` characters, each followed by the same `k`
        // whitespace characters as this one.
        if (t.len - i < len + k or src.len - i < lineReach(K, len)) continue;
        // In place, not until a line's stores stay behind its start, so
        // that its loads and a restart at it read what the caller passed.
        // Each line moves its start further ahead of its output.
        if (!untouched(dst, src, i, o + lineVectors(K, len) / 4 * 3 + K.slack)) continue;
        const gap = std.mem.readInt(u32, src[i - k ..][0..4], .little) & @as(u32, @truncate(simd.lowBits(u64, 8 * k)));
        o = decodeLines(isa, alphabet, dst, src, t, &i, o, len, k, gap);
        run = i;
    }
    if (t.len - i >= 64) return fromWords(decodeStaged(isa, alphabet, dst, src, t, i, o, last_chunk));
    return decodeLast(isa, alphabet, dst, src, t, i, o, last_chunk);
}

/// The last block, `src[i..t.len]`, fewer than 64 characters, into
/// `dst[o..]`, zero-padded. None, as at a multiple of 64 without padding,
/// is done.
inline fn decodeLast(
    comptime isa: Isa,
    comptime alphabet: Alphabet,
    dst: []u8,
    src: []const u8,
    t: scalar.Trim,
    i: usize,
    o: usize,
    last_chunk: LastChunk,
) Result {
    const options: DecodeOptions = .{ .alphabet = alphabet, .last_chunk = last_chunk };
    const K = Kernel(isa, alphabet);
    const n = t.len - i;
    if (n == 0 and t.padding == 0) return .ok(o);
    const live = simd.lowBits(u64, n);
    const block = simd.loadTail(src, i, t.len);
    if (K.blocks > 1 and n <= 32) {
        // Classify and pack only the first half of the block, one vector
        // on AVX2 and two on SSE and NEON
        // (docs/slop/results/calls-20261031.md).
        const in: [K.blocks]K.V = @bitCast(block);
        var values: [K.blocks / 2]K.V = undefined;
        var classes: [K.blocks / 2]K.V = undefined;
        var bad: u64 = 0;
        inline for (&values, &classes, 0..) |*v, *cl, k| {
            const c = K.classify(in[k]);
            v.* = c.values;
            cl.* = c.classes;
            bad |= @as(u64, simd.bitmask(c.bad)) << (k * K.lanes);
        }
        if (bad & live == 0) {
            if (K.finish(values, n, dst[o..], t, last_chunk)) |len| return .ok(o + len);
            return scalar.decodeFrom(dst, src, t, i, o, options);
        }
        if (K.structured) {
            // Whitespace, as the line break before MIME's last line: in
            // the vectors classified, not the whole block again.
            if (K.finishSpaced(values, classes, n, bad & live, live, dst[o..], t, last_chunk)) |len|
                return .ok(o + len);
            return fromWords(decodeStaged(isa, alphabet, dst, src, t, i, o, last_chunk));
        }
    }
    const c = K.classifyBlock(block);
    const bad = c.badMask() & live;
    if (bad == 0) {
        if (K.finish(c.values, n, dst[o..], t, last_chunk)) |len| return .ok(o + len);
        return scalar.decodeFrom(dst, src, t, i, o, options);
    }
    // Whitespace in it, compressed out in registers.
    if (K.finishSpaced(c.values, c.classes, n, bad, live, dst[o..], t, last_chunk)) |len| return .ok(o + len);
    return fromWords(decodeStaged(isa, alphabet, dst, src, t, i, o, last_chunk));
}

/// Decodes lines of `len` characters from `src[i.*]`, a multiple of four
/// and at least 64, each followed by `k` whitespace characters whose bytes
/// are `gap`, into `dst[o..]`, while the lines are clean and end so; returns
/// the new `o` and leaves `i.*` at the start of the line it stops at.
inline fn decodeLines(
    comptime isa: Isa,
    comptime alphabet: Alphabet,
    dst: []u8,
    src: []const u8,
    t: scalar.Trim,
    i: *usize,
    out: usize,
    len: usize,
    k: usize,
    gap: u32,
) usize {
    const K = Kernel(isa, alphabet);
    const full = len / 64 * 64;
    const rem = len - full;
    const mask: u32 = @truncate(simd.lowBits(u64, 8 * k));
    const reach = lineReach(K, len);
    var o = out;
    lines: while (t.len - i.* >= len + k and src.len - i.* >= reach and dst.len - o >= len / 4 * 3 + 64) {
        const at = i.*;
        var j: usize = 0;
        while (j < full) : (j += 64) {
            const b = K.classifyClean(src[at + j ..][0..64]);
            if (b.anyBad()) break :lines;
            K.packClean(b.values, dst[o + j / 4 * 3 ..][0 .. 48 + K.clean_slack]);
        }
        if (rem != 0) {
            if (K.lanes < 64) {
                // The rest in vectors, not a whole block.
                inline for (0..K.blocks) |v| {
                    if (v * K.lanes < rem) {
                        const in: K.V = src[at + full + v * K.lanes ..][0..K.lanes].*;
                        const cv = K.classify(in);
                        const live = simd.lowBits(@Int(.unsigned, K.lanes), rem - v * K.lanes);
                        if (simd.bitmask(cv.bad) & live != 0) break :lines;
                        K.packOne(cv.values, dst[o + (full + v * K.lanes) / 4 * 3 ..][0 .. K.lanes / 4 * 3 + K.slack]);
                    }
                }
            } else {
                const b = K.classifyClean(src[at + len - 64 ..][0..64]);
                if (b.anyBad()) break;
                K.packClean(b.values, dst[o + (len - 64) / 4 * 3 ..][0 .. 48 + K.clean_slack]);
            }
        }
        if (std.mem.readInt(u32, src[at + len ..][0..4], .little) & mask != gap) break;
        o += len / 4 * 3;
        i.* = at + len + k;
    }
    return o;
}

/// A `Result` as two words, the count in the low half: returned from an
/// out-of-line function, LLVM keeps them in registers, where it returns a
/// `Result` through memory and loads it back whole, which stalls on the
/// two narrower stores that wrote it.
const Words = @Int(.unsigned, 2 * @bitSizeOf(usize));

inline fn toWords(r: Result) Words {
    return @as(Words, compat.enumToInt(r.err)) << @bitSizeOf(usize) | r.count;
}

inline fn fromWords(w: Words) Result {
    return .{
        .err = compat.enumFromInt(
            @TypeOf(@as(Result, undefined).err),
            @as(u8, @truncate(w >> @bitSizeOf(usize))),
        ),
        .count = @truncate(w),
    };
}

/// How far past a line's start `decodeLines` reads: the line, the four
/// bytes after it, and its last vectors past its end.
fn lineReach(comptime K: type, len: usize) usize {
    return @max(len + 4, lineVectors(K, len));
}

/// The characters `decodeLines` decodes of a line: the line, and its last
/// vectors past its end.
fn lineVectors(comptime K: type, len: usize) usize {
    const full = len / 64 * 64;
    return if (K.lanes < 64) full + std.mem.alignForward(usize, len - full, K.lanes) else len;
}

/// Whether `src[i..]` still holds what the caller passed after writes to
/// `dst[0..n]`: `dst` either starts where `src` does, to decode in place,
/// and then the writes must stay behind the reads, or does not overlap it.
inline fn untouched(dst: []const u8, src: []const u8, i: usize, n: usize) bool {
    return dst.ptr != src.ptr or n <= i;
}

/// `decodeWith` from a block at `from` with whitespace it does not decode
/// in lines, or an error, or that `dst` has no room for with the slack,
/// writing from `dst[out]`. Out of line, so that its staging buffer costs
/// no stack frame where there is no such whitespace.
noinline fn decodeStaged(
    comptime isa: Isa,
    comptime alphabet: Alphabet,
    dst: []u8,
    src: []const u8,
    t: scalar.Trim,
    from: usize,
    out: usize,
    last_chunk: LastChunk,
) Words {
    const options: DecodeOptions = .{ .alphabet = alphabet, .last_chunk = last_chunk };
    const K = Kernel(isa, alphabet);
    var i = from;
    var o = out;
    // The 6-bit values of blocks with whitespace, compressed, not yet
    // decoded, in the ring `K.stagePut` and `K.stageGet` keep: `w` values
    // staged, the first `r` of them, whole blocks, decoded.
    var stage: [K.stage_len]u8 align(64) = undefined;
    var w: usize = 0;
    var r: usize = 0;
    // From the first with whitespace, all go through `stage`. A staged
    // block is decoded once `K.lag` more values follow it: its load
    // straddles the stores that wrote it, and would wait for them to reach
    // the cache.
    while (t.len - i >= 64 and dst.len - o >= 48 * ((w - r) / 64 + 1) + K.slack) {
        const block = src[i..][0..64];
        const c = K.classifyBlock(block);
        var space: u64 = 0;
        if (c.anyBad()) {
            space = c.spaceMask();
            if (c.badMask() & ~space != 0) break;
        }
        K.stagePut(&stage, w, c.values, space);
        w += 64 - @popCount(space);
        i += 64;
        if (w - r >= 64 + K.lag) {
            K.packBlock(K.stageGet(&stage, r), dst[o..][0 .. 48 + K.slack]);
            r += 64;
            o += 48;
        }
    }

    // A block without whitespace that fits only without the slack.
    if (w == 0 and t.len - i >= 64 and dst.len - o >= 48) {
        const c = K.classifyBlock(src[i..][0..64]);
        if (!c.anyBad()) {
            simd.storePartial(dst[o..], K.packAll(c.values), 48);
            i += 64;
            o += 48;
        }
    }
    // The input from `end` on is not yet staged or decoded.
    var end = i;
    if (t.len - i < 64) {
        // The last block, fewer than 64 characters, zero-padded.
        const n = t.len - i;
        const live = simd.lowBits(u64, n);
        const block = simd.loadTail(src, i, t.len);
        const c = K.classifyBlock(block);
        const bad = c.badMask() & live;
        if (bad == 0 and w == 0) {
            if (K.finish(c.values, n, dst[o..], t, last_chunk)) |len| return toWords(.ok(o + len));
            return toWords(scalar.decodeFrom(dst, src, t, i, o, options));
        }
        if (w == 0) {
            if (K.finishSpaced(c.values, c.classes, n, bad, live, dst[o..], t, last_chunk)) |len|
                return toWords(.ok(o + len));
        }
        const space = if (bad == 0) 0 else c.spaceMask() & live;
        if (bad & ~space == 0) {
            K.stagePut(&stage, w, c.values, space);
            w += n - @popCount(space);
            end = t.len;
        }
    }

    // Decode the staged blocks that fit, and the last one if the input is
    // all staged. Otherwise hand the scalar decoder the input from the
    // first value still undecoded.
    while (w - r >= 64 and dst.len - o >= 48) : (r += 64) {
        const values = K.stageGet(&stage, r);
        if (dst.len - o >= 48 + K.slack) {
            K.packBlock(values, dst[o..][0 .. 48 + K.slack]);
        } else {
            simd.storePartial(dst[o..], K.packAll(values), 48);
        }
        o += 48;
    }
    if (end == t.len and w - r < 64) {
        if (K.finish(K.stageGet(&stage, r), w - r, dst[o..], t, last_chunk)) |len| return toWords(.ok(o + len));
    }
    var start = end;
    var keep = w - r;
    while (keep > 0) {
        start -= 1;
        if (!scalar.isSpace(src[start])) keep -= 1;
    }
    return toWords(scalar.decodeFrom(dst, src, t, start, o, options));
}

/// `encodedLen(n, .{ .padding = padding })`, whose options struct LLVM
/// leaves in memory, on the critical path of short encodes.
inline fn charsFor(n: usize, padding: bool) usize {
    return if (padding) (n + 2) / 3 * 4 else (n * 4 + 2) / 3;
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
            const in = simd.loadVolatile(V, src);
            return translate(@shuffle(u8, in, undefined, spreadMask(!avx512, 0)), mul);
        }

        /// NEON's structured loads and stores, as simdutf's arm64 kernel
        /// uses them: `ld3` puts the first, second, and third byte of each
        /// group in a vector of their own and `st4` interleaves four
        /// vectors of characters, and for decode `ld4` and `st3` the
        /// reverse, so that the bits move with shifts within lanes and no
        /// shuffle. LLVM makes them from a whole load or store and strided
        /// shuffles of it.
        const structured = isa == .neon;

        /// Encodes 48 bytes into 64 characters.
        inline fn encodeStructured(src: *const [48]u8, out: *[64]u8) void {
            const in = @as(*align(1) const @Vector(48, u8), @ptrCast(src)).*;
            const a = @shuffle(u8, in, undefined, strided(3, 0));
            const b = @shuffle(u8, in, undefined, strided(3, 1));
            const c = @shuffle(u8, in, undefined, strided(3, 2));
            const m = splat(0x3f);
            // `ushr` and `sli`, as simdutf has them, not the `shl` and
            // `usra` LLVM makes from shifts and ors: 5% faster from 4 KiB
            // (docs/slop/results/neon-base64-20261101.md).
            const sli = @"llvm.aarch64.neon.vsli.v16i8";
            const r0 = lookup64(a >> @splat(2));
            const r1 = lookup64(sli(b >> @splat(4), a, 4) & m);
            const r2 = lookup64(sli(c >> @splat(6), b, 2) & m);
            const r3 = lookup64(c & m);
            const all = std.simd.join(std.simd.join(r0, r1), std.simd.join(r2, r3));
            @as(*align(1) V64, @ptrCast(out)).* = @shuffle(u8, all, undefined, blk: {
                var s: [64]i32 = undefined;
                for (&s, 0..) |*x, j| x.* = j % 4 * 16 + j / 4;
                break :blk s;
            });
        }

        /// Each index's character: one `tbl` from four table registers.
        inline fn lookup64(idx: V) V {
            const t: [4]V = @bitCast(chars.*);
            return @"llvm.aarch64.neon.tbl4.v16i8"(t[0], t[1], t[2], t[3], idx);
        }

        /// Lane `j` is lane `j * n + k` of a vector of `16 * n`.
        fn strided(comptime n: usize, comptime k: usize) [16]i32 {
            var m: [16]i32 = undefined;
            for (&m, 0..) |*x, j| x.* = j * n + k;
            return m;
        }

        /// Classifies a block known or likely to be clean, for
        /// `packClean`: on NEON its values come four characters apart, the
        /// first of each chunk in `values[0]`, so `badMask` and
        /// `spaceMask` do not give positions.
        inline fn classifyClean(src: *const [64]u8) Block {
            if (!structured) return classifyBlock(src);
            const in = simd.load(u8, src);
            var b: Block = undefined;
            inline for (0..blocks) |k| {
                const x = @shuffle(u8, in, undefined, strided(4, k));
                // simdutf's arm64 classifier: one class bit per rectangle
                // of the alphabet, by the low nibble and the byte over 8,
                // and the leading zeros of the class pick the offset, where
                // `classify` makes the roll slot with a compare and an add.
                const class = simd.lookup16(clean.lo, x & splat(0x0f)) & simd.lookup16(clean.hi, x >> @splat(3));
                b.values[k] = x +% simd.lookup16(clean.roll, @as(V, @clz(class)));
                b.bad[k] = class <= splat(1);
            }
            return b;
        }

        /// `classifyClean`'s tables, simdutf's: a character's class is
        /// `lo[c & 15] & hi[c >> 3]` (an index from 16 looks up 0), none
        /// outside the alphabet, bit 0 alone for whitespace, and its value
        /// is `c + roll[@clz(class)]`.
        const CleanTables = struct { lo: [16]u8, hi: [16]u8, roll: [16]u8 };
        const clean: CleanTables = blk: {
            const t: CleanTables = switch (alphabet) {
                .standard => .{
                    .lo = .{
                        0xa9, 0xf8, 0xf8, 0xf8, 0xf8, 0xf8, 0xf8, 0xf8,
                        0xf8, 0xf9, 0xf1, 0xa2, 0xa1, 0xa1, 0xa0, 0xa4,
                    },
                    .hi = .{
                        0x00, 0x01, 0x00, 0x00, 0x01, 0x06, 0x08, 0x08,
                        0x10, 0x20, 0x20, 0x10, 0x40, 0x80, 0x80, 0x40,
                    },
                    .roll = .{ 0xb9, 0xb9, 0xbf, 0xbf, 0x04, 0x10, 0x13, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
                },
                .url => .{
                    .lo = .{
                        0xa9, 0xf8, 0xf8, 0xf8, 0xf8, 0xf8, 0xf8, 0xf8,
                        0xf8, 0xf9, 0xf1, 0xa0, 0xa1, 0xa5, 0xa0, 0xa2,
                    },
                    .hi = .{
                        0x00, 0x01, 0x00, 0x00, 0x01, 0x04, 0x08, 0x08,
                        0x10, 0x20, 0x20, 0x12, 0x40, 0x80, 0x80, 0x40,
                    },
                    .roll = .{ 0xb9, 0xb9, 0xbf, 0xbf, 0x04, 0x11, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
                },
            };
            // Every byte checked: in the alphabet, a class above 1 and its
            // value; outside it, 0 or 1.
            @setEvalBranchQuota(20000);
            for (0..256) |c| {
                const class = if (c >> 3 < 16) t.lo[c & 15] & t.hi[c >> 3] else 0;
                const v = std.mem.findScalar(u8, chars, c);
                if ((class > 1) != (v != null)) @compileError("bad clean class");
                if (v) |value| {
                    if (@as(u8, c) +% t.roll[@clz(class)] != value) @compileError("bad clean roll");
                }
            }
            break :blk t;
        };

        /// How many bytes past its 48 `packClean` writes: none with `st3`,
        /// so that a block that fills `dst` exactly, as the only one of 64
        /// characters does, need not go through `decodeStaged`.
        const clean_slack = if (structured) 0 else slack;

        /// `packBlock` for the values of `classifyClean`.
        inline fn packClean(values: [blocks]V, out: *[48 + clean_slack]u8) void {
            if (!structured) return packBlock(values, out);
            const a, const b, const c, const d = values;
            // `sli` shifts its second operand left and inserts it above the
            // bits the shift left free: 5 instructions where LLVM made 8
            // from the shifts and ors.
            const sli = @"llvm.aarch64.neon.vsli.v16i8";
            const o0 = sli(b >> @splat(4), a, 2);
            const o1 = sli(c >> @splat(2), b, 4);
            const o2 = sli(d, c, 6);
            @as(*align(1) @Vector(48, u8), @ptrCast(out)).* = @shuffle(u8, std.simd.join(o0, o1), o2, blk: {
                var s: [48]i32 = undefined;
                for (&s, 0..) |*x, j| x.* = if (j % 3 == 2) ~@as(i32, j / 3) else j % 3 * 16 + j / 3;
                break :blk s;
            });
        }

        /// Encodes the top 48 bytes of `src`.
        inline fn encodeTop(src: *const [64]u8) [64]u8 {
            const in = simd.loadVolatile(V, src);
            const top = comptime blk: {
                var m = spreadMask(false, 0);
                for (&m) |*x| x.* += 16;
                break :blk m;
            };
            return translate(@shuffle(u8, in, undefined, top), undefined);
        }

        /// Encodes `whole[start..end]`, at most 48 bytes, writing only
        /// its `encodedLen` characters.
        inline fn encodeLast(dst: []u8, whole: []const u8, start: usize, end: usize, padding: bool) usize {
            if (avx512) {
                const n = end - start;
                const len = charsFor(n, padding);
                if (n == 0) return 0;
                const spread: V64 = comptime blk: {
                    var v: [64]u8 = undefined;
                    for (spreadMask(false, 0), &v) |x, *y| y.* = x;
                    break :blk v;
                };
                // From a whole block before `end`, the one ending there:
                // the spread shuffle moves it down and zeroes the bytes past
                // the data, one `vpermb` where `loadTail` adds another.
                // Without one, the data zero-padded from one masked load,
                // which the spread shuffle reads as it is.
                const in = if (end >= 64) blk: {
                    const off: V64 = @splat(@intCast(64 - n));
                    const moved = simd.permute(simd.load(u8, whole[end - 64 ..]), spread +% off);
                    break :blk @select(u8, spread < @as(V64, @splat(@intCast(n))), moved, @as(V64, @splat(0)));
                } else simd.permute(simd.loadShort(u8, whole[start..end]), spread);
                return storeLast(dst, translate(in, undefined), n, len);
            }
            const src = whole[start..end];
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
            const len = charsFor(r, padding);
            // Up to two groups and a partial one, the scalar code inline is
            // faster.
            if (r <= 7) return o + scalar.encodeChars(dst[o..], src[i..], chars, padding);
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
            simd.storePartial(dst, @select(u8, pad, @as(@TypeOf(out), @splat('=')), out), len);
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
                return simd.permute(chars.*, simd.multishift(shifts, spread));
            }
            // Pull the four 6-bit indices into the low bits of each byte:
            // a>>2 and the low 6 bits of c with shifts within 16-bit
            // lanes, the two in the middle across them. The shifts are
            // multiplies, as the paper has them: one instruction each on
            // x86, where shifts by lane need two and a blend.
            const W = @Vector(lanes / 2, u16);
            const w: W = @bitCast(spread);
            if (structured) {
                // NEON shifts each lane by its own count, and looks the
                // indices up in the whole alphabet at once.
                const S = @Vector(lanes / 2, u4);
                const hi = (w & rep(W, .{ 0xfc00, 0x0fc0 })) >> rep(S, .{ 10, 6 });
                const lo = (w & rep(W, .{ 0x03f0, 0x003f })) << rep(S, .{ 4, 8 });
                return lookup64(@bitCast(if (big) @byteSwap(hi | lo) else hi | lo));
            }
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
            const table: [16]u8 = .{ 'A', o_lower } ++ comptime compat.repeat(u8, o_digit, 10) ++ .{ o_62, o_63, 0, 0 };
            return simd.lookup16(table, reduced);
        }

        /// `classes` says which characters are whitespace: with the nibble
        /// tables, through their whitespace bits, and otherwise it is the
        /// input, for `isSpace`.
        const Classified = struct { values: V, bad: @Vector(lanes, bool), classes: V };
        const nibbles = isa == .ssse3 or isa == .avx2 or isa == .neon;

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
                const v = simd.permute2(@as(V64, table[0..64].*), in, table[64..].*);
                return .{ .values = v, .bad = (v | in) >= splat(0x80), .classes = in };
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
                return .{ .values = v, .bad = !good, .classes = in };
            }
            const hi = in >> @splat(4);
            const lo = in & splat(0x0f);
            const classes = simd.lookup16(tables.lo, lo) & simd.lookup16(tables.hi, hi);
            // The character whose offset differs from the rest of its high
            // nibble's takes a slot of its own: the one below, when that
            // nibble has no characters, with one instruction, or one above 7.
            const special = in == splat(tables.special);
            const I = @Vector(lanes, i8);
            // On NEON, hidden from LLVM, which would fold the shift into
            // the add as a `usra`, redoing the shift the lookup has done:
            // decode was 2.5% slower so
            // (docs/slop/results/neon-base64-20261101.md).
            const h = if (structured) asm (""
                : [ret] "=w" (-> V),
                : [hi] "0" (hi),
            ) else hi;
            const slot = if (tables.below)
                h +% @as(V, @bitCast(@select(i8, special, @as(I, @splat(-1)), @as(I, @splat(0)))))
            else
                h | @select(u8, special, splat(8), splat(0));
            const values = in +% simd.lookup16(tables.roll, slot);
            return .{ .values = values, .bad = classes != splat(0), .classes = classes };
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

        /// Bit k is set when character k of the vectors whose `classes`
        /// these are is ASCII whitespace.
        inline fn spaceBits(classes: anytype) u64 {
            var m: u64 = 0;
            inline for (classes, 0..) |c, k| {
                const space = if (nibbles) c & splat(tables.space) != splat(0) else isSpace(c);
                m |= @as(u64, simd.bitmask(space)) << (k * lanes);
            }
            return m;
        }

        const Block = struct {
            values: [blocks]V,
            bad: [blocks]@Vector(lanes, bool),
            classes: [blocks]V,

            /// Bit k is set when character k is ASCII whitespace.
            inline fn spaceMask(b: Block) u64 {
                return spaceBits(b.classes);
            }

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
                b.classes[k] = c.classes;
            }
            return b;
        }

        /// How many bytes past its 48 `packBlock` writes: each vector is
        /// stored whole.
        const slack = lanes / 4;

        /// Turns 64 6-bit values into 48 bytes, and writes `slack` more.
        inline fn packBlock(values: [blocks]V, out: *[48 + slack]u8) void {
            // Whole vectors, each overwriting the slack of the one before.
            inline for (0..blocks) |k| packOne(values[k], out[k * lanes / 4 * 3 ..][0 .. lanes / 4 * 3 + slack]);
        }

        /// Turns one vector of 6-bit values into `lanes / 4 * 3` bytes,
        /// and writes `slack` more.
        inline fn packOne(values: V, out: *[lanes / 4 * 3 + slack]u8) void {
            // The stores are volatile so that LLVM keeps them whole: it
            // would merge them with more shuffles than it saves.
            if (isa == .avx2) {
                // Each 16-byte half from its own store, which saves the
                // shuffle across halves, a shuffle-port instruction.
                const halves: [2]@Vector(16, u8) = @bitCast(@shuffle(u8, packWords(values), undefined, blk: {
                    // The lanes left over stay in their half too.
                    var m: [lanes]i32 = std.simd.iota(i32, lanes);
                    for (0..lanes / 4) |g| m[g / 4 * 16 + g % 4 * 3 ..][0..3].* = .{ g * 4 + 2, g * 4 + 1, g * 4 };
                    break :blk m;
                }));
                inline for (halves, 0..) |h, j| simd.storeVolatile(out[j * 12 ..], h);
            } else {
                simd.storeVolatile(out, pack(values));
            }
        }

        /// Turns the 6-bit values of an array of vectors into bytes, each
        /// four into three, in the first three quarters of the result.
        inline fn packAll(values: anytype) @Vector(@sizeOf(@TypeOf(values)), u8) {
            const k = values.len;
            const W = @Vector(k * lanes, u8);
            var p: [k]V = undefined;
            inline for (0..k) |j| p[j] = pack(values[j]);
            if (k == 1) return @bitCast(p);
            return @shuffle(u8, @as(W, @bitCast(p)), undefined, blk: {
                var m: [k * lanes]i32 = @splat(0);
                for (0..k * lanes / 4 * 3) |j| m[j] = j / (lanes / 4 * 3) * lanes + j % (lanes / 4 * 3);
                break :blk m;
            });
        }

        /// Decodes the last `count` values, fewer than 64, by the last-chunk
        /// rules, into `dst`, and returns the number of bytes written. Null
        /// when the scalar decoder must finish: at an error, at a partial
        /// chunk the rules leave to it, or when `dst` is too small.
        inline fn finish(values: anytype, count: usize, dst: []u8, t: scalar.Trim, last: LastChunk) ?usize {
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
            // A block, or the vectors of one that hold all `count` values.
            const w = @sizeOf(@TypeOf(values));
            const W = @Vector(w, u8);
            // Zeros past the data, so that a partial chunk decodes with zero
            // bits after it, and the byte after its data holds its extra bits.
            const live = std.simd.iota(u8, w) < @as(W, @splat(@intCast(count)));
            const kept = @select(u8, live, @as(W, @bitCast(values)), @as(W, @splat(0)));
            const out = packAll(@as([w / lanes]V, @bitCast(kept)));
            // In a vector: reading byte `len` stored `out` to the stack.
            const at_len = std.simd.iota(u8, w) == @as(W, @splat(@intCast(len)));
            const zero: W = @splat(0);
            if (last == .strict and tail != 0 and @reduce(.Or, @select(u8, at_len, out, zero) != zero)) return null;
            simd.storePartial(dst, out, len);
            return len;
        }

        /// `finish` for the last block, of `n` characters, where `bad`
        /// marks those outside the alphabet: when they are all whitespace
        /// that `compressVec` removes, decodes the rest. Null where
        /// `finish` is, or when they are not.
        inline fn finishSpaced(
            values: anytype,
            classes: @TypeOf(values),
            n: usize,
            bad: u64,
            live: u64,
            dst: []u8,
            t: scalar.Trim,
            last: LastChunk,
        ) ?usize {
            const space = spaceBits(classes) & live;
            if (bad & ~space != 0) return null;
            const v = compressVec(values, space) orelse return null;
            return finish(v, n - @popCount(space), dst, t, last);
        }

        /// The staging ring: 512 values at `stage[64..]`, with 64 bytes
        /// before it, where a store that runs past its end is written again
        /// 512 bytes earlier, and 72 after it for `compressMem`'s overflow.
        const ring = 512;
        const stage_len = 64 + ring + 72;
        /// How many values follow a staged block before it is decoded.
        /// At most `64 + lag` values are pending before a put, so what a put
        /// writes past the ring's end, its overflow included, lands on
        /// values already decoded.
        const lag = 256;
        comptime {
            std.debug.assert(64 + lag + 72 <= ring - 64);
        }

        /// Stages the values of `values` not in `space` at ring position
        /// `w`, and may write the ring up to 64 positions past them.
        inline fn stagePut(stage: *[stage_len]u8, w: usize, values: [blocks]V, space: u64) void {
            const p = 64 + w % ring;
            const v: V64 = if (space == 0) @bitCast(values) else compressVec(values, space) orelse {
                compressMem(values, space, stage[p..][0..72]);
                if (p + 72 > 64 + ring) stage[64..][0..72].* = stage[64 + ring ..][0..72].*;
                return;
            };
            // Volatile, so that LLVM keeps each store whole.
            simd.storeVolatile(stage[p..], v);
            if (p > ring) simd.storeVolatile(stage[p - ring ..], v);
        }

        /// The staged block at ring position `r`, a multiple of 64.
        inline fn stageGet(stage: *const [stage_len]u8, r: usize) [blocks]V {
            // Through an unaligned vector pointer: Debug builds bitcast the
            // array in place as the 64-byte-aligned result, which faults.
            return @bitCast(@as(*align(1) const V64, @ptrCast(stage[64 + r % ring ..][0..64])).*);
        }

        /// The bytes of `values` not in `space`, at the front, when that
        /// takes a few vector instructions.
        inline fn compressVec(values: anytype, space: u64) ?@Vector(@sizeOf(@TypeOf(values)), u8) {
            if (avx512 and simd.has_vbmi2) {
                return simd.compress(values[0], ~space);
            }
            // Line breaks put one or two whitespace characters in most
            // blocks: remove each by shifting what follows it down a lane,
            // the last first, or a CR LF pair two lanes at once.
            if (@popCount(space) <= 2) {
                if (space & (space >> 1) != 0) return @bitCast(shiftFrom(values, @ctz(space), 2));
                var v = values;
                var rest = space;
                while (rest != 0) {
                    const pos: u8 = 63 - @clz(rest);
                    rest &= ~(@as(u64, 1) << @intCast(pos));
                    v = shiftFrom(v, pos, 1);
                }
                return @bitCast(v);
            }
            return null;
        }

        /// `values` with the lanes from `pos` on taken from `by` lanes
        /// later.
        inline fn shiftFrom(values: anytype, pos: usize, comptime by: usize) @TypeOf(values) {
            var v = values;
            inline for (0..values.len) |k| {
                const next = if (k + 1 < values.len) values[k + 1] else values[k];
                const shifted = @shuffle(u8, values[k], next, blk: {
                    var m: [lanes]i32 = undefined;
                    for (&m, 0..) |*x, j| x.* = if (j + by < lanes) j + by else ~@as(i32, j + by - lanes);
                    break :blk m;
                });
                // Lanes from `pos` on, from a load instead of a compare
                // with a broadcast, which take the shuffle port.
                const from: V = shift_masks[64 - pos + k * lanes ..][0..lanes].*;
                v[k] = @select(u8, from == splat(0xff), shifted, values[k]);
            }
            return v;
        }

        /// Copies the bytes of `values` not in `space` to the front of
        /// `out`. It may write all of `out`.
        inline fn compressMem(values: [blocks]V, space: u64, out: *[72]u8) void {
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
            // Each 32-bit lane holds its three bytes in its low 24 bits.
            return @shuffle(u8, packWords(values), undefined, blk: {
                var m: [lanes]i32 = @splat(0);
                for (0..lanes / 4) |g| m[g * 3 ..][0..3].* = if (big)
                    .{ g * 4 + 1, g * 4 + 2, g * 4 + 3 }
                else
                    .{ g * 4 + 2, g * 4 + 1, g * 4 };
                break :blk m;
            });
        }

        /// Turns each four 6-bit values into three bytes, in the low 24 bits
        /// of their 32-bit lane, the first byte highest.
        inline fn packWords(values: V) V {
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
                // Pairs a:b into a*64 + b in 16-bit lanes, then those in
                // 32-bit lanes, each with a shift each way: 8 instructions
                // where the generic form below takes 10.
                .neon => if (!big) blk: {
                    const H = @Vector(lanes / 2, u16);
                    const h: H = @bitCast(values);
                    const p: D = @bitCast((h >> @splat(8)) | ((h << @splat(8)) >> @splat(2)));
                    break :blk (p >> @splat(16)) | ((p << @splat(16)) >> @splat(4));
                } else packWordsGeneric(values),
                .generic => packWordsGeneric(values),
            };
            return @bitCast(w);
        }

        /// `packWords` in plain shifts and masks.
        inline fn packWordsGeneric(values: V) @Vector(lanes / 4, u32) {
            const D = @Vector(lanes / 4, u32);
            const x: D = @bitCast(values);
            // The four values are the bytes of x, the first lowest on
            // little-endian targets and highest on big-endian ones.
            return if (big)
                ((x >> @splat(6)) & rep(D, .{0xfc0000})) |
                    ((x >> @splat(4)) & rep(D, .{0x3f000})) |
                    ((x >> @splat(2)) & rep(D, .{0xfc0})) |
                    (x & rep(D, .{0x3f}))
            else
                ((x & rep(D, .{0x3f})) << @splat(18)) |
                    ((x & rep(D, .{0x3f00})) << @splat(4)) |
                    ((x >> @splat(10)) & rep(D, .{0xfc0})) |
                    (x >> @splat(24));
        }

        const tables = decodeTables(alphabet);
    };
}

/// Lookup tables for the nibble classification: `lo[c & 15] & hi[c >> 4]`
/// is nonzero exactly for the bytes outside the alphabet, and has a bit of
/// `space` exactly for ASCII whitespace; `c + roll[c >> 4]` is the value of
/// an alphabet character other than `special`, whose offset is at
/// `roll[(special >> 4) | 8]`.
fn decodeTables(comptime alphabet: Alphabet) struct {
    lo: [16]u8,
    hi: [16]u8,
    roll: [16]u8,
    special: u8,
    space: u8,
    below: bool,
} {
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
    // Two bits of their own: tab, LF, FF, and CR, then space.
    if (n_sets > 6) @compileError("too many nibble classes");
    hi[0] |= 0x40;
    for ("\t\n\x0c\r") |c| lo[c] |= 0x40;
    hi[2] |= 0x80;
    lo[0] |= 0x80;
    var roll: [16]u8 = @splat(0);
    var seen: [16]bool = @splat(false);
    const below = for (chars) |c| {
        if (c >> 4 == (special >> 4) - 1) break false;
    } else true;
    for (chars, 0..) |c, v| {
        const slot = if (c != special) c >> 4 else if (below) (c >> 4) - 1 else (c >> 4) | 8;
        const off: u8 = @as(u8, v) -% c;
        if (seen[slot] and roll[slot] != off) @compileError("two offsets for one high nibble");
        roll[slot] = off;
        seen[slot] = true;
    }
    return .{ .lo = lo, .hi = hi, .roll = roll, .special = special, .space = 0xc0, .below = below };
}

/// 64 zeros, then 64 bytes of 0xff: the lanes of a block from position p on
/// are the 64 bytes from `64 - p`.
const shift_masks: [128]u8 = @as([64]u8, @splat(0)) ++ @as([64]u8, @splat(0xff));

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
        @setEvalBranchQuota(10_000);
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

extern fn @"llvm.x86.ssse3.pmadd.ub.sw.128"(@Vector(16, u8), @Vector(16, u8)) callconv(simd.llvm_cc) @Vector(8, i16);
extern fn @"llvm.x86.avx2.pmadd.ub.sw"(@Vector(32, u8), @Vector(32, u8)) callconv(simd.llvm_cc) @Vector(16, i16);
extern fn @"llvm.x86.sse2.pmadd.wd"(@Vector(8, i16), @Vector(8, i16)) callconv(simd.llvm_cc) @Vector(4, i32);
extern fn @"llvm.x86.avx2.pmadd.wd"(@Vector(16, i16), @Vector(16, i16)) callconv(simd.llvm_cc) @Vector(8, i32);
extern fn @"llvm.x86.sse2.pmulhu.w"(@Vector(8, u16), @Vector(8, u16)) callconv(simd.llvm_cc) @Vector(8, u16);
extern fn @"llvm.x86.avx2.pmulhu.w"(@Vector(16, u16), @Vector(16, u16)) callconv(simd.llvm_cc) @Vector(16, u16);
extern fn @"llvm.x86.avx512.pmaddubs.w.512"(@Vector(64, u8), @Vector(64, u8)) callconv(simd.llvm_cc) @Vector(32, i16);
extern fn @"llvm.x86.avx512.pmaddw.d.512"(@Vector(32, i16), @Vector(32, i16)) callconv(simd.llvm_cc) @Vector(16, i32);
const V16 = @Vector(16, u8);
extern fn @"llvm.aarch64.neon.vsli.v16i8"(V16, V16, i32) callconv(simd.llvm_cc) V16;
extern fn @"llvm.aarch64.neon.tbl4.v16i8"(V16, V16, V16, V16, V16) callconv(simd.llvm_cc) V16;

const test_isas = blk: {
    var isas: []const Isa = &.{};
    for (std.enums.values(Isa)) |isa| {
        if (isa.supported()) isas = isas ++ .{isa};
    }
    break :blk isas;
};

const all_last_chunks = std.enums.values(LastChunk);

/// Decodes `src` with every kernel, into a buffer of its own and in place,
/// and expects the scalar reference's result and bytes.
fn expectSameDecode(dst_len: usize, src: []const u8, options: DecodeOptions) !void {
    var want_buf: [2400]u8 = undefined;
    var got_buf: [2400]u8 = undefined;
    var in_place: [3200]u8 = undefined;
    const want = scalar.decode(want_buf[0..dst_len], src, options);
    inline for (test_isas) |isa| {
        @memcpy(in_place[0..src.len], src);
        const dsts = [_][]u8{ got_buf[0..dst_len], in_place[0..dst_len] };
        const srcs = [_][]const u8{ src, in_place[0..src.len] };
        for (dsts, srcs) |dst, s| {
            const got = switch (options.alphabet) {
                inline else => |a| decodeWith(isa, a, dst, s, options.last_chunk),
            };
            const same = std.meta.eql(want, got) and
                (want.err != .none or std.mem.eql(u8, want_buf[0..want.count], dst[0..got.count]));
            if (!same) {
                const where = if (dst.ptr == s.ptr) " in place" else "";
                const fmt = "{t}{s} {any} dst_len={d} src=\"{f}\"\n";
                std.debug.print(fmt, .{ isa, where, options, dst_len, std.zig.fmtString(src) });
            }
            try testing.expectEqual(want, got);
            if (want.err == .none) try testing.expectEqualSlices(u8, want_buf[0..want.count], dst[0..got.count]);
        }
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

test "every kernel decodes regular lines, with a fault in any line" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const rand = prng.random();
    var raw: [1200]u8 = undefined;
    var enc: [1600]u8 = undefined;
    var text: [2300]u8 = undefined;
    // Widths that decode in lines, at one block and between two and four,
    // and one that does not.
    for ([_]usize{ 64, 68, 76, 100, 128, 132, 200, 62 }) |width| {
        for ([_][]const u8{ "\n", "\r\n", " ", "\r\n\t\t", "\n\n\n\n\n" }) |gap| {
            for (0..12) |_| {
                const n = rand.uintLessThan(usize, raw.len);
                rand.bytes(raw[0..n]);
                const alphabet = randomAlphabet(rand);
                const len = scalar.encode(&enc, raw[0..n], .{ .alphabet = alphabet, .padding = rand.boolean() });
                var m: usize = 0;
                for (enc[0..len], 1..) |c, j| {
                    text[m] = c;
                    m += 1;
                    if (j % width == 0) {
                        @memcpy(text[m..][0..gap.len], gap);
                        m += gap.len;
                    }
                }
                const options: DecodeOptions = .{ .alphabet = alphabet, .last_chunk = rand.enumValue(LastChunk) };
                try expectSameDecode(maxDecodedLen(m), text[0..m], options);
                try expectSameDecode(rand.uintAtMost(usize, maxDecodedLen(m)), text[0..m], options);
                if (m == 0) continue;
                // One fault, anywhere or around a line's end: another
                // byte, a character where whitespace was, whitespace in a
                // line, or `=`.
                const line_end = (rand.uintLessThan(usize, len / width + 1) + 1) * (width + gap.len) - gap.len;
                const near = @min(m - 1, line_end + rand.uintLessThan(usize, gap.len + 2) -| 1);
                const at = if (rand.boolean()) rand.uintLessThan(usize, m) else near;
                const saved = text[at];
                for ([_]u8{ rand.int(u8), 'A', ' ', '=' }) |b| {
                    text[at] = b;
                    try expectSameDecode(maxDecodedLen(m), text[0..m], options);
                }
                text[at] = saved;
            }
        }
    }
}

/// Random inputs through `encode` and `decode`, on whichever kernels they
/// dispatch to, against the scalar reference: every length to 400 bytes,
/// clean, in MIME lines, and with a byte replaced, with room to spare and
/// with exactly the room the result needs, into a buffer of its own and in
/// place.
fn publicCases(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();
    var raw: [400]u8 = undefined;
    var want: [560]u8 = undefined;
    var got: [560]u8 = undefined;
    var lines: [600]u8 = undefined;
    var want_out: [600]u8 = undefined;
    var got_out: [600]u8 = undefined;
    for (0..raw.len) |n| {
        rand.bytes(raw[0..n]);
        const eo: EncodeOptions = .{ .alphabet = randomAlphabet(rand), .padding = rand.boolean() };
        const len = scalar.encode(&want, raw[0..n], eo);
        try testing.expectEqual(len, encode(got[0..len], raw[0..n], eo));
        try testing.expectEqualStrings(want[0..len], got[0..len]);
        // Lines of 76 characters, as MIME writes them.
        var m: usize = 0;
        for (want[0..len], 1..) |c, k| {
            lines[m] = c;
            m += 1;
            if (k % 76 == 0) {
                lines[m] = if (rand.boolean()) '\n' else ' ';
                m += 1;
            }
        }
        for ([_][]u8{ want[0..len], lines[0..m] }) |text| {
            for (0..2) |mutate| {
                const at = if (mutate == 1 and text.len > 0) rand.uintLessThan(usize, text.len) else 0;
                const saved = if (text.len > 0) text[at] else 0;
                if (mutate == 1 and text.len > 0) text[at] = rand.int(u8);
                const options: DecodeOptions = .{ .alphabet = eo.alphabet, .last_chunk = rand.enumValue(LastChunk) };
                const r = scalar.decode(&want_out, text, options);
                const exact = if (r.err == .none) r.count else maxDecodedLen(text.len);
                for ([_]usize{ maxDecodedLen(text.len), exact }) |room| {
                    const g = decode(got_out[0..room], text, options);
                    try testing.expectEqual(r, g);
                    if (r.err == .none) try testing.expectEqualSlices(u8, want_out[0..r.count], got_out[0..g.count]);
                    @memcpy(got_out[0..text.len], text);
                    const p = decode(got_out[0..room], got_out[0..text.len], options);
                    try testing.expectEqual(r, p);
                    if (r.err == .none) try testing.expectEqualSlices(u8, want_out[0..r.count], got_out[0..p.count]);
                }
                if (text.len > 0) text[at] = saved;
            }
        }
    }
}

test "encode and decode match the scalar reference on every tier" {
    try dispatch.forEachLevel(publicCases, .{testing.random_seed});
}
