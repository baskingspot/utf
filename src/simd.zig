//! Shared vector helpers and the instruction set chosen at comptime.
//!
//! Every algorithm works on 64-byte blocks, `Block(T)`, on every ISA: four
//! 16-byte registers on SSE, NEON, and the generic path, two on AVX2, one on
//! AVX-512. The block code is the same everywhere; LLVM splits a 64-byte
//! vector into the target's registers, and only the operations with no
//! portable form, like `lookup16`, pick an instruction per ISA.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const x86 = std.Target.x86;

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

/// AVX-512 VBMI (`vpermb`, `vpermi2b`), for paths that need byte permutes.
pub const has_vbmi = isa == .avx512 and hasX86(.avx512vbmi);
/// AVX-512 VBMI2 (`vpcompressb`, `vpexpandb`), for paths that compress lanes.
pub const has_vbmi2 = isa == .avx512 and hasX86(.avx512vbmi2);

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
extern fn @"llvm.x86.ssse3.pshuf.b.128"(@Vector(16, u8), @Vector(16, u8)) @Vector(16, u8);
extern fn @"llvm.x86.avx2.pshuf.b"(@Vector(32, u8), @Vector(32, u8)) @Vector(32, u8);
extern fn @"llvm.x86.avx512.pshuf.b.512"(@Vector(64, u8), @Vector(64, u8)) @Vector(64, u8);
extern fn @"llvm.aarch64.neon.tbl1.v16i8"(@Vector(16, u8), @Vector(16, u8)) @Vector(16, u8);

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
/// or a 64-bit compare).
pub inline fn bitmask(v: anytype) @Int(.unsigned, @typeInfo(@TypeOf(v)).vector.len) {
    const n = @typeInfo(@TypeOf(v)).vector.len;
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
