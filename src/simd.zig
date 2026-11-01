//! Shared vector helpers and the instruction set chosen at comptime.
//!
//! Every algorithm works on 64-byte blocks, `Block(T)`, on every ISA: four
//! 16-byte registers on SSE, NEON, and the generic path, two on AVX2, one on
//! AVX-512. The block code is the same everywhere; LLVM splits a 64-byte
//! vector into the target's registers, and only the operations with no
//! portable form, like `lookup16`, pick an instruction per ISA.
//!
//! The helpers, by what they do:
//! - Loads: `load` (a block, unaligned), `loadAligned`, `load16`,
//!   `loadVolatile` (kept whole), and for less than a block, zero-padded,
//!   without reading past the input, `loadPartial` (in registers, any ISA),
//!   `loadShort` (one masked load on AVX-512), and `loadTail` (the block
//!   ending at the input's end, moved down; for input ends that an output
//!   may have just been written after). `toBoundary` finds the first
//!   aligned block.
//! - Stores: `storeVolatile` (kept whole: LLVM splits an AVX-512 store it
//!   cannot prove aligned) and `storePartial` (the first `n` lanes, writing
//!   nothing past them; masked on AVX-512 only within a page).
//! - Lanes: `lookup16` (`pshufb`/`tbl`), `prev`, `bitmask`, `lowBits`
//!   (`bzhi`), `narrow` (`packusdw`/`packuswb`), and on AVX-512 `compress`
//!   (`vpcompressb/w/d`), `permute` (`vpermb`), `permute2` (`vpermi2b/d`),
//!   `multishift` (`vpmultishiftqb`), with BMI2's `pext` and `pdep`.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const x86 = std.Target.x86;
const compat = @import("compat.zig");

pub const Isa = enum { avx512, avx2, sse, neon, generic };

/// The widest vector instruction set the target CPU has, from `-Dcpu`.
pub const isa: Isa = isaOf(builtin.cpu);

/// The widest vector instruction set `cpu` has. build.zig uses it too, to
/// pick the kernels `dispatch.zig` adds at runtime.
pub fn isaOf(cpu: std.Target.Cpu) Isa {
    return switch (cpu.arch) {
        .x86, .x86_64 => if (x86.featureSetHas(cpu.features, .avx512bw))
            .avx512
        else if (x86.featureSetHas(cpu.features, .avx2))
            .avx2
        else if (x86.featureSetHas(cpu.features, .ssse3))
            .sse
        else
            .generic,
        .aarch64, .aarch64_be => if (std.Target.aarch64.featureSetHas(cpu.features, .neon))
            .neon
        else
            .generic,
        else => .generic,
    };
}

// Runtime dispatch's tiers (`dispatch.zig`), here with `isaOf` so build.zig
// can import them without the dispatch options.

/// The kernels for one tier: compiled for `model` plus `add`, run where the
/// CPU has every feature in `need`. `need` lists what LLVM may emit for that
/// CPU: an x86-64 psABI level, plus the AVX-512 extensions the AVX-512
/// kernels use.
pub const Tier = struct {
    isa: Isa,
    model: *const std.Target.Cpu.Model,
    add: []const x86.Feature = &.{},
    need: []const x86.Feature,
};

const v2: []const x86.Feature = &.{ .cx16, .popcnt, .sahf, .sse3, .sse4_1, .sse4_2, .ssse3 };
const v3 = v2 ++ &[_]x86.Feature{ .avx, .avx2, .bmi, .bmi2, .f16c, .fma, .lzcnt, .movbe, .xsave };
const v4 = v3 ++ &[_]x86.Feature{ .avx512f, .avx512bw, .avx512cd, .avx512dq, .avx512vl };
// GFNI too, which Ice Lake and later and Zen 4 have alongside VBMI2: LLVM
// shifts bytes with it, worth 4-10% on UTF-8 validation from 1 KiB
// (docs/slop/results/dispatch-20261031.md).
const avx512_ext: []const x86.Feature = &.{ .avx512vbmi, .avx512vbmi2, .avx512bitalg, .avx512vpopcntdq, .gfni };

/// Every tier, best first.
pub const tiers = [_]Tier{
    .{ .isa = .avx512, .model = &x86.cpu.x86_64_v4, .add = avx512_ext, .need = v4 ++ avx512_ext },
    .{ .isa = .avx2, .model = &x86.cpu.x86_64_v3, .need = v3 },
    .{ .isa = .sse, .model = &x86.cpu.x86_64_v2, .need = v2 },
};

/// The tiers better than `base`, the ISA a build gets at comptime: the ones
/// build.zig compiles objects for and `dispatch.zig` picks among, best first.
pub fn dispatchAbove(base: Isa) []const Tier {
    for (tiers, 0..) |t, i| {
        if (t.isa == base) return tiers[0..i];
    }
    return if (base == .generic) &tiers else &.{};
}

/// AVX-512 VBMI (`vpermb`, `vpermi2b`, `vpmultishiftqb`), for paths that
/// need byte permutes: `permute`, `permute2`, `multishift`.
pub const has_vbmi = isa == .avx512 and hasX86(.avx512vbmi);
/// AVX-512 VBMI2 (`vpcompressb/w`, `vpexpandb`), for paths that compress
/// lanes: `compress`.
pub const has_vbmi2 = isa == .avx512 and hasX86(.avx512vbmi2);
/// BMI2 (`bzhi`, `pext`, `pdep`).
pub const has_bmi2 = builtin.cpu.arch == .x86_64 and hasX86(.bmi2);
/// Masked loads and stores of a whole 64-byte register, which `loadShort`
/// and `storePartial` use. Like every intrinsic here they need the LLVM
/// backend; the self-hosted backends (Debug builds on x86_64) take the
/// portable paths.
pub const has_masked = isa == .avx512 and llvm;

/// Bytes in one native vector register.
pub const width: usize = switch (isa) {
    .avx512 => 64,
    .avx2 => 32,
    .sse, .neon, .generic => 16,
};

/// Bytes each algorithm processes per iteration.
pub const block_len = 64;

/// One block of `T` code units.
pub fn Block(comptime T: type) type {
    return @Vector(block_len / @sizeOf(T), T);
}

fn hasX86(comptime feature: x86.Feature) bool {
    return x86.featureSetHas(builtin.cpu.features, feature);
}

// LLVM intrinsics resolve only under the LLVM backend; the self-hosted
// backends (Debug builds on x86_64) take the portable loop instead.
const llvm = builtin.zig_backend == .stage2_llvm;

/// The calling convention every `extern fn @"llvm.…"` intrinsic declares.
/// Zig lowers an extern's parameters as its calling convention passes them,
/// and since Zig 0.17 the Windows x64 C convention passes a vector by
/// reference, which gives the intrinsic a pointer where LLVM's signature has
/// the vector and fails LLVM's verifier. System V passes the vector by
/// value, as the signature has it, and is already the C convention on every
/// other x86-64 OS, where nothing changes. Elsewhere, the C convention
/// passes vectors by value on every OS.
pub const llvm_cc: std.builtin.CallingConvention = if (builtin.cpu.arch == .x86_64) .{ .x86_64_sysv = .{} } else .c;

extern fn @"llvm.x86.ssse3.pshuf.b.128"(@Vector(16, u8), @Vector(16, u8)) callconv(llvm_cc) @Vector(16, u8);
extern fn @"llvm.x86.avx2.pshuf.b"(@Vector(32, u8), @Vector(32, u8)) callconv(llvm_cc) @Vector(32, u8);
extern fn @"llvm.x86.avx512.pshuf.b.512"(@Vector(64, u8), @Vector(64, u8)) callconv(llvm_cc) @Vector(64, u8);
extern fn @"llvm.aarch64.neon.tbl1.v16i8"(@Vector(16, u8), @Vector(16, u8)) callconv(llvm_cc) @Vector(16, u8);
extern fn @"llvm.aarch64.neon.addp.v16i8"(@Vector(16, u8), @Vector(16, u8)) callconv(llvm_cc) @Vector(16, u8);

/// Looks each lane of `idx` up in a 16-entry table: `table[idx[i]]` where
/// `idx[i] < 16`, and 0 where bit 7 of `idx[i]` is set; other indices give an
/// unspecified byte. One `pshufb` or `tbl` per register.
pub inline fn lookup16(table: [16]u8, idx: anytype) @TypeOf(idx) {
    const n = @typeInfo(@TypeOf(idx)).vector.len;
    comptime std.debug.assert(n % 16 == 0);
    const t: @Vector(16, u8) = table;
    const Native = switch (isa) {
        .avx512 => if (n % 64 == 0) 64 else if (n % 32 == 0) 32 else 16,
        .avx2 => if (n % 32 == 0) 32 else 16,
        .sse, .neon, .generic => 16,
    };
    const in: [n]u8 = idx;
    var out: [n]u8 = undefined;
    if (!llvm or isa == .generic) {
        for (in, &out) |i, *o| o.* = if (i & 0x80 != 0) 0 else table[i & 0x0F];
        return out;
    }
    const tw = broadcast16(Native, t);
    inline for (0..n / Native) |c| {
        const v: @Vector(Native, u8) = in[c * Native ..][0..Native].*;
        out[c * Native ..][0..Native].* = switch (isa) {
            .avx512 => switch (Native) {
                64 => @"llvm.x86.avx512.pshuf.b.512"(tw, v),
                32 => @"llvm.x86.avx2.pshuf.b"(tw, v),
                else => @"llvm.x86.ssse3.pshuf.b.128"(tw, v),
            },
            .avx2 => switch (Native) {
                32 => @"llvm.x86.avx2.pshuf.b"(tw, v),
                else => @"llvm.x86.ssse3.pshuf.b.128"(tw, v),
            },
            .sse => @"llvm.x86.ssse3.pshuf.b.128"(tw, v),
            .neon => @"llvm.aarch64.neon.tbl1.v16i8"(tw, v),
            .generic => unreachable,
        };
    }
    return out;
}

fn broadcast16(comptime n: usize, t: @Vector(16, u8)) @Vector(n, u8) {
    const mask = comptime blk: {
        @setEvalBranchQuota(100_000);
        var m: [n]i32 = undefined;
        for (&m, 0..) |*x, i| x.* = @intCast(i % 16);
        break :blk m;
    };
    return @shuffle(u8, t, undefined, mask);
}

/// `v` as an array of vectors of type `P`, as `@bitCast` gives it, but cut
/// out with shuffles. Zig 0.17 lowers a `@bitCast` to or from an array as a
/// loop over the elements through one wide integer; LLVM unrolls a short one
/// into moves through general registers and leaves a long one a loop. Not a
/// rule for every cast: most unroll back into register moves, and where the
/// shuffles let LLVM see the lanes, it can do worse, as in AVX-512's
/// `vpermt2b` narrowing, which it rewrote as two `vpmovwb` and a blend
/// (docs/slop/results/bitcast-sweep-20261101.md).
pub inline fn split(comptime P: type, v: anytype) [@sizeOf(@TypeOf(v)) / @sizeOf(P)]P {
    const m = @typeInfo(P).vector.len;
    const E = @typeInfo(P).vector.child;
    const k = @sizeOf(@TypeOf(v)) / @sizeOf(P);
    const all: @Vector(k * m, E) = @bitCast(v);
    var out: [k]P = undefined;
    inline for (&out, 0..) |*o, j| {
        o.* = @shuffle(E, all, undefined, std.simd.iota(i32, m) + @as(@Vector(m, i32), @splat(j * m)));
    }
    return out;
}

/// The vectors of `parts` end to end as a `T`, as `@bitCast` gives them,
/// but joined with shuffles, which Zig 0.17 needs as `split` does.
pub inline fn join(comptime T: type, parts: anytype) T {
    if (@typeInfo(@TypeOf(parts)) == .vector) return @bitCast(parts);
    const P = @typeInfo(@TypeOf(parts)).array.child;
    const E = @typeInfo(P).vector.child;
    const m = @typeInfo(P).vector.len;
    if (parts.len == 1) return @bitCast(parts[0]);
    const both = comptime blk: {
        var r: [2 * m]i32 = undefined;
        for (&r, 0..) |*x, i| x.* = if (i < m) i else ~@as(i32, i - m);
        break :blk r;
    };
    var pairs: [parts.len / 2]@Vector(2 * m, E) = undefined;
    inline for (&pairs, 0..) |*q, j| q.* = @shuffle(E, parts[2 * j], parts[2 * j + 1], both);
    return join(T, pairs);
}

/// The vector `k` lanes earlier in the stream: lane i is `cur[i - k]`, and
/// the first `k` lanes are the last `k` of `before`, the previous block.
pub inline fn prev(comptime k: usize, cur: anytype, before: @TypeOf(cur)) @TypeOf(cur) {
    const info = @typeInfo(@TypeOf(cur)).vector;
    const n = info.len;
    return @shuffle(info.child, cur, before, prevMask(n, k));
}

fn prevMask(comptime n: usize, comptime k: usize) [n]i32 {
    @setEvalBranchQuota(100_000);
    var m: [n]i32 = undefined;
    for (&m, 0..) |*x, i| x.* = if (i >= k) @intCast(i - k) else ~@as(i32, @intCast(n - k + i));
    return m;
}

/// Lane i of `v` as bit i of an integer. Two cases build the mask from the
/// lanes instead of a `@bitCast`: big-endian targets, where the cast orders
/// the bits differently depending on how the vector was made (seen on
/// aarch64_be with Zig 0.16), and fewer than 8 lanes (or a count that is not
/// a multiple of 8) on the self-hosted backends, where the cast can leave
/// bits set above the last lane (seen on x86_64 for 2 and 4 lanes after `!`
/// or a 64-bit compare). NEON has no `pmovmskb`: LLVM lowers the cast with an
/// `addv` per 16 lanes, so 32 and 64 lanes take each lane's bit and add
/// neighbouring bytes with `addp` instead, as simdutf does.
pub inline fn bitmask(v: anytype) @Int(.unsigned, @typeInfo(@TypeOf(v)).vector.len) {
    const n = @typeInfo(@TypeOf(v)).vector.len;
    if (isa == .neon and llvm and builtin.cpu.arch.endian() == .little and (n == 32 or n == 64)) {
        const z: @Vector(n, u8) = @splat(0);
        const m: [n / 16]@Vector(16, u8) = @bitCast(@select(u8, v, comptime laneBits(n), z));
        const addp = @"llvm.aarch64.neon.addp.v16i8";
        const r = if (n == 64) addp(addp(m[0], m[1]), addp(m[2], m[3])) else addp(m[0], m[1]);
        const s = addp(r, r);
        const t = if (n == 64) s else addp(s, s);
        return @truncate(@as(@Vector(2, u64), @bitCast(t))[0]);
    }
    if (builtin.cpu.arch.endian() == .little and (llvm or n % 8 == 0)) return @bitCast(v);
    const L = @Int(.unsigned, @max(8, std.math.ceilPowerOfTwoAssert(usize, n)));
    const bits = comptime blk: {
        @setEvalBranchQuota(100_000);
        var b: [n]L = undefined;
        for (&b, 0..) |*x, i| x.* = @as(L, 1) << i;
        break :blk b;
    };
    return @truncate(@reduce(.Or, @select(L, v, @as(@Vector(n, L), bits), @as(@Vector(n, L), @splat(0)))));
}

/// Byte i is bit i % 8: each lane's bit within its byte of the mask.
fn laneBits(comptime n: usize) @Vector(n, u8) {
    var b: [n]u8 = undefined;
    for (&b, 0..) |*x, i| x.* = @as(u8, 1) << @intCast(i % 8);
    return b;
}

/// Loads the block starting at `src[0]`, which must hold a whole block. One
/// unaligned load: coercing the array `src[0..n].*` to a vector instead can
/// compile to a load per lane.
pub inline fn load(comptime T: type, src: []const T) Block(T) {
    const n = @typeInfo(Block(T)).vector.len;
    return @as(*align(1) const Block(T), @ptrCast(src[0..n])).*;
}

/// Loads a slice shorter than a block, zero-padded, without reading past
/// it. The block is built in registers from 16-byte loads and a tail of
/// overlapping integer loads: building it in a stack buffer and loading
/// that whole stalls store-to-load forwarding, which costs more than the
/// validation itself on short inputs.
pub inline fn loadPartial(comptime T: type, src: []const T) Block(T) {
    const s = std.mem.sliceAsBytes(src);
    std.debug.assert(s.len < block_len);
    const full = s.len / 16;
    const z: @Vector(16, u8) = @splat(0);
    const t = tail16(s[full * 16 ..]);
    const bytes = switch (full) {
        0 => concat4(t, z, z, z),
        1 => concat4(load16(s), t, z, z),
        2 => concat4(load16(s), load16(s[16..]), t, z),
        else => concat4(load16(s), load16(s[16..]), load16(s[32..]), t),
    };
    return @bitCast(bytes);
}

/// Loads 16 bytes, the width every ISA path has.
pub inline fn load16(s: []const u8) @Vector(16, u8) {
    return @as(*align(1) const @Vector(16, u8), @ptrCast(s[0..16])).*;
}

/// Fewer than 16 bytes, zero-padded. Each pair of loads overlaps in the
/// middle, where both hold the same bytes, so OR joins them.
inline fn tail16(s: []const u8) @Vector(16, u8) {
    const r = s.len;
    var x: u128 = 0;
    if (r >= 8) {
        const lo = std.mem.readInt(u64, s[0..8], .little);
        const hi = std.mem.readInt(u64, s[r - 8 ..][0..8], .little);
        x = lo | @as(u128, hi) << @intCast(8 * (r - 8));
    } else if (r >= 4) {
        const lo = std.mem.readInt(u32, s[0..4], .little);
        const hi = std.mem.readInt(u32, s[r - 4 ..][0..4], .little);
        x = lo | @as(u64, hi) << @intCast(8 * (r - 4));
    } else if (r > 0) {
        x = @as(u32, s[0]) | @as(u32, s[r / 2]) << @intCast(8 * (r / 2)) | @as(u32, s[r - 1]) << @intCast(8 * (r - 1));
    }
    return @bitCast(std.mem.nativeToLittle(u128, x));
}

inline fn concat4(a: @Vector(16, u8), b: @Vector(16, u8), c: @Vector(16, u8), d: @Vector(16, u8)) @Vector(64, u8) {
    const halves = comptime blk: {
        @setEvalBranchQuota(100_000);
        var m: [32]i32 = undefined;
        for (&m, 0..) |*x, i| x.* = if (i < 16) @intCast(i) else ~@as(i32, @intCast(i - 16));
        break :blk m;
    };
    const whole = comptime blk: {
        @setEvalBranchQuota(100_000);
        var m: [64]i32 = undefined;
        for (&m, 0..) |*x, i| x.* = if (i < 32) @intCast(i) else ~@as(i32, @intCast(i - 32));
        break :blk m;
    };
    return @shuffle(u8, @shuffle(u8, a, b, halves), @shuffle(u8, c, d, halves), whole);
}

/// Loads the block at `src[0]`, which must be 64-byte aligned and hold a
/// whole block: an aligned load can be an operand on SSE.
pub inline fn loadAligned(comptime T: type, src: []const T) Block(T) {
    const n = @typeInfo(Block(T)).vector.len;
    return @as(*align(64) const Block(T), @ptrCast(@alignCast(src[0..n]))).*;
}

/// Code units from `p` to the first 64-byte boundary after it: 1 to a
/// block's worth, a whole block when `p` is on one. A loop that checks the
/// first block unaligned and goes on from there loads every later block
/// aligned, so none splits a cache line.
pub inline fn toBoundary(comptime T: type, p: [*]const T) usize {
    return (block_len - @intFromPtr(p) % block_len) / @sizeOf(T);
}

/// Loads one vector of type `V` from `src`, a slice or a pointer to an
/// array, in one load per register. Volatile: LLVM narrows a load whose
/// lanes are not all used, such as a shuffle table's entry or a window of
/// input, into several narrower ones.
pub inline fn loadVolatile(comptime V: type, src: anytype) V {
    const n = @typeInfo(V).vector.len;
    return @as(*align(1) const volatile V, @ptrCast(src[0..n])).*;
}

/// Stores the vector `v` at `dst[0..]` in one store per register.
/// Volatile: LLVM splits a 64-byte store it cannot prove aligned in two,
/// and merges overlapping stores into extra shuffles.
pub inline fn storeVolatile(dst: anytype, v: anytype) void {
    const n = @typeInfo(@TypeOf(v)).vector.len;
    @as(*align(1) volatile @TypeOf(v), @ptrCast(dst[0..n])).* = v;
}

/// The low `n` bits of an `M` set, all of them for `n` from its width up to
/// 255: one `bzhi` with BMI2.
pub inline fn lowBits(comptime M: type, n: usize) M {
    std.debug.assert(n < 256);
    if (has_bmi2 and llvm and @bitSizeOf(M) <= 64) {
        const k: u64 = n & 0xFF;
        if (@bitSizeOf(M) == 64) return @"llvm.x86.bmi.bzhi.64"(~@as(u64, 0), k);
        const ones: u32 = @truncate(~@as(u64, 0));
        return @truncate(@"llvm.x86.bmi.bzhi.32"(ones >> @intCast(32 - @bitSizeOf(M)), @truncate(k)));
    }
    return if (n >= @bitSizeOf(M)) ~@as(M, 0) else (@as(M, 1) << @intCast(n)) - 1;
}

/// Whether a 64-byte access at `addr` whose first `len` bytes count leaves
/// the bytes after them on the page of its last counted byte (of `addr`
/// itself when `len` is 0, unless `addr` starts a page). A masked load or
/// store whose masked-off bytes reach into another page takes a microcode
/// assist on every call when that page is not mapped or not yet written,
/// as a freshly allocated output is.
inline fn restOnPage(addr: usize, len: usize) bool {
    return (addr +% len -% 1) ^ (addr +% (block_len - 1)) < std.heap.page_size_min;
}

/// Loads a slice of up to a block, zero-padded, without reading past it:
/// on AVX-512 one masked load (1.2-1.9× `loadPartial` at 7-45 bytes,
/// docs/slop/results/validate-wave2-20261031.md). Where the masked-off
/// bytes would reach another page (see `restOnPage`), with VBMI the 64
/// bytes that end where the slice does, moved down, else `loadPartial`.
/// A masked load waits for any recent store to the bytes it masks off;
/// where those may be an output just written, as at the end of an input,
/// `loadTail` avoids that.
pub inline fn loadShort(comptime T: type, src: []const T) Block(T) {
    const len = src.len * @sizeOf(T);
    std.debug.assert(len <= block_len);
    if (!has_masked) return if (len == block_len) load(T, src) else loadPartial(T, src);
    // The pointer of an empty slice may be anything.
    if (len == 0) return @splat(0);
    const addr = @intFromPtr(src.ptr);
    const lanes = @typeInfo(Block(T)).vector.len;
    // The common case in one test: all 64 bytes on one page.
    if (addr % std.heap.page_size_min <= std.heap.page_size_min - block_len)
        return maskedLoad(T, src.ptr, @bitCast(lowBits(@Int(.unsigned, lanes), src.len)));
    if (restOnPage(addr, len))
        return maskedLoad(T, src.ptr, @bitCast(lowBits(@Int(.unsigned, lanes), src.len)));
    if (!has_vbmi) return loadPartial(T, src);
    // The input starts in the last 63 bytes of its page, so the 64 bytes
    // that end where it does lie on that page: load the input as the end of
    // them, then move it down. Cheaper in registers than `loadPartial`,
    // which inline cost short callers saved registers, and out of line a
    // frame (13-20% at 16 bytes).
    const ending: *const anyopaque = @ptrFromInt(addr + len - block_len);
    const top: @Vector(64, bool) = @bitCast(~lowBits(u64, block_len - len));
    const block = maskedLoad(u8, ending, top);
    const idx = std.simd.iota(u8, 64) +% @as(Block(u8), @splat(@intCast(block_len - len)));
    return @bitCast(permute2(block, idx, @as(Block(u8), @splat(0))));
}

/// A masked load of a whole register, zeros in the lanes `mask` leaves out.
inline fn maskedLoad(comptime T: type, ptr: *const anyopaque, mask: @Vector(block_len / @sizeOf(T), bool)) Block(T) {
    return switch (T) {
        u8 => @"llvm.masked.load.v64i8.p0"(ptr, 1, @bitCast(mask), @splat(0)),
        u16 => @"llvm.masked.load.v32i16.p0"(ptr, 1, @bitCast(mask), @splat(0)),
        u32 => @"llvm.masked.load.v16i32.p0"(ptr, 1, @bitCast(mask), @splat(0)),
        else => @compileError("no masked load for " ++ @typeName(T)),
    };
}

/// A masked store of a whole register, of the lanes `mask` selects.
inline fn maskedStore(v: anytype, ptr: *anyopaque, mask: @Vector(@typeInfo(@TypeOf(v)).vector.len, bool)) void {
    switch (@TypeOf(v)) {
        @Vector(64, u8) => @"llvm.masked.store.v64i8.p0"(v, ptr, 1, @bitCast(mask)),
        @Vector(32, u16) => @"llvm.masked.store.v32i16.p0"(v, ptr, 1, @bitCast(mask)),
        @Vector(16, u32) => @"llvm.masked.store.v16i32.p0"(v, ptr, 1, @bitCast(mask)),
        else => @compileError("no masked store for " ++ @typeName(@TypeOf(v))),
    }
}

/// Loads `src[start..end]`, shorter than a block, zero-padded, without
/// reading outside `src`. With VBMI and a whole block before `end`, that is
/// the block that ends at `end`, moved down with `vpermb`: a masked load
/// reads no more, but waits for any recent store to the bytes it masks off,
/// such as to an output placed right after the input, which doubled the
/// time of short base64 calls (docs/slop/results/base64-20261031.md).
pub inline fn loadTail(src: []const u8, start: usize, end: usize) Block(u8) {
    const n = end - start;
    std.debug.assert(n < block_len);
    if (n == 0) return @splat(0);
    if (has_vbmi and llvm and end >= block_len) {
        const iota = std.simd.iota(u8, 64);
        const moved = permute(load(u8, src[end - block_len ..]), iota +% @as(Block(u8), @splat(@intCast(64 - n))));
        return @select(u8, iota < @as(Block(u8), @splat(@intCast(n))), moved, @as(Block(u8), @splat(0)));
    }
    return loadPartial(u8, src[start..end]);
}

/// Stores the first `n` lanes of `v`, a vector of 16, 32, or 64 bytes, at
/// `dst`, writing nothing past them; all of them when `n` is at least the
/// lane count. On AVX-512 a 64-byte vector goes in one masked store when
/// the bytes it masks off are on the page of its last byte (see
/// `restOnPage`: into a freshly mapped buffer, masking across a page halved
/// the speed of 4 KiB base64 decodes); otherwise, with VBMI, as the end of
/// the 64 bytes that end where the output does, moved up. Elsewhere whole
/// 16-byte pieces and the last part of one in two overlapping integer
/// stores.
pub inline fn storePartial(dst: anytype, v: anytype, n: usize) void {
    const T = @typeInfo(@TypeOf(v)).vector.child;
    const lanes = @typeInfo(@TypeOf(v)).vector.len;
    const size = lanes * @sizeOf(T);
    comptime std.debug.assert(size == 16 or size == 32 or size == 64);
    comptime std.debug.assert(@typeInfo(@TypeOf(dst.ptr)).pointer.child == T);
    std.debug.assert(@min(n, lanes) <= dst.len);
    if (has_masked and size == 64) {
        const addr = @intFromPtr(dst.ptr);
        const M = @Int(.unsigned, lanes);
        // The common case in one test, independent of `n`: all 64 bytes on
        // one page. `lowBits` stores all lanes from `n = lanes` on.
        if (addr % std.heap.page_size_min <= std.heap.page_size_min - block_len)
            return maskedStore(v, @ptrCast(dst.ptr), @bitCast(lowBits(M, n)));
        const len = @as(usize, @min(n, lanes)) * @sizeOf(T);
        if (restOnPage(addr, len)) return maskedStore(v, @ptrCast(dst.ptr), @bitCast(lowBits(M, n)));
        if (has_vbmi) {
            if (len == 0) return;
            // As in `loadShort`: the 64 bytes that end where the output
            // does lie on its last page, which the store writes, so the
            // output goes in as the end of them, moved up.
            const idx = std.simd.iota(u8, 64) -% @as(Block(u8), @splat(@intCast(block_len - len)));
            const top: @Vector(64, bool) = @bitCast(~lowBits(u64, block_len - len));
            const ending: *anyopaque = @ptrFromInt(addr + len - block_len);
            return maskedStore(permute(@bitCast(v), idx), ending, top);
        }
    }
    const len = @as(usize, @min(n, lanes)) * @sizeOf(T);
    storeBytes(@as([*]u8, @ptrCast(dst.ptr))[0..len], v);
}

/// Stores the first `d.len` bytes of `v` without writing past them: whole
/// 16-byte pieces, then the last part of one in two overlapping integer
/// stores.
inline fn storeBytes(d: []u8, v: anytype) void {
    const size = @sizeOf(@TypeOf(v));
    const len = d.len;
    const pieces: [size / 16]@Vector(16, u8) = @bitCast(v);
    const full = len / 16;
    inline for (0..size / 16) |k| {
        if (k < full) d[k * 16 ..][0..16].* = pieces[k];
    }
    if (full == size / 16) return;
    // A switch here compiles to a gather of 16 single bytes.
    var piece = pieces[0];
    inline for (1..size / 16) |k| {
        if (full == k) piece = pieces[k];
    }
    const x = std.mem.littleToNative(u128, @bitCast(piece));
    const r = d[full * 16 ..];
    const m = len % 16;
    if (m >= 8) {
        std.mem.writeInt(u64, r[0..8], @truncate(x), .little);
        std.mem.writeInt(u64, r[m - 8 ..][0..8], @truncate(x >> @intCast(8 * (m - 8))), .little);
    } else if (m >= 4) {
        std.mem.writeInt(u32, r[0..4], @truncate(x), .little);
        std.mem.writeInt(u32, r[m - 4 ..][0..4], @truncate(x >> @intCast(8 * (m - 4))), .little);
    } else if (m >= 2) {
        std.mem.writeInt(u16, r[0..2], @truncate(x), .little);
        std.mem.writeInt(u16, r[m - 2 ..][0..2], @truncate(x >> @intCast(8 * (m - 2))), .little);
    } else if (m == 1) {
        r[0] = @truncate(x);
    }
}

/// Byte i of each 16-byte lane of `data` and `idx`: `data`'s byte
/// `idx[i] % 16` of the same lane, or 0 where bit 7 of `idx[i]` is set
/// (`pshufb`, `tbl`). Unlike `lookup16`, each lane looks up its own 16
/// bytes, so one AVX2 `vpshufb` packs two groups of `data` at once.
pub inline fn shuffleLanes(data: anytype, idx: @TypeOf(data)) @TypeOf(data) {
    const n = @typeInfo(@TypeOf(data)).vector.len;
    comptime std.debug.assert(@typeInfo(@TypeOf(data)).vector.child == u8 and n % 16 == 0);
    const d: [n]u8 = data;
    const in: [n]u8 = idx;
    var out: [n]u8 = undefined;
    if (!llvm or isa == .generic) {
        for (in, &out, 0..) |i, *o, k| o.* = if (i & 0x80 != 0) 0 else d[k / 16 * 16 + (i & 0x0F)];
        return out;
    }
    const Native = switch (isa) {
        .avx512 => if (n % 64 == 0) 64 else if (n % 32 == 0) 32 else 16,
        .avx2 => if (n % 32 == 0) 32 else 16,
        .sse, .neon, .generic => 16,
    };
    inline for (0..n / Native) |c| {
        const t: @Vector(Native, u8) = d[c * Native ..][0..Native].*;
        const v: @Vector(Native, u8) = in[c * Native ..][0..Native].*;
        out[c * Native ..][0..Native].* = switch (Native) {
            64 => @"llvm.x86.avx512.pshuf.b.512"(t, v),
            32 => @"llvm.x86.avx2.pshuf.b"(t, v),
            else => switch (isa) {
                .neon => @"llvm.aarch64.neon.tbl1.v16i8"(t, v & @as(@Vector(16, u8), @splat(0x8F))),
                else => @"llvm.x86.ssse3.pshuf.b.128"(t, v),
            },
        };
    }
    return out;
}

/// The lanes of `v` that `keep` selects, in order, then zeros
/// (`vpcompressb/w/d`). Byte and 16-bit lanes need VBMI2.
pub inline fn compress(v: anytype, keep: @Int(.unsigned, @typeInfo(@TypeOf(v)).vector.len)) @TypeOf(v) {
    comptime std.debug.assert(isa == .avx512 and llvm);
    const m: @Vector(@typeInfo(@TypeOf(v)).vector.len, compat.MaskLane) = @bitCast(keep);
    return switch (@TypeOf(v)) {
        @Vector(64, u8) => @"llvm.x86.avx512.mask.compress.v64i8"(v, @splat(0), m),
        @Vector(32, u16) => @"llvm.x86.avx512.mask.compress.v32i16"(v, @splat(0), m),
        @Vector(16, u32) => @"llvm.x86.avx512.mask.compress.v16i32"(v, @splat(0), m),
        else => @compileError("no compress for " ++ @typeName(@TypeOf(v))),
    };
}

/// `table[idx[i] % 64]` (`vpermb`).
pub inline fn permute(table: @Vector(64, u8), idx: @Vector(64, u8)) @Vector(64, u8) {
    comptime std.debug.assert(has_vbmi and llvm);
    return @"llvm.x86.avx512.permvar.qi.512"(table, idx);
}

/// `(lo ++ hi)[idx[i] % (2 * lanes)]`, a lookup in a table of two
/// registers: `vpermi2b` for bytes (VBMI), `vpermi2d` for 32-bit lanes.
/// LLVM picks `vpermt2b/d` instead when the table is the register to
/// overwrite.
pub inline fn permute2(lo: anytype, idx: @TypeOf(lo), hi: @TypeOf(lo)) @TypeOf(lo) {
    comptime std.debug.assert(isa == .avx512 and llvm);
    return switch (@TypeOf(lo)) {
        @Vector(64, u8) => blk: {
            comptime std.debug.assert(has_vbmi);
            break :blk @"llvm.x86.avx512.vpermi2var.qi.512"(lo, idx, hi);
        },
        @Vector(16, u32) => @"llvm.x86.avx512.vpermi2var.d.512"(lo, idx, hi),
        else => @compileError("no permute2 for " ++ @typeName(@TypeOf(lo))),
    };
}

/// Byte i of each 64-bit lane of `data`, from bit `ctrl[i] % 64` up,
/// wrapping (`vpmultishiftqb`, VBMI).
pub inline fn multishift(ctrl: @Vector(64, u8), data: @Vector(64, u8)) @Vector(64, u8) {
    comptime std.debug.assert(has_vbmi and llvm);
    return @"llvm.x86.avx512.pmultishift.qb.512"(ctrl, data);
}

/// The bits of `x` where `mask` has a one, packed into the low bits (`pext`).
pub inline fn pext(x: u64, mask: u64) u64 {
    comptime std.debug.assert(has_bmi2 and llvm);
    return @"llvm.x86.bmi.pext.64"(x, mask);
}

/// The low bits of `x` spread to where `mask` has a one (`pdep`).
pub inline fn pdep(x: u64, mask: u64) u64 {
    comptime std.debug.assert(has_bmi2 and llvm);
    return @"llvm.x86.bmi.pdep.64"(x, mask);
}

/// The lanes of `v`, 32-bit, narrowed to `To` (`u16` or `u8`); each must
/// fit, else its lane is unspecified. On AVX2 and SSE4.1 saturating packs
/// (`packusdw`, then `packuswb` for bytes) and, on AVX2, a permute to undo
/// their per-128-bit lane order: a truncation masks each lane first.
pub inline fn narrow(comptime To: type, v: anytype) @Vector(@typeInfo(@TypeOf(v)).vector.len, To) {
    const n = @typeInfo(@TypeOf(v)).vector.len;
    comptime std.debug.assert(@typeInfo(@TypeOf(v)).vector.child == u32);
    const sse41 = isa == .sse and hasX86(.sse4_1);
    if (!llvm) return @truncate(v);
    if (has_vbmi and n % (64 / @sizeOf(To)) == 0) {
        // Two-register byte permutes: one makes 64 bytes of `u16` from two
        // registers, two and a blend make 64 of `u8` from four, where each
        // `vpmovdw` or `vpmovdb` is two shuffle-port operations for 32 or
        // 16 bytes.
        const per = 64 / @sizeOf(To);
        const q: [n / 16]@Vector(64, u8) = @bitCast(v);
        var out: [n / per]@Vector(64, u8) = undefined;
        // Byte j of the output is byte j % 2 of lane j / 2 of the two
        // registers' 32 lanes.
        const words = comptime blk: {
            var t: [64]u8 = undefined;
            for (&t, 0..) |*x, j| x.* = 4 * (j / 2) + j % 2;
            break :blk t;
        };
        inline for (&out, 0..) |*o, h| {
            if (To == u16) {
                o.* = permute2(q[2 * h], words, q[2 * h + 1]);
            } else {
                // An index LLVM cannot see, or it rewrites the blend of two
                // permutes as four `vpshufb`, two `vpermd`, and two 32-byte
                // stores.
                var t: *const [2][64]u8 = &narrow_bytes;
                _ = &t;
                const ab = permute2(q[4 * h], loadVolatile(@Vector(64, u8), &t[0]), q[4 * h + 1]);
                const cd = permute2(q[4 * h + 2], loadVolatile(@Vector(64, u8), &t[1]), q[4 * h + 3]);
                o.* = @select(u8, std.simd.iota(u8, 64) < @as(@Vector(64, u8), @splat(32)), ab, cd);
            }
        }
        return @bitCast(out);
    }
    if (To == u16 and isa == .avx2 and n % 16 == 0) {
        const q: [n / 8]@Vector(8, u32) = @bitCast(v);
        var out: [n / 16]@Vector(16, u16) = undefined;
        inline for (&out, 0..) |*o, h| {
            const lanes: @Vector(4, u64) = @bitCast(@"llvm.x86.avx2.packusdw"(q[2 * h], q[2 * h + 1]));
            o.* = @bitCast(@shuffle(u64, lanes, undefined, [4]i32{ 0, 2, 1, 3 }));
        }
        return @bitCast(out);
    }
    if (To == u16 and sse41 and n % 8 == 0) {
        const q: [n / 4]@Vector(4, u32) = @bitCast(v);
        var out: [n / 8]@Vector(8, u16) = undefined;
        inline for (&out, 0..) |*o, h| o.* = @"llvm.x86.sse41.packusdw"(q[2 * h], q[2 * h + 1]);
        return @bitCast(out);
    }
    if (To == u8 and isa == .avx2 and n % 32 == 0) {
        const q: [n / 8]@Vector(8, u32) = @bitCast(v);
        var out: [n / 32]@Vector(32, u8) = undefined;
        inline for (&out, 0..) |*o, h| {
            const ab = @"llvm.x86.avx2.packusdw"(q[4 * h], q[4 * h + 1]);
            const cd = @"llvm.x86.avx2.packusdw"(q[4 * h + 2], q[4 * h + 3]);
            const bytes: @Vector(8, u32) = @bitCast(@"llvm.x86.avx2.packuswb"(ab, cd));
            o.* = @bitCast(@"llvm.x86.avx2.permd"(bytes, .{ 0, 4, 1, 5, 2, 6, 3, 7 }));
        }
        return @bitCast(out);
    }
    return @truncate(v);
}

/// `narrow`'s indexes to `u8`, for output bytes 0-31 from the first two
/// registers and 32-63 from the last two, which it loads at run time.
const narrow_bytes: [2][64]u8 = blk: {
    var t: [2][64]u8 = @splat(@splat(0));
    for (0..32) |j| {
        t[0][j] = 4 * j;
        t[1][32 + j] = 4 * j;
    }
    break :blk t;
};

extern fn @"llvm.x86.bmi.bzhi.64"(u64, u64) callconv(llvm_cc) u64;
extern fn @"llvm.x86.bmi.bzhi.32"(u32, u32) callconv(llvm_cc) u32;
extern fn @"llvm.x86.bmi.pext.64"(u64, u64) callconv(llvm_cc) u64;
extern fn @"llvm.x86.bmi.pdep.64"(u64, u64) callconv(llvm_cc) u64;
extern fn @"llvm.masked.load.v64i8.p0"(
    *const anyopaque,
    u32,
    @Vector(64, compat.MaskLane),
    @Vector(64, u8),
) callconv(llvm_cc) @Vector(64, u8);
extern fn @"llvm.masked.load.v32i16.p0"(*const anyopaque, u32, @Vector(32, compat.MaskLane), W32) callconv(llvm_cc) W32;
extern fn @"llvm.masked.load.v16i32.p0"(*const anyopaque, u32, @Vector(16, compat.MaskLane), D16) callconv(llvm_cc) D16;
extern fn @"llvm.masked.store.v64i8.p0"(
    @Vector(64, u8),
    *anyopaque,
    u32,
    @Vector(64, compat.MaskLane),
) callconv(llvm_cc) void;
extern fn @"llvm.masked.store.v32i16.p0"(W32, *anyopaque, u32, @Vector(32, compat.MaskLane)) callconv(llvm_cc) void;
extern fn @"llvm.masked.store.v16i32.p0"(D16, *anyopaque, u32, @Vector(16, compat.MaskLane)) callconv(llvm_cc) void;
extern fn @"llvm.x86.avx512.mask.compress.v64i8"(
    @Vector(64, u8),
    @Vector(64, u8),
    @Vector(64, compat.MaskLane),
) callconv(llvm_cc) @Vector(64, u8);
const W32 = @Vector(32, u16);
const D16 = @Vector(16, u32);
extern fn @"llvm.x86.avx512.mask.compress.v32i16"(W32, W32, @Vector(32, compat.MaskLane)) callconv(llvm_cc) W32;
extern fn @"llvm.x86.avx512.mask.compress.v16i32"(D16, D16, @Vector(16, compat.MaskLane)) callconv(llvm_cc) D16;
extern fn @"llvm.x86.avx512.permvar.qi.512"(@Vector(64, u8), @Vector(64, u8)) callconv(llvm_cc) @Vector(64, u8);
extern fn @"llvm.x86.avx512.vpermi2var.qi.512"(
    @Vector(64, u8),
    @Vector(64, u8),
    @Vector(64, u8),
) callconv(llvm_cc) @Vector(64, u8);
extern fn @"llvm.x86.avx512.vpermi2var.d.512"(
    @Vector(16, u32),
    @Vector(16, u32),
    @Vector(16, u32),
) callconv(llvm_cc) @Vector(16, u32);
extern fn @"llvm.x86.avx512.pmultishift.qb.512"(@Vector(64, u8), @Vector(64, u8)) callconv(llvm_cc) @Vector(64, u8);
extern fn @"llvm.x86.avx2.packusdw"(@Vector(8, u32), @Vector(8, u32)) callconv(llvm_cc) @Vector(16, u16);
extern fn @"llvm.x86.sse41.packusdw"(@Vector(4, u32), @Vector(4, u32)) callconv(llvm_cc) @Vector(8, u16);
extern fn @"llvm.x86.avx2.packuswb"(@Vector(16, u16), @Vector(16, u16)) callconv(llvm_cc) @Vector(32, u8);
extern fn @"llvm.x86.avx2.permd"(@Vector(8, u32), @Vector(8, u32)) callconv(llvm_cc) @Vector(8, u32);

test "lookup16 matches a table lookup at every index and width" {
    const table: [16]u8 = .{ 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0xF0, 0xE1, 0xD2, 0xC3, 0xB4, 0xA5 };
    inline for (.{ 16, 32, 64 }) |n| {
        var idx: [n]u8 = undefined;
        for (&idx, 0..) |*x, i| x.* = @intCast((i * 7) % 16);
        idx[3] = 0x80;
        idx[n - 1] = 0xFF;
        const got: [n]u8 = lookup16(table, @as(@Vector(n, u8), idx));
        for (got, idx) |g, i| try testing.expectEqual(if (i & 0x80 != 0) 0 else table[i], g);
    }
}

test "prev shifts in the previous block's last lanes" {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    for (&a, &b, 0..) |*x, *y, i| {
        x.* = @intCast(i);
        y.* = @intCast(100 + i);
    }
    const got: [64]u8 = prev(3, @as(@Vector(64, u8), b), @as(@Vector(64, u8), a));
    try testing.expectEqualSlices(u8, &.{ 61, 62, 63, 100, 101 }, got[0..5]);
    try testing.expectEqual(160, got[63]);
}

test "bitmask puts lane i in bit i" {
    var a: [64]u8 = @splat(0);
    a[0] = 1;
    a[5] = 1;
    a[33] = 1;
    const v: @Vector(64, u8) = a;
    try testing.expectEqual(0x2_0000_0021, bitmask(v == @as(@Vector(64, u8), @splat(1))));
    const w: @Vector(16, u16) = @bitCast(a[0..32].*);
    const one: u16 = std.mem.nativeToLittle(u16, 1);
    try testing.expectEqual(0b1, bitmask(w == @as(@Vector(16, u16), @splat(one))));
    const x: @Vector(32, u16) = @bitCast(a);
    try testing.expectEqual(0x1_0005, bitmask(x != @as(@Vector(32, u16), @splat(0))));
}

test "bitmask sets no bits above the last lane of a short vector" {
    // `!` and a 64-bit compare are what left junk above the lanes on the
    // self-hosted x86_64 backend; every mask of 2 and 4 lanes, read wide.
    inline for (.{ 2, 4 }) |n| {
        for (0..1 << n) |k| {
            var lanes: [n]u64 = undefined;
            for (&lanes, 0..) |*x, i| x.* = if (k >> @intCast(i) & 1 != 0) 7 else 2;
            var v: @Vector(n, u64) = lanes;
            std.mem.doNotOptimizeAway(&v);
            const five: @Vector(n, u64) = @splat(5);
            try testing.expectEqual(k, @as(u64, bitmask(v >= five)));
            try testing.expectEqual(~k & ((1 << n) - 1), @as(u64, bitmask(!(v >= five))));
        }
    }
}

test "loadPartial copies every short length and zero-pads" {
    var src: [64]u8 = undefined;
    for (&src, 0..) |*x, i| x.* = @intCast(i + 1);
    for (0..64) |len| {
        const got: [64]u8 = loadPartial(u8, src[0..len]);
        try testing.expectEqualSlices(u8, src[0..len], got[0..len]);
        for (got[len..]) |x| try testing.expectEqual(0, x);
    }
    const units = [_]u16{ 0xD800, 0x1234, 0xDC00 };
    const got: [32]u16 = loadPartial(u16, &units);
    try testing.expectEqualSlices(u16, &units, got[0..3]);
    try testing.expectEqual(0, got[3]);
}

test "loadShort matches loadPartial at every length, also at a page's end" {
    const page = std.heap.page_size_min;
    const buf = try testing.allocator.alignedAlloc(u8, .fromByteUnits(page), 2 * page);
    defer testing.allocator.free(buf);
    for (buf, 0..) |*x, i| x.* = @truncate(i *% 7 + 1);
    // Starts at the page's end, so the bytes past each slice cross into the
    // next page, then within it.
    for ([_]usize{ page - 63, page - 40, page - 1, 5 }) |at| {
        for (0..64) |len| {
            try testing.expectEqual(loadPartial(u8, buf[at..][0..len]), loadShort(u8, buf[at..][0..len]));
        }
        const units: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, buf[at & ~@as(usize, 1) ..][0..62]));
        for (0..32) |len| try testing.expectEqual(loadPartial(u16, units[0..len]), loadShort(u16, units[0..len]));
    }
}

test "loadTail loads the end of an input zero-padded" {
    var src: [200]u8 = undefined;
    for (&src, 0..) |*x, i| x.* = @intCast(i);
    for ([_]usize{ 0, 3, 64, 130, 199 }) |start| {
        for (start..@min(start + 64, src.len + 1)) |end| {
            try testing.expectEqual(loadPartial(u8, src[start..end]), loadTail(src[0..end], start, end));
        }
    }
}

test "storePartial writes exactly the first n lanes" {
    inline for (.{ u8, u16, u32 }) |T| {
        inline for (.{ 16, 32, 64 }) |size| {
            const lanes = size / @sizeOf(T);
            var lanes_v: [lanes]T = undefined;
            for (&lanes_v, 0..) |*x, i| x.* = @intCast(i + 1);
            const v: @Vector(lanes, T) = lanes_v;
            for (0..lanes + 2) |n| {
                var dst: [lanes + 8]T = @splat(0xAA);
                storePartial(dst[0..], v, n);
                const k = @min(n, lanes);
                try testing.expectEqualSlices(T, lanes_v[0..k], dst[0..k]);
                for (dst[k..]) |x| try testing.expectEqual(0xAA, x);
            }
        }
    }
}

test "storePartial writes nothing past a page's end" {
    const page = std.heap.page_size_min;
    const buf = try testing.allocator.alignedAlloc(u8, .fromByteUnits(page), 2 * page);
    defer testing.allocator.free(buf);
    var bytes: [64]u8 = undefined;
    for (&bytes, 0..) |*x, i| x.* = @intCast(i + 1);
    for ([_]usize{ page - 64, page - 40, page - 1 }) |at| {
        for (0..64) |n| {
            @memset(buf, 0);
            storePartial(buf[at..], @as(@Vector(64, u8), bytes), n);
            try testing.expectEqualSlices(u8, bytes[0..n], buf[at..][0..n]);
            for (buf[at + n ..]) |x| try testing.expectEqual(0, x);
        }
    }
}

test "lowBits sets the low n bits, all from the width up" {
    for (0..256) |n| {
        try testing.expectEqual(if (n >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(n)) - 1, lowBits(u64, n));
        try testing.expectEqual(if (n >= 32) ~@as(u32, 0) else (@as(u32, 1) << @intCast(n)) - 1, lowBits(u32, n));
        try testing.expectEqual(if (n >= 16) ~@as(u16, 0) else (@as(u16, 1) << @intCast(n)) - 1, lowBits(u16, n));
    }
}

test "narrow keeps each lane that fits, in order" {
    var a: [64]u32 = undefined;
    for (&a, 0..) |*x, i| x.* = @intCast((i * 1031) % 0x10000);
    const w: [64]u16 = narrow(u16, @as(@Vector(64, u32), a));
    for (w, a) |x, y| try testing.expectEqual(y, x);
    for (&a, 0..) |*x, i| x.* = @intCast((i * 37) % 0x100);
    const b: [64]u8 = narrow(u8, @as(@Vector(64, u32), a));
    for (b, a) |x, y| try testing.expectEqual(y, x);
}

test "the AVX-512 permutes and compress pick the lanes they name" {
    if (!(has_vbmi and has_vbmi2 and has_bmi2 and llvm)) return error.SkipZigTest;
    const iota = std.simd.iota(u8, 64);
    const rev: @Vector(64, u8) = @as(@Vector(64, u8), @splat(63)) - iota;
    try testing.expectEqual(rev, permute(iota, rev +% @as(@Vector(64, u8), @splat(64))));
    const hi = iota +% @as(@Vector(64, u8), @splat(64));
    const k64: @Vector(64, u8) = @splat(64);
    try testing.expectEqual(rev +% k64, permute2(iota, rev | k64, hi));
    const odd: [64]u8 = compress(iota, 0xAAAA_AAAA_AAAA_AAAA);
    for (0..32) |i| try testing.expectEqual(2 * i + 1, odd[i]);
    for (odd[32..]) |x| try testing.expectEqual(0, x);
    // Each byte of a lane from bit 8 * i + 4: the high nibble of byte i and
    // the low nibble of byte i + 1.
    var ctrl: [64]u8 = undefined;
    for (&ctrl, 0..) |*x, i| x.* = @intCast(8 * (i % 8) + 4);
    const data: @Vector(64, u8) = @splat(0x5A);
    try testing.expectEqual(@as(@Vector(64, u8), @splat(0xA5)), multishift(ctrl, data));
    try testing.expectEqual(0b1011, pext(0b1011_0110, 0b1111_0000));
    try testing.expectEqual(0b1000_0100, pdep(0b101, 0b1100_0100));
}
