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
//! Characters per Second with SIMD Instructions" (2022), and on AVX-512 with
//! VBMI2 Clausecker and Lemire, "Transcoding Unicode Characters with AVX-512
//! Instructions" (2023). UTF-8 is decoded a 64-byte block at a time: each
//! byte gets the value of a character ending there, and the values that end
//! characters are packed by shuffle tables keyed by the end-of-character mask
//! (by lane compression on AVX-512), with 12-byte windows for the tail.
//! UTF-16 and UTF-32 are encoded by expanding code points into lanes and
//! packing them, with ASCII and two-byte fast paths. UTF-8 is validated in
//! the same pass with Keiser and Lemire's three-lookup check. Every table is
//! built at comptime.

const std = @import("std");
const builtin = @import("builtin");
const Endian = std.lang.Endian;
const result = @import("result.zig");
const Result = result.Result;
const scalar = @import("scalar_convert.zig");
const simd = @import("simd.zig");
const dispatch = @import("dispatch.zig");

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
    return dispatch.call(@src(), utf8ToUtf16leKernel, .{ src, dst });
}
fn utf8ToUtf16leKernel(src: []const u8, dst: []u16) Result {
    return utf8ToUnits(u16, .little, true, src, dst);
}
pub fn utf8ToUtf16be(src: []const u8, dst: []u16) Result {
    return dispatch.call(@src(), utf8ToUtf16beKernel, .{ src, dst });
}
fn utf8ToUtf16beKernel(src: []const u8, dst: []u16) Result {
    return utf8ToUnits(u16, .big, true, src, dst);
}
pub fn utf8ToUtf32(src: []const u8, dst: []u32) Result {
    return dispatch.call(@src(), utf8ToUtf32Kernel, .{ src, dst });
}
fn utf8ToUtf32Kernel(src: []const u8, dst: []u32) Result {
    return utf8ToUnits(u32, native, true, src, dst);
}
pub fn utf8ToLatin1(src: []const u8, dst: []u8) Result {
    return dispatch.call(@src(), utf8ToLatin1Kernel, .{ src, dst });
}
fn utf8ToLatin1Kernel(src: []const u8, dst: []u8) Result {
    return utf8ToLatin1Impl(true, src, dst);
}
pub fn validUtf8ToUtf16le(src: []const u8, dst: []u16) usize {
    return dispatch.call(@src(), validUtf8ToUtf16leKernel, .{ src, dst });
}
fn validUtf8ToUtf16leKernel(src: []const u8, dst: []u16) usize {
    return utf8ToUnits(u16, .little, false, src, dst).count;
}
pub fn validUtf8ToUtf16be(src: []const u8, dst: []u16) usize {
    return dispatch.call(@src(), validUtf8ToUtf16beKernel, .{ src, dst });
}
fn validUtf8ToUtf16beKernel(src: []const u8, dst: []u16) usize {
    return utf8ToUnits(u16, .big, false, src, dst).count;
}
pub fn validUtf8ToUtf32(src: []const u8, dst: []u32) usize {
    return dispatch.call(@src(), validUtf8ToUtf32Kernel, .{ src, dst });
}
fn validUtf8ToUtf32Kernel(src: []const u8, dst: []u32) usize {
    return utf8ToUnits(u32, native, false, src, dst).count;
}
pub fn validUtf8ToLatin1(src: []const u8, dst: []u8) usize {
    return dispatch.call(@src(), validUtf8ToLatin1Kernel, .{ src, dst });
}
fn validUtf8ToLatin1Kernel(src: []const u8, dst: []u8) usize {
    return utf8ToLatin1Impl(false, src, dst).count;
}

// UTF-16 source.

pub fn utf16leToUtf8(src: []const u16, dst: []u8) Result {
    return dispatch.call(@src(), utf16leToUtf8Kernel, .{ src, dst });
}
fn utf16leToUtf8Kernel(src: []const u16, dst: []u8) Result {
    return utf16ToUtf8Impl(.little, true, src, dst);
}
pub fn utf16beToUtf8(src: []const u16, dst: []u8) Result {
    return dispatch.call(@src(), utf16beToUtf8Kernel, .{ src, dst });
}
fn utf16beToUtf8Kernel(src: []const u16, dst: []u8) Result {
    return utf16ToUtf8Impl(.big, true, src, dst);
}
pub fn utf16leToUtf32(src: []const u16, dst: []u32) Result {
    return dispatch.call(@src(), utf16leToUtf32Kernel, .{ src, dst });
}
fn utf16leToUtf32Kernel(src: []const u16, dst: []u32) Result {
    return utf16ToUtf32Impl(.little, true, src, dst);
}
pub fn utf16beToUtf32(src: []const u16, dst: []u32) Result {
    return dispatch.call(@src(), utf16beToUtf32Kernel, .{ src, dst });
}
fn utf16beToUtf32Kernel(src: []const u16, dst: []u32) Result {
    return utf16ToUtf32Impl(.big, true, src, dst);
}
pub fn utf16leToLatin1(src: []const u16, dst: []u8) Result {
    return dispatch.call(@src(), utf16leToLatin1Kernel, .{ src, dst });
}
fn utf16leToLatin1Kernel(src: []const u16, dst: []u8) Result {
    return utf16ToLatin1Impl(.little, true, src, dst);
}
pub fn utf16beToLatin1(src: []const u16, dst: []u8) Result {
    return dispatch.call(@src(), utf16beToLatin1Kernel, .{ src, dst });
}
fn utf16beToLatin1Kernel(src: []const u16, dst: []u8) Result {
    return utf16ToLatin1Impl(.big, true, src, dst);
}
/// Swaps the byte order, failing on an unpaired surrogate.
pub fn utf16leToUtf16be(src: []const u16, dst: []u16) Result {
    return dispatch.call(@src(), utf16leToUtf16beKernel, .{ src, dst });
}
fn utf16leToUtf16beKernel(src: []const u16, dst: []u16) Result {
    return utf16SwapImpl(.little, true, src, dst);
}
/// Swaps the byte order, failing on an unpaired surrogate.
pub fn utf16beToUtf16le(src: []const u16, dst: []u16) Result {
    return dispatch.call(@src(), utf16beToUtf16leKernel, .{ src, dst });
}
fn utf16beToUtf16leKernel(src: []const u16, dst: []u16) Result {
    return utf16SwapImpl(.big, true, src, dst);
}
pub fn validUtf16leToUtf8(src: []const u16, dst: []u8) usize {
    return dispatch.call(@src(), validUtf16leToUtf8Kernel, .{ src, dst });
}
fn validUtf16leToUtf8Kernel(src: []const u16, dst: []u8) usize {
    return utf16ToUtf8Impl(.little, false, src, dst).count;
}
pub fn validUtf16beToUtf8(src: []const u16, dst: []u8) usize {
    return dispatch.call(@src(), validUtf16beToUtf8Kernel, .{ src, dst });
}
fn validUtf16beToUtf8Kernel(src: []const u16, dst: []u8) usize {
    return utf16ToUtf8Impl(.big, false, src, dst).count;
}
pub fn validUtf16leToUtf32(src: []const u16, dst: []u32) usize {
    return dispatch.call(@src(), validUtf16leToUtf32Kernel, .{ src, dst });
}
fn validUtf16leToUtf32Kernel(src: []const u16, dst: []u32) usize {
    return utf16ToUtf32Impl(.little, false, src, dst).count;
}
pub fn validUtf16beToUtf32(src: []const u16, dst: []u32) usize {
    return dispatch.call(@src(), validUtf16beToUtf32Kernel, .{ src, dst });
}
fn validUtf16beToUtf32Kernel(src: []const u16, dst: []u32) usize {
    return utf16ToUtf32Impl(.big, false, src, dst).count;
}
pub fn validUtf16leToLatin1(src: []const u16, dst: []u8) usize {
    return dispatch.call(@src(), validUtf16leToLatin1Kernel, .{ src, dst });
}
fn validUtf16leToLatin1Kernel(src: []const u16, dst: []u8) usize {
    return utf16ToLatin1Impl(.little, false, src, dst).count;
}
pub fn validUtf16beToLatin1(src: []const u16, dst: []u8) usize {
    return dispatch.call(@src(), validUtf16beToLatin1Kernel, .{ src, dst });
}
fn validUtf16beToLatin1Kernel(src: []const u16, dst: []u8) usize {
    return utf16ToLatin1Impl(.big, false, src, dst).count;
}
pub fn validUtf16leToUtf16be(src: []const u16, dst: []u16) usize {
    return dispatch.call(@src(), validUtf16leToUtf16beKernel, .{ src, dst });
}
fn validUtf16leToUtf16beKernel(src: []const u16, dst: []u16) usize {
    return utf16SwapImpl(.little, false, src, dst).count;
}
pub fn validUtf16beToUtf16le(src: []const u16, dst: []u16) usize {
    return dispatch.call(@src(), validUtf16beToUtf16leKernel, .{ src, dst });
}
fn validUtf16beToUtf16leKernel(src: []const u16, dst: []u16) usize {
    return utf16SwapImpl(.big, false, src, dst).count;
}

// UTF-32 source.

pub fn utf32ToUtf8(src: []const u32, dst: []u8) Result {
    return dispatch.call(@src(), utf32ToUtf8Kernel, .{ src, dst });
}
fn utf32ToUtf8Kernel(src: []const u32, dst: []u8) Result {
    return utf32ToUtf8Impl(true, src, dst);
}
pub fn utf32ToUtf16le(src: []const u32, dst: []u16) Result {
    return dispatch.call(@src(), utf32ToUtf16leKernel, .{ src, dst });
}
fn utf32ToUtf16leKernel(src: []const u32, dst: []u16) Result {
    return utf32ToUtf16Impl(.little, true, src, dst);
}
pub fn utf32ToUtf16be(src: []const u32, dst: []u16) Result {
    return dispatch.call(@src(), utf32ToUtf16beKernel, .{ src, dst });
}
fn utf32ToUtf16beKernel(src: []const u32, dst: []u16) Result {
    return utf32ToUtf16Impl(.big, true, src, dst);
}
pub fn utf32ToLatin1(src: []const u32, dst: []u8) Result {
    return dispatch.call(@src(), utf32ToLatin1Kernel, .{ src, dst });
}
fn utf32ToLatin1Kernel(src: []const u32, dst: []u8) Result {
    return utf32ToLatin1Impl(true, src, dst);
}
pub fn validUtf32ToUtf8(src: []const u32, dst: []u8) usize {
    return dispatch.call(@src(), validUtf32ToUtf8Kernel, .{ src, dst });
}
fn validUtf32ToUtf8Kernel(src: []const u32, dst: []u8) usize {
    return utf32ToUtf8Impl(false, src, dst).count;
}
pub fn validUtf32ToUtf16le(src: []const u32, dst: []u16) usize {
    return dispatch.call(@src(), validUtf32ToUtf16leKernel, .{ src, dst });
}
fn validUtf32ToUtf16leKernel(src: []const u32, dst: []u16) usize {
    return utf32ToUtf16Impl(.little, false, src, dst).count;
}
pub fn validUtf32ToUtf16be(src: []const u32, dst: []u16) usize {
    return dispatch.call(@src(), validUtf32ToUtf16beKernel, .{ src, dst });
}
fn validUtf32ToUtf16beKernel(src: []const u32, dst: []u16) usize {
    return utf32ToUtf16Impl(.big, false, src, dst).count;
}
pub fn validUtf32ToLatin1(src: []const u32, dst: []u8) usize {
    return dispatch.call(@src(), validUtf32ToLatin1Kernel, .{ src, dst });
}
fn validUtf32ToLatin1Kernel(src: []const u32, dst: []u8) usize {
    return utf32ToLatin1Impl(false, src, dst).count;
}

// Latin-1 source. Every byte is a character, so the checked forms fail only
// when the output runs out, and the valid forms only assume it does not.

pub fn latin1ToUtf8(src: []const u8, dst: []u8) Result {
    return dispatch.call(@src(), latin1ToUtf8Kernel, .{ src, dst });
}
fn latin1ToUtf8Kernel(src: []const u8, dst: []u8) Result {
    return latin1ToUtf8Impl(true, src, dst);
}
pub fn latin1ToUtf16le(src: []const u8, dst: []u16) Result {
    return dispatch.call(@src(), latin1ToUtf16leKernel, .{ src, dst });
}
fn latin1ToUtf16leKernel(src: []const u8, dst: []u16) Result {
    return latin1ToUnits(u16, .little, true, src, dst);
}
pub fn latin1ToUtf16be(src: []const u8, dst: []u16) Result {
    return dispatch.call(@src(), latin1ToUtf16beKernel, .{ src, dst });
}
fn latin1ToUtf16beKernel(src: []const u8, dst: []u16) Result {
    return latin1ToUnits(u16, .big, true, src, dst);
}
pub fn latin1ToUtf32(src: []const u8, dst: []u32) Result {
    return dispatch.call(@src(), latin1ToUtf32Kernel, .{ src, dst });
}
fn latin1ToUtf32Kernel(src: []const u8, dst: []u32) Result {
    return latin1ToUnits(u32, native, true, src, dst);
}
pub fn validLatin1ToUtf8(src: []const u8, dst: []u8) usize {
    return dispatch.call(@src(), validLatin1ToUtf8Kernel, .{ src, dst });
}
fn validLatin1ToUtf8Kernel(src: []const u8, dst: []u8) usize {
    return latin1ToUtf8Impl(false, src, dst).count;
}
pub fn validLatin1ToUtf16le(src: []const u8, dst: []u16) usize {
    return dispatch.call(@src(), validLatin1ToUtf16leKernel, .{ src, dst });
}
fn validLatin1ToUtf16leKernel(src: []const u8, dst: []u16) usize {
    return latin1ToUnits(u16, .little, false, src, dst).count;
}
pub fn validLatin1ToUtf16be(src: []const u8, dst: []u16) usize {
    return dispatch.call(@src(), validLatin1ToUtf16beKernel, .{ src, dst });
}
fn validLatin1ToUtf16beKernel(src: []const u8, dst: []u16) usize {
    return latin1ToUnits(u16, .big, false, src, dst).count;
}
pub fn validLatin1ToUtf32(src: []const u8, dst: []u32) usize {
    return dispatch.call(@src(), validLatin1ToUtf32Kernel, .{ src, dst });
}
fn validLatin1ToUtf32Kernel(src: []const u8, dst: []u32) usize {
    return latin1ToUnits(u32, native, false, src, dst).count;
}

// Vector helpers.

const V16 = @Vector(16, u8);

inline fn splat(comptime T: type, comptime x: anytype) T {
    return @splat(x);
}

/// Loads `n` UTF-16 code units in byte order `e` as native values. Volatile:
/// a block and the units one past it would otherwise merge into narrow
/// loads that rebuild both.
inline fn load16(comptime e: Endian, comptime n: usize, src: []const u16, i: usize) @Vector(n, u16) {
    const v = simd.loadVolatile(@Vector(n, u16), src[i..]);
    return if (e == native) v else @byteSwap(v);
}

/// Stores `v` to `dst[o..][0..n]`, widening or narrowing each lane to `T`
/// and putting UTF-16 in byte order `e`.
inline fn store(comptime T: type, comptime e: Endian, dst: []T, o: usize, v: anytype) void {
    const n = @typeInfo(@TypeOf(v)).vector.len;
    const Elem = @typeInfo(@TypeOf(v)).vector.child;
    const w: @Vector(n, T) = if (@bitSizeOf(Elem) <= @bitSizeOf(T)) v else @truncate(v);
    const out = if (T == u16 and e != native) @byteSwap(w) else w;
    // On AVX-512 volatile, so LLVM keeps each register's store whole. On
    // AVX2 the same made long ASCII runs half as fast.
    if (simd.isa == .avx512) {
        simd.storeVolatile(dst[o..], out);
    } else {
        dst[o..][0..n].* = out;
    }
}

/// Whether every lane of `v` is below `limit`, a power of two: one test of
/// the bits above, where a reduction to the largest lane takes a tree of
/// shuffles.
inline fn below(comptime limit: comptime_int, v: anytype) bool {
    const V = @TypeOf(v);
    const Elem = @typeInfo(V).vector.child;
    if (neon and @sizeOf(V) >= 16) return !anySet(fold(v) & splat(Fold(V), ~@as(Elem, limit - 1)));
    return @reduce(.Or, v & splat(V, ~@as(Elem, limit - 1))) == 0;
}

// NEON, where the code is shaped for Neoverse-class cores (Neoverse N2,
// docs/slop/results/neon-convert-20261101.md): of their two vector pipes
// only one shifts by an immediate (`ushll`, `shl`, `ushr`, `shrn`), while
// both run permutes (`zip`, `uzp`, `tbl`), logic, and compares, and they
// count bits only in vector registers. So lanes widen with `tbl`, not
// `ushll`; a reduction to a bool folds lanes with `orr` and one pairwise
// `umaxp`, read as a word, where LLVM reduces a bool vector through a lane
// mask or ORs a vector down with shifts on the integer side; and counts
// come from one `cnt` or a table, not a `@popCount` per mask.

/// NEON with the LLVM backend, which the intrinsics below need.
const neon = simd.isa == .neon and builtin.zig_backend == .stage2_llvm;

/// Little-endian NEON on an Apple core: an `apple_*` CPU model, which is
/// also what Zig builds for when aarch64 macOS is the target without a CPU.
/// UTF-8 decoding takes paths of its own there, since the choices measured
/// on Neoverse N2 do not hold (on M4 Max `utf8DecodeBlock` decodes emoji
/// 1.9x as fast as the windows N2 wants;
/// docs/slop/results/neon-apple-20261101.md); other NEON cores keep N2's.
const apple = neon and native == .little and std.mem.startsWith(u8, builtin.cpu.model.name, "apple_");

extern fn @"llvm.aarch64.neon.umaxp.v16i8"(V16, V16) callconv(simd.llvm_cc) V16;
extern fn @"llvm.aarch64.neon.addp.v8i16"(@Vector(8, u16), @Vector(8, u16)) callconv(simd.llvm_cc) @Vector(8, u16);

/// One 16-byte register of `V`'s lanes.
fn Fold(comptime V: type) type {
    const Elem = @typeInfo(V).vector.child;
    return @Vector(16 / @sizeOf(Elem), Elem);
}

/// The 16-byte registers of `v` ORed into one.
inline fn fold(v: anytype) Fold(@TypeOf(v)) {
    const F = Fold(@TypeOf(v));
    const n = @typeInfo(@TypeOf(v)).vector.len / @typeInfo(F).vector.len;
    if (n == 1) return v;
    const parts: [n]F = @bitCast(v);
    var acc = parts[0];
    inline for (parts[1..]) |x| acc |= x;
    return acc;
}

/// Whether any bit of the 16-byte register `v` is set: one `umaxp` and a
/// move to a general register.
inline fn anySet(v: anytype) bool {
    const b: V16 = @bitCast(v);
    const m = @"llvm.aarch64.neon.umaxp.v16i8"(b, b);
    return @as(@Vector(2, u64), @bitCast(m))[0] != 0;
}

/// Whether any lane of `c`, a compare of `Elem` lanes, is true. On NEON
/// from the compare's lanes, not a lane mask.
inline fn anyTrue(comptime Elem: type, c: anytype) bool {
    const V = @Vector(@typeInfo(@TypeOf(c)).vector.len, Elem);
    if (!neon or @sizeOf(V) < 16) return @reduce(.Or, c);
    return anySet(fold(@select(Elem, c, splat(V, ~@as(Elem, 0)), splat(V, 0))));
}

/// `tbl` indexes that widen the bytes `first..` of a register to lanes of
/// `size` bytes, each byte in the lane's byte `at` and the rest zero.
fn widening(comptime size: usize, comptime at: usize, comptime first: usize) V16 {
    var m: [16]u8 = @splat(0x80);
    for (0..16 / size) |k| m[size * k + at] = first + k;
    return m;
}

/// Stores the 16 bytes of `v` widened to `T` at `dst[o..]`, UTF-16 in byte
/// order `e`. On NEON with `tbl`, and plain stores, which LLVM pairs:
/// widened with zips against zero, LLVM sees a zero extension and makes
/// `ushll` of them again, and volatile stores keep it from pairing them
/// (`str` moves 16 bytes a cycle there, `stp` more: Latin-1 to UTF-32
/// 13.5 against 18 GB/s).
inline fn storeWide(comptime T: type, comptime e: Endian, dst: []T, o: usize, v: V16) void {
    if (!neon) return store(T, e, dst, o, v);
    const n = 16 / @sizeOf(T);
    const at = if (T == u16) @intFromBool(e == .big) else if (native == .little) 0 else 3;
    // One store per register: Zig 0.17 lowers a `@bitCast` of an array of
    // registers to `[16]T` through one integer, which LLVM unrolled into
    // lane moves.
    inline for (0..@sizeOf(T)) |q| {
        const x = simd.lookup16(v, comptime widening(@sizeOf(T), at, n * q));
        dst[o + n * q ..][0..n].* = @as(@Vector(n, T), @bitCast(x));
    }
}

/// Stores the 16-bit lanes of `v` widened to UTF-32 at `dst[o..]`: on
/// NEON with `tbl`, as `storeWide`.
inline fn storeWideUnits(dst: []u32, o: usize, v: anytype) void {
    if (!neon) return store(u32, native, dst, o, v);
    inline for (simd.split(V16, v), 0..) |x, k| {
        inline for (0..2) |h| {
            const idx = comptime blk: {
                var m: [16]u8 = @splat(0x80);
                for (0..4) |j| {
                    const lo = if (native == .little) 0 else 2;
                    m[4 * j + lo] = 8 * h + 2 * j;
                    m[4 * j + lo + 1] = 8 * h + 2 * j + 1;
                }
                break :blk m;
            };
            const w = simd.lookup16(x, @as(V16, idx));
            dst[o + 8 * k + 4 * h ..][0..4].* = @as(@Vector(4, u32), @bitCast(w));
        }
    }
}

// AVX-512 with VBMI and VBMI2: byte permutes across the whole register
// (`vpermb`, `vpermi2b`) and lane compression (`vpcompressb/w/d`), after
// Clausecker and Lemire, "Transcoding Unicode Characters with AVX-512
// Instructions" (2023). With them the kernels need no shuffle tables, and
// masked loads and stores let one loop take every input length, so these
// kernels replace the table-driven ones and the scalar tail on such CPUs.

const v512 = fast_shuffle and simd.has_vbmi and simd.has_vbmi2 and simd.has_bmi2;

/// A funnel shift of 16-bit lanes: `vpshldw` with VBMI2.
extern fn @"llvm.fshl.v32i16"(
    @Vector(32, u16),
    @Vector(32, u16),
    @Vector(32, u16),
) callconv(simd.llvm_cc) @Vector(32, u16);

/// The first step of a long AVX-512 loop over `s`: the units before its
/// first 64-byte boundary, or a whole block when it starts on one or the
/// loop is short. The first block is done whole and the next starts on the
/// boundary, rewriting some units with the same values: a 64-byte access
/// that crosses a cache line costs two, which shows once the data is out of
/// L1 (Latin-1 to UTF-16 at 64 KiB, output 16 bytes off a line: 14.7
/// against 21.5 GB/s).
inline fn firstStep(comptime T: type, s: []const T, len: usize, block: usize) usize {
    if (!v512 or len < 16 * block) return block;
    const addr = @intFromPtr(s.ptr);
    const k = (std.mem.alignForward(usize, addr, 64) - addr) / @sizeOf(T);
    return if (k == 0) block else k;
}

const V64 = @Vector(64, u8);

/// Stores `n` of the 64 bytes of `v` widened to `T` (UTF-16 in byte order
/// `e`) at `dst[o..]`, writing nothing past them.
inline fn storeWidened(comptime T: type, comptime e: Endian, dst: []T, o: usize, v: V64, n: usize) void {
    const lanes = 64 / @sizeOf(T);
    const a: [64]u8 = v;
    inline for (0..64 / lanes) |k| {
        if (k == 0 or n > k * lanes) {
            var w: @Vector(lanes, T) = @as(@Vector(lanes, u8), a[k * lanes ..][0..lanes].*);
            if (T == u16 and e != native) w = @byteSwap(w);
            simd.storePartial(dst[o + k * lanes ..], w, n - k * lanes);
        }
    }
}

/// Widens the 64 bytes at `s` to `T` at `d` (UTF-16 in byte order `e`).
inline fn widenAscii(comptime T: type, comptime e: Endian, s: []const u8, d: []T) void {
    inline for (0..4) |k| storeWide(T, e, d, 16 * k, widenLoad(s[16 * k ..]));
}

/// Loads 16 bytes to widen. On AVX2 a plain load, which folds into
/// `vpmovzx`: widened from a register, each upper half takes a
/// `vextracti128` too, on the same port. Elsewhere volatile, which keeps it
/// one load and two `punpck` where LLVM would fold it into two or four
/// `pmovzx` loads (SSE Latin-1 to UTF-16 1.1x).
inline fn widenLoad(s: []const u8) V16 {
    return if (simd.isa == .avx2) s[0..16].* else simd.loadVolatile(V16, s);
}

/// `f(ct ++ .{ src, dst })`, a kernel's long path: out of line when
/// `apart`, so that the registers its loops save cost the short path before
/// it nothing (LLVM saves them on entry, before any length test), with its
/// `Result` back through `dispatch.pack`, in registers. Apart only in the
/// tier objects (`dispatch.exported`), whose kernels are called out of line
/// anyway, and only for kernels that saved three registers or more: the
/// call costs 64-256-byte inputs about 3 TSC ticks, more than one or two
/// saved registers (docs/slop/results/short-20261101.md).
inline fn longPath(comptime apart: bool, comptime f: anytype, comptime ct: anytype, src: anytype, dst: anytype) Result {
    if (!(apart and dispatch.exported)) return @call(.always_inline, f, ct ++ .{ src, dst });
    const Long = struct {
        fn run(s: @TypeOf(src), d: @TypeOf(dst)) dispatch.Packed(Result) {
            return dispatch.pack(@call(.always_inline, f, ct ++ .{ s, d }));
        }
    };
    return dispatch.unpack(Result, @call(.never_inline, Long.run, .{ src, dst }));
}

/// Combines a checked scalar tail at input `p` and output `o` with the
/// work before it.
inline fn tail(r: Result, p: usize, o: usize) Result {
    // One result built from scalars: choosing between two built ones made
    // LLVM write both fields to the stack and copy the pair with one 16-byte
    // load, which stalls store forwarding (6 ns on a 16-byte input).
    return .{ .err = r.err, .count = r.count + if (r.err == .none) o else p };
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
    if (neon) return anySet(fold(special ^ must23));
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
        storeWide(T, e, dst, o.*, in);
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
    const perm = simd.lookup16(in, simd.loadVolatile(V16, &utf8_windows.shuffles[entry[0]]));
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
            const mask = simd.bitmask(pairs) & 7;
            const s = cp -% splat(U32x4, 0x10000);
            const pair = (splat(U32x4, 0xD800) | s >> splat(U32x4, 10)) |
                (splat(U32x4, 0xDC00) | (s & splat(U32x4, 0x3FF))) << splat(U32x4, 16);
            const units = simd.lookup16(
                @bitCast(@select(u32, pairs, pair, cp)),
                simd.loadVolatile(V16, &utf16_pairs[mask]),
            );
            store(T, e, dst, o.*, @as(U16x8, @bitCast(units)));
            // aarch64 counts bits in a vector register: from a nibble
            // table, it costs no moves there.
            const pairs_n = if (neon) @as(u32, 0x3221_2110) >> @as(u5, mask) * 4 & 0xF else @popCount(mask);
            o.* += 3 + @as(usize, pairs_n);
        }
    }
    return entry[1];
}

// UTF-8 to UTF-16 and UTF-32 with AVX-512: every character of a 64-byte
// block at once. Each byte gets the payload bits a character ending there
// has from its own byte and the two before it, as a 16-bit value split
// into two byte vectors; `vpcompressb` lists the positions where characters
// end, and one `vpermi2b` gathers the values of 32 characters into 16-bit
// lanes. For UTF-16 a four-byte character ends twice: its first three bytes
// make the high surrogate (the code point shifted right by six) and its
// last two the low one.

// The payload bits of a byte, by its high nibble: all seven of ASCII, six
// of a continuation, five, four, or three of a lead.
const utf8_payload = [16]u8{
    0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F,
    0x3F, 0x3F, 0x3F, 0x3F, 0x1F, 0x1F, 0x0F, 0x07,
};

/// Index pairs for `vpermi2b`: lanes 2i and 2i+1 take position i of the
/// half `half` of a 64-byte vector of positions.
fn pairsOf(comptime half: usize) [64]i32 {
    var m: [64]i32 = undefined;
    for (0..32) |i| {
        m[2 * i] = @intCast(32 * half + i);
        m[2 * i + 1] = @intCast(32 * half + i);
    }
    return m;
}

/// How many bytes of the 64 at the start of `src` hold whole characters,
/// from the last few bytes alone, so the next block's load waits on a few
/// scalar loads and not on the block's vector work. The block ends after
/// its last lead's character if that is whole and the byte after it (or the
/// end of the input) starts a character, else before that lead: a
/// character cut off waits for the next block, which reports it if it is
/// too short. Null if no lead is in the last four bytes, which only
/// ill-formed input allows.
inline fn utf8BlockEnd(src: []const u8) ?usize {
    // Volatile: else LLVM takes it from the block's register with two
    // shuffles, which cost UTF-8 to UTF-16 on non-Latin text 25-35%.
    const last = std.mem.littleToNative(u32, @as(*align(1) const volatile u32, @ptrCast(src[60..64])).*);
    // The top bit of each byte that is not a continuation.
    const x = last ^ 0x80808080;
    const leads = (x | x << 1) & 0x80808080;
    if (leads == 0) return null;
    const at = 60 + (31 - @as(usize, @clz(leads))) / 8;
    const lead = src[at];
    const len: usize = if (lead < 0xC0) 1 else if (lead < 0xE0) 2 else if (lead < 0xF0) 3 else 4;
    const next_lead = src.len == 64 or @as(i8, @bitCast(src[64])) >= -64;
    return if (at + len == 64 and next_lead) 64 else at;
}

/// Converts `src` until it ends, an error, or the output runs out, and
/// returns how far it got in each.
fn utf8ToUnitsAvx512(
    comptime T: type,
    comptime e: Endian,
    comptime checked: bool,
    src: []const u8,
    dst: []T,
) struct { usize, usize } {
    @setEvalBranchQuota(10_000);
    const V = V64;
    const W = @Vector(32, u16);
    const zero = splat(V, 0);
    const iota = std.simd.iota(u8, 64);
    const hi_table = comptime blk: {
        var t: [64]u8 = undefined;
        for (&t, 0..) |*x, i| x.* = if (i % 2 == 0) 0 else 64;
        break :blk t;
    };
    var p: usize = 0;
    var o: usize = 0;
    while (p < src.len) {
        const rem = src.len - p;
        const room = dst.len - o;
        var block: V = undefined;
        var take: usize = rem;
        if (rem >= 64) {
            block = simd.load(u8, src[p..]);
            if (below(0x80, block) and room >= 64) {
                // Whole stores: `storeWidened` tests each register's page
                // for a masked store, which cost UTF-32 at 256 bytes 20%.
                store(T, e, dst, o, block);
                p += 64;
                o += 64;
                continue;
            }
        } else {
            block = simd.loadShort(u8, src[p..][0..rem]);
            if (below(0x80, block) and room >= rem) {
                storeWidened(T, e, dst, o, block, rem);
                return .{ src.len, o + rem };
            }
        }
        // A shorter block is zero-padded, so it ends at a boundary (its
        // validation finds a character cut off); a whole one ends at its
        // last whole character.
        if (rem >= 64) take = utf8BlockEnd(src[p..]) orelse break;
        if (checked and utf8Invalid(64, block)) break;
        const leads = leadMask(64, block);
        // Bit i set where byte i ends a character.
        const ends = (leads >> 1 | @as(u64, 1) << 63) & simd.lowBits(u64, take);
        const m4 = simd.bitmask(block >= splat(V, 0xF0));
        const fourth = m4 << 3;
        // For UTF-16, also the third byte of each four-byte character.
        const mend = if (T == u16) ends | (m4 << 2 & ends >> 1) else ends;
        const count: usize = @popCount(mend);
        if (count > room) break;

        const cont = ~leads;
        const s = block & simd.lookup16(utf8_payload, block >> splat(V, 4));
        const s1 = @select(u8, @as(@Vector(64, bool), @bitCast(cont)), simd.prev(1, s, zero), zero);
        const c2 = cont & cont << 1 & if (T == u16) ~fourth else ~@as(u64, 0);
        const s2 = @select(u8, @as(@Vector(64, bool), @bitCast(c2)), simd.prev(2, s, zero), zero);
        // The 16-bit value of a character ending at each byte, low and
        // high halves.
        const lo = s | s1 << splat(V, 6);
        const hi = s1 >> splat(V, 2) | s2 << splat(V, 4);
        const pos = simd.compress(iota, mend);
        // Bit i set where the ith character is a low surrogate, or (for
        // UTF-32) four bytes long.
        const fours = if (m4 != 0) simd.pext(fourth, mend) else 0;
        // UTF-32's bits above 16: the rest of the third-last byte and the
        // lead, at the fourth byte.
        const top = if (T == u32 and m4 != 0) blk: {
            const at4: @Vector(64, bool) = @bitCast(fourth);
            const t = @select(
                u8,
                at4,
                simd.prev(2, s, zero) >> splat(V, 4) | simd.prev(3, s, zero) << splat(V, 2),
                zero,
            );
            break :blk simd.permute(t, pos);
        } else zero;
        inline for (0..2) |half| {
            if (half == 0 or count > 32) {
                const idx = @shuffle(u8, pos, undefined, pairsOf(half)) | @as(V, hi_table);
                var w: W = @bitCast(simd.permute2(lo, idx, hi));
                if (T == u16) {
                    if (m4 != 0) {
                        const low_s: u32 = @truncate(fours >> 32 * half);
                        const high_s: u32 = @truncate(fours >> 32 * half + 1);
                        w = @select(
                            u16,
                            @as(@Vector(32, bool), @bitCast(low_s)),
                            (w & splat(W, 0x3FF)) | splat(W, 0xDC00),
                            w,
                        );
                        w = @select(
                            u16,
                            @as(@Vector(32, bool), @bitCast(high_s)),
                            (w >> splat(W, 4)) +% splat(W, 0xD7C0),
                            w,
                        );
                    }
                    if (e != native) w = @byteSwap(w);
                    simd.storePartial(dst[o + 32 * half ..], w, count - 32 * half);
                } else {
                    const ws: [32]u16 = w;
                    const ts: [64]u8 = top;
                    inline for (0..2) |q| {
                        const k = 32 * half + 16 * q;
                        if (q == 0 or count > k) {
                            var d: @Vector(16, u32) = @as(@Vector(16, u16), ws[16 * q ..][0..16].*);
                            if (m4 != 0) d |= @as(
                                @Vector(16, u32),
                                @as(@Vector(16, u8), ts[k..][0..16].*),
                            ) << splat(@Vector(16, u32), 16);
                            simd.storePartial(dst[o + k ..], d, count - k);
                        }
                    }
                }
            }
        }
        p += take;
        o += count;
    }
    return .{ p, o };
}

// For each 8-bit mask, the shuffle that packs the 16-bit lanes it selects.
const compress_words = blk: {
    @setEvalBranchQuota(100_000);
    var shuffles: [256][16]u8 = undefined;
    for (&shuffles, 0..) |*sh, mask| {
        sh.* = @splat(0x80);
        var o: usize = 0;
        for (0..8) |k| {
            if (mask >> k & 1 == 0) continue;
            sh[2 * o] = 2 * k;
            sh[2 * o + 1] = 2 * k + 1;
            o += 1;
        }
    }
    break :blk shuffles;
};

/// Decodes the characters of a 64-byte block, where bit i of `ends` marks
/// byte i as the last of one, and stores them as UTF-16 in byte order `e`
/// or as UTF-32. As in the AVX-512 kernel, each byte gets the 16-bit value
/// of a character ending there, from its own payload bits and those of the
/// two bytes before it; then each group of eight values packs the ones that
/// end characters with one shuffle from a table. Nothing waits on the
/// length of a character, where each 12-byte window waits on the last
/// one's table lookup. `four`: whether the block has four-byte characters,
/// which for UTF-16 end twice (a high surrogate at the third byte, a low
/// one at the fourth) and for UTF-32 get their top five bits from a second
/// vector packed alongside. Writes 16 bytes (UTF-32: 32) past its output.
inline fn utf8DecodeBlock(
    comptime T: type,
    comptime e: Endian,
    comptime four: bool,
    block: @Vector(64, u8),
    ends: u64,
    dst: []T,
    o: *usize,
) void {
    const V = @Vector(64, u8);
    const zero = splat(V, 0);
    const interleave = comptime blk: {
        var m: [128]i32 = undefined;
        for (0..64) |i| {
            m[2 * i] = @intCast(i);
            m[2 * i + 1] = ~@as(i32, @intCast(i));
        }
        break :blk m;
    };
    const cont = @select(u8, block & splat(V, 0xC0) == splat(V, 0x80), splat(V, 0xFF), zero);
    const lead4 = @select(u8, block >= splat(V, 0xF0), splat(V, 0xFF), zero);
    // The fourth byte of a four-byte character.
    const fourth = if (four) simd.prev(3, lead4, zero) else zero;
    const s = block & simd.lookup16(utf8_payload, block >> splat(V, 4));
    const s1 = simd.prev(1, s, zero) & cont;
    var s2 = simd.prev(2, s, zero) & cont & simd.prev(1, cont, zero);
    if (four and T == u16) s2 &= ~fourth;
    const lo = s | s1 << splat(V, 6);
    const hi = s1 >> splat(V, 2) | s2 << splat(V, 4);
    var words: @Vector(64, u16) = @bitCast(@shuffle(u8, lo, hi, interleave));
    var mend = ends;
    var tops: [64]u16 = undefined;
    if (four) {
        const U = @Vector(64, u16);
        if (T == u16) {
            // Third bytes end high surrogates, fourth bytes low ones.
            mend |= simd.bitmask(block >= splat(V, 0xF0)) << 2 & ends >> 1;
            const lead_at = simd.prev(2, lead4, zero);
            const third: U = @bitCast(@shuffle(u8, lead_at, lead_at, interleave));
            const last: U = @bitCast(@shuffle(u8, fourth, fourth, interleave));
            words = @select(u16, last != splat(U, 0), (words & splat(U, 0x3FF)) | splat(U, 0xDC00), words);
            words = @select(u16, third != splat(U, 0), (words >> splat(U, 4)) +% splat(U, 0xD7C0), words);
        } else {
            // Bits 16 to 20: the rest of the second byte and the lead's.
            const t = (simd.prev(2, s, zero) >> splat(V, 4) | simd.prev(3, s, zero) << splat(V, 2)) & fourth;
            // Through a vector: Zig 0.17 lowers a @bitCast from a vector to
            // an array of another lane type as a loop that shifts the whole
            // 1024-bit value once per lane, 10x slower on this path.
            tops = @as(@Vector(64, u16), @bitCast(@shuffle(u8, t, zero, interleave)));
        }
    }
    const w: [64]u16 = words;
    // On aarch64, which counts bits only in vector registers, every group's
    // count at once and their sums with one multiply: a count per group
    // took two moves between register files.
    const counts: @Vector(8, u8) = if (neon) @popCount(@as(@Vector(8, u8), @bitCast(mend))) else @splat(0);
    const sums = @as(u64, @bitCast(counts)) *% 0x0101_0101_0101_0101;
    const start = o.*;
    inline for (0..8) |g| {
        if (neon and g > 0) o.* = start + @as(u8, @truncate(sums >> 8 * (g - 1)));
        const m: u8 = @truncate(mend >> 8 * g);
        const shuffle = simd.loadVolatile(V16, &compress_words[m]);
        const group: V16 = @bitCast(@as(@Vector(8, u16), w[8 * g ..][0..8].*));
        const packed_words: @Vector(8, u16) = @bitCast(simd.lookup16(group, shuffle));
        if (four and T == u32) {
            const top: V16 = @bitCast(@as(@Vector(8, u16), tops[8 * g ..][0..8].*));
            const packed_tops: @Vector(8, u16) = @bitCast(simd.lookup16(top, shuffle));
            store(
                u32,
                e,
                dst,
                o.*,
                @as(@Vector(8, u32), packed_words) | @as(@Vector(8, u32), packed_tops) << splat(@Vector(8, u32), 16),
            );
        } else {
            store(T, e, dst, o.*, packed_words);
        }
        if (!neon) o.* += @popCount(m);
    }
    if (neon) o.* = start + @as(usize, sums >> 56);
}

/// Decodes the 16 three-byte characters in the first 48 bytes of `src` and
/// stores them as UTF-16 in byte order `e` or as UTF-32.
inline fn utf8DecodeThree(comptime T: type, comptime e: Endian, src: []const u8, dst: []T, o: *usize) void {
    const U = @Vector(4, u32);
    const pick = [16]i32{ 2, 1, 0, -1, 5, 4, 3, -1, 8, 7, 6, -1, 11, 10, 9, -1 };
    if (neon) return utf8DecodeThreeNeon(T, e, 16, src, dst, o);
    inline for (0..4) |q| {
        const x: U = @bitCast(@shuffle(u8, simd.loadVolatile(V16, src[12 * q ..][0..16]), splat(V16, 0), pick));
        store(T, e, dst, o.* + 4 * q, x & splat(U, 0x3F) | (x & splat(U, 0x3F00)) >> splat(U, 2) |
            (x & splat(U, 0x0F0000)) >> splat(U, 4));
    }
    o.* += 16;
}

/// Decodes the `n` three-byte characters in the first `3 * n` bytes of
/// `src`, 16 or 21, and stores them as `utf8DecodeThree` does, writing up
/// to three units past them: four at a time, then one store of them all,
/// which UTF-16 narrows with `uzp1` and stores with `stp`, where each four
/// took an `xtn` and a store of eight bytes. Reads 16 bytes from the start
/// of each four, so up to byte 76 for 21.
inline fn utf8DecodeThreeNeon(
    comptime T: type,
    comptime e: Endian,
    comptime n: usize,
    src: []const u8,
    dst: []T,
    o: *usize,
) void {
    const U = @Vector(4, u32);
    const pick = [16]i32{ 2, 1, 0, -1, 5, 4, 3, -1, 8, 7, 6, -1, 11, 10, 9, -1 };
    var cp: [(n + 3) / 4]U = undefined;
    inline for (&cp, 0..) |*c, q| {
        const x: U = @bitCast(@shuffle(u8, simd.loadVolatile(V16, src[12 * q ..][0..16]), splat(V16, 0), pick));
        c.* = x & splat(U, 0x3F) | (x & splat(U, 0x3F00)) >> splat(U, 2) | (x & splat(U, 0x0F0000)) >> splat(U, 4);
    }
    store(T, e, dst, o.*, @as(@Vector(4 * cp.len, u32), @bitCast(cp)));
    o.* += n;
}

extern fn @"llvm.aarch64.neon.tbl2.v16i8"(V16, V16, V16) callconv(simd.llvm_cc) V16;
extern fn @"llvm.aarch64.neon.vsli.v8i16"(@Vector(8, u16), @Vector(8, u16), i32) callconv(simd.llvm_cc) @Vector(8, u16);

/// The eight three-byte characters in the first 24 bytes of `src`, as
/// 16-bit code points, on little-endian NEON. Byte j of the 24 is lane j
/// of the table below 16 and lane j + 8 above, from loads at 0 and 8.
inline fn utf8ThreeEight(src: []const u8) struct { @Vector(8, u16), @Vector(8, u16) } {
    const U = @Vector(8, u16);
    const at = struct {
        fn f(comptime j: usize) u8 {
            return if (j < 16) j else j + 8;
        }
    }.f;
    // Lane i: the lead (1110aaaa) and the last byte (10cccccc).
    const lead_last = comptime blk: {
        var m: [16]u8 = undefined;
        for (0..8) |i| {
            m[2 * i] = at(3 * i);
            m[2 * i + 1] = at(3 * i + 2);
        }
        break :blk m;
    };
    // Lane i: the middle byte (10bbbbbb).
    const middle = comptime blk: {
        var m: [16]u8 = undefined;
        for (0..8) |i| {
            m[2 * i] = at(3 * i + 1);
            m[2 * i + 1] = at(3 * i + 1);
        }
        break :blk m;
    };
    const a = simd.loadVolatile(V16, src[0..16]);
    const b = simd.loadVolatile(V16, src[8..24]);
    const tbl2 = @"llvm.aarch64.neon.tbl2.v16i8";
    const sli = @"llvm.aarch64.neon.vsli.v8i16";
    const ll: U = @bitCast(tbl2(a, b, lead_last));
    const mm: U = @bitCast(tbl2(a, b, middle));
    // xxaaaabb bbbb: the lead above the middle byte's six bits; then
    // aaaabbbb bbcccccc above the last byte's six, which the lane's swapped
    // bytes hold low. What the shifts push past bit 15 is gone.
    const hi = sli(mm, ll, 6);
    const last: U = @bitCast(@shuffle(u8, @as(V16, @bitCast(ll)), undefined, [16]i32{ 1, 0, 3, 2, 5, 4, 7, 6, 9, 8, 11, 10, 13, 12, 15, 14 }));
    return .{ sli(last, hi, 6), ll };
}

/// Decodes the 64-byte block at `src`, of which `take` bytes end on a
/// character and `leads` marks the bytes that start one, when it opens
/// with up to eight ASCII bytes and then three-byte characters: to `take`,
/// if they reach it and it is at least 32, in groups of eight characters;
/// otherwise, if there are at least eight, in 12-byte windows up to `take`.
/// Returns how far it got, 0 if `checked` and the bytes are not valid
/// UTF-8 (having written nothing it counts), or null, having done nothing,
/// if the block has neither shape. Chinese and Japanese, with a space or
/// ASCII punctuation every so often, decode here, checked on their decoded
/// values where the block's validation takes twice the operations; Korean,
/// whose words are short, does not. The shape comes from `leads`: two
/// leads in a row make the first ASCII (or invalid), and a lead every three
/// bytes three-byte characters (or invalid ones). Reads up to 80 bytes of
/// `src` and writes up to 80 units at `o`.
inline fn utf8AsciiThree(
    comptime T: type,
    comptime e: Endian,
    comptime checked: bool,
    src: []const u8,
    leads: u64,
    take: usize,
    dst: []T,
    o: *usize,
) ?usize {
    const three: u64 = 0x9249_2492_4924_9249;
    const a = @as(usize, @ctz(~leads)) -| 1;
    if (a > 8 or take < 32) return null;
    const whole: u64 = if (take == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(take)) - 1;
    const head_shape = (@as(u64, 1) << @intCast(a)) - 1;
    const t = (take - a) / 3;
    if (a + 3 * t == take and (leads ^ (head_shape | three << @intCast(a))) & whole == 0) {
        const head = simd.loadVolatile(V16, src[0..16]);
        const run = utf8ThreeRun(checked, src, a, t);
        if (checked and anySet(run.bad | asciiBad(head, a))) return 0;
        storeWide(T, e, dst, o.*, head);
        inline for (run.cps, 0..) |cp, g| store(T, e, dst, o.* + a + 8 * g, cp);
        o.* += a + t;
        return take;
    }
    // Otherwise windows, when the run is at least eight characters long,
    // with four three-byte characters tested first and checked on their
    // values, and the other windows validated one by one: validating the
    // block first cost CJK text 3%.
    const t1 = (@as(usize, @ctz((leads >> @intCast(a)) ^ three)) -| 1) / 3;
    if (t1 < 8) return null;
    const ends = (leads >> 1 | @as(u64, 1) << 63) & whole;
    const start = o.*;
    var bad: @Vector(8, u16) = @splat(0);
    var pos: usize = 0;
    while (pos + 12 <= take) {
        const in = simd.loadVolatile(V16, src[pos..]);
        const m = ends >> @intCast(pos);
        if (m & 0xFFF == 0x924) {
            const cp, const ll = utf8FourThree(T, e, in, dst, o.*);
            if (checked) bad |= utf8ThreeBad(cp, ll);
            o.* += 4;
            pos += 12;
            continue;
        }
        if (checked and utf8Invalid(16, in)) {
            o.* = start;
            return 0;
        }
        pos += utf8Window(T, e, in, m, dst, o);
    }
    if (checked and anySet(bad)) {
        o.* = start;
        return 0;
    }
    return pos;
}

/// Stores the four three-byte characters in the first 12 bytes of `in` at
/// `dst[o..]`, as `utf8ThreeEight` decodes eight, as UTF-16 in byte order
/// `e` or as UTF-32.
inline fn utf8FourThree(comptime T: type, comptime e: Endian, in: V16, dst: []T, o: usize) struct { @Vector(8, u16), @Vector(8, u16) } {
    const U = @Vector(8, u16);
    const sli = @"llvm.aarch64.neon.vsli.v8i16";
    const ll: U = @bitCast(simd.lookup16(in, @as(V16, .{ 0, 2, 3, 5, 6, 8, 9, 11, 0, 2, 3, 5, 6, 8, 9, 11 })));
    const mm: U = @bitCast(simd.lookup16(in, @as(V16, .{ 1, 1, 4, 4, 7, 7, 10, 10, 1, 1, 4, 4, 7, 7, 10, 10 })));
    const last: U = @bitCast(@shuffle(u8, @as(V16, @bitCast(ll)), undefined, [16]i32{ 1, 0, 3, 2, 5, 4, 7, 6, 9, 8, 11, 10, 13, 12, 15, 14 }));
    const cp = sli(last, sli(mm, ll, 6), 6);
    store(T, e, dst, o, @shuffle(u16, cp, undefined, [4]i32{ 0, 1, 2, 3 }));
    return .{ cp, ll };
}

/// The 24 three-byte characters from `src[at..]`, of which the first `t`
/// count, and where `checked`, the lanes of those that are not valid: a
/// lead that is not 1110____, an overlong form, or a surrogate. Groups
/// that would start past byte 64 read from it instead.
inline fn utf8ThreeRun(comptime checked: bool, src: []const u8, at: usize, t: usize) struct { cps: [3]@Vector(8, u16), bad: @Vector(8, u16) } {
    const U = @Vector(8, u16);
    var cps: [3]U = undefined;
    var bad: U = @splat(0);
    inline for (&cps, 0..) |*cp, k| {
        cp.*, const ll = utf8ThreeEight(src[@min(at + 24 * k, 64)..]);
        if (checked) {
            const in_run = std.simd.iota(u16, 8) + splat(U, 8 * k) < @as(U, @splat(@intCast(t)));
            bad |= utf8ThreeBad(cp.*, ll) & @select(u16, in_run, splat(U, 0xFFFF), splat(U, 0));
        }
    }
    return .{ .cps = cps, .bad = bad };
}

/// The lanes of three-byte characters, decoded to `cp` from leads in the
/// low bytes of `ll`, that are not valid: a lead that is not 1110____, an
/// overlong form, or a surrogate.
inline fn utf8ThreeBad(cp: @Vector(8, u16), ll: @Vector(8, u16)) @Vector(8, u16) {
    const U = @Vector(8, u16);
    const ones = splat(U, 0xFFFF);
    const zero = splat(U, 0);
    return @select(u16, (ll & splat(U, 0xF0)) != splat(U, 0xE0), ones, zero) |
        @select(u16, cp < splat(U, 0x800), ones, zero) |
        @select(u16, (cp & splat(U, 0xF800)) == splat(U, 0xD800), ones, zero);
}

/// Bytes of `v`'s first `n` lanes with the top bit set, as 16-bit lanes
/// that are nonzero where one is.
inline fn asciiBad(v: V16, n: usize) @Vector(8, u16) {
    const in_head = std.simd.iota(u8, 16) < @as(V16, @splat(@intCast(n)));
    return @bitCast(@select(u8, in_head, v, splat(V16, 0)) & splat(V16, 0x80));
}

/// Decodes the 16 four-byte characters of `block`, one every four bytes,
/// and stores them as UTF-16 in byte order `e` or as UTF-32: each 32-bit
/// lane holds one character, its bytes reversed in place.
inline fn utf8DecodeFour(comptime T: type, comptime e: Endian, block: @Vector(64, u8), dst: []T, o: *usize) void {
    const U = @Vector(16, u32);
    const rev = comptime blk: {
        var m: [64]i32 = undefined;
        for (&m, 0..) |*x, i| x.* = @intCast(i / 4 * 4 + 3 - i % 4);
        break :blk m;
    };
    const x: U = @bitCast(@shuffle(u8, block, undefined, rev));
    const cp = (x & splat(U, 0x3F)) | (x & splat(U, 0x3F00)) >> splat(U, 2) |
        (x & splat(U, 0x3F_0000)) >> splat(U, 4) | (x & splat(U, 0x0700_0000)) >> splat(U, 6);
    if (T == u32) {
        store(T, e, dst, o.*, cp);
        o.* += 16;
        return;
    }
    // Each pair in its character's lane, the high surrogate first.
    const s = cp -% splat(U, 0x10000);
    const pairs = (splat(U, 0xD800) | s >> splat(U, 10)) | (splat(U, 0xDC00) | (s & splat(U, 0x3FF))) << splat(U, 16);
    store(T, e, dst, o.*, @as(@Vector(32, u16), @bitCast(pairs)));
    o.* += 32;
}

/// The 64-byte blocks of `src`, on Apple cores, from the start until fewer
/// than 64 bytes or units are left or a block that is not valid UTF-8: how
/// far it got in each.
inline fn utf8BlocksApple(comptime T: type, comptime e: Endian, comptime checked: bool, src: []const u8, dst: []T) struct { usize, usize } {
    var p: usize = 0;
    var o: usize = 0;
    while (src.len - p >= 64 and dst.len - o >= 64) {
        const block = simd.load(u8, src[p..]);
        if (below(0x80, block)) {
            widenAscii(T, e, src[p..], dst[o..]);
            p += 64;
            o += 64;
            var k = @min(src.len - p, dst.len - o) / 64;
            while (k > 0) : (k -= 1) {
                if (!below(0x80, simd.load(u8, src[p..]))) break;
                widenAscii(T, e, src[p..], dst[o..]);
                p += 64;
                o += 64;
            }
            continue;
        }
        const room = src.len - p >= 64 + 16 and dst.len - o >= 64 + 16;
        // UTF-16 without the room below fails its test for certain:
        // before the work for it, which cost 64-byte inputs 5%.
        if (!room and T == u16 and dst.len - o < 64 + 8) break;
        // The block's end first: a few scalar loads, which the next
        // block's load then waits on, where a count from the
        // block's lane mask would make it wait on the block's
        // vector work (21 three-byte characters a block, 0.64x).
        const take = utf8BlockEnd(src[p..]) orelse break;
        const leads = leadMask(64, block);
        // The last 64 to 79 bytes still decode as a block, where windows
        // took longer, but not as runs, which read past it, and only
        // with room for the eight units `utf8DecodeBlock` writes past
        // its output: one unit per character for UTF-32, at most one per
        // byte for UTF-16.
        const whole: u64 = if (take == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(take)) - 1;
        if (!room and dst.len - o < (if (T == u32) @popCount(leads & whole) else take) + 8) break;
        if (room) if (utf8AsciiThree(T, e, checked, src[p..], leads, take, dst, &o)) |n| {
            if (n == 0) break;
            p += n;
            continue;
        };
        if (checked and utf8Invalid(64, block)) break;
        if (leads == 0x1111_1111_1111_1111) {
            utf8DecodeFour(T, e, block, dst, &o);
            p += 64;
            continue;
        }
        // Blocks with four-byte characters too: on these cores
        // `utf8DecodeBlock` decodes emoji text 1.9x as fast as
        // windows.
        const ends = (leads >> 1 | @as(u64, 1) << 63) & whole;
        if (anyTrue(u8, block >= splat(@Vector(64, u8), 0xF0)))
            utf8DecodeBlock(T, e, true, block, ends, dst, &o)
        else
            utf8DecodeBlock(T, e, false, block, ends, dst, &o);
        p += take;
    }
    return .{ p, o };
}

fn utf8ToUnitsLong(comptime T: type, comptime e: Endian, comptime checked: bool, src: []const u8, dst: []T) Result {
    const p, const o = utf8ToUnitsAvx512(T, e, checked, src, dst);
    if (T == u16) {
        if (checked) return tail(scalar.utf8ToUtf16(e, src[p..], dst[o..]), p, o);
        return .ok(o + scalar.validUtf8ToUtf16(e, src[p..], dst[o..]));
    }
    if (checked) return tail(scalar.utf8ToUtf32(src[p..], dst[o..]), p, o);
    return .ok(o + scalar.validUtf8ToUtf32(src[p..], dst[o..]));
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
    if (v512) {
        // Up to 64 ASCII bytes, before the loop loads its constants: set
        // up first, they cost every short call 2-4 ns.
        if (src.len <= 64 and src.len <= dst.len) {
            const block = simd.loadShort(u8, src);
            if (below(0x80, block)) {
                if (src.len > 0) storeWidened(T, e, dst, 0, block, src.len);
                return .ok(src.len);
            }
        }
        return longPath(true, utf8ToUnitsLong, .{ T, e, checked }, src, dst);
    }
    var p: usize = 0;
    var o: usize = 0;
    var steps: Steps = .{};
    if (use_simd) while (true) {
        if (apple) {
            if (src.len >= 64 and dst.len >= 64) p, o = utf8BlocksApple(T, e, checked, src, dst);
        } else
        // A block writes at most one code unit per byte, and a window's last
        // store reaches at most eight past its output, and loads 16 bytes
        // from as far as byte 51: an ASCII block needs neither.
        while (src.len - p >= 64 and dst.len - o >= 64) {
            const block = simd.load(u8, src[p..]);
            if (below(0x80, block)) {
                widenAscii(T, e, src[p..], dst[o..]);
                p += 64;
                o += 64;
                // A run of ASCII in a loop of its own, with one bound: as
                // a branch of this loop it took three jumps a block.
                var k = @min(src.len - p, dst.len - o) / 64;
                while (k > 0) : (k -= 1) {
                    if (!below(0x80, simd.load(u8, src[p..]))) break;
                    widenAscii(T, e, src[p..], dst[o..]);
                    p += 64;
                    o += 64;
                }
                continue;
            }
            if (!fast_shuffle) {
                break;
            }
            if (src.len - p < 64 + 16 or dst.len - o < 64 + 16) break;
            if (checked and utf8Invalid(64, block)) break;
            const leads = leadMask(64, block);
            if (neon) {
                // Runs of one length first, before the block's end is
                // found: 21 three-byte characters, the whole block's, or
                // sixteen, as below, or sixteen four-byte ones, which a
                // lead every four bytes means in valid (or validated)
                // input. The units written past 21 are written again.
                if (leads == 0x9249_2492_4924_9249) {
                    utf8DecodeThreeNeon(T, e, 21, src[p..], dst, &o);
                    p += 63;
                    continue;
                }
                if (leads & 0x1_FFFF_FFFF_FFFF == 0x1_2492_4924_9249) {
                    utf8DecodeThreeNeon(T, e, 16, src[p..], dst, &o);
                    p += 48;
                    continue;
                }
                if (leads == 0x1111_1111_1111_1111) {
                    utf8DecodeFour(T, e, block, dst, &o);
                    p += 64;
                    continue;
                }
            }
            const take = utf8BlockEnd(src[p..]) orelse break;
            const whole: u64 = if (take == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(take)) - 1;
            // On NEON another block with four-byte characters decodes in
            // 12-byte windows, as simdutf's arm64 kernel decodes every
            // block, where `utf8DecodeBlock` takes twice the vector
            // operations (emoji, before the run above: 1.1x to UTF-16,
            // 1.8x to UTF-32); on text without them windows lose 15-20%.
            // Each window starts on a character and sees twelve bytes of
            // the block's ends, which hold at least three whole
            // characters; the rest of the block goes again.
            const neon_four = neon and anyTrue(u8, block >= splat(@Vector(64, u8), 0xF0));
            if (neon_four) {
                const ends = (leads >> 1 | @as(u64, 1) << 63) & whole;
                var pos: usize = 0;
                while (pos + 12 <= take) {
                    const in = simd.loadVolatile(V16, src[p + pos ..]);
                    pos += utf8Window(T, e, in, ends >> @intCast(pos), dst, &o);
                }
                p += pos;
                continue;
            }
            // Sixteen three-byte characters first: a fixed shuffle for each
            // four, and no table. The rest of the block goes again.
            if (leads & 0x1_FFFF_FFFF_FFFF == 0x1_2492_4924_9249) {
                utf8DecodeThree(T, e, src[p..], dst, &o);
                p += 48;
                continue;
            }
            const ends = (leads >> 1 | @as(u64, 1) << 63) & whole;
            if (neon or simd.bitmask(block >= splat(@Vector(64, u8), 0xF0)) & whole == 0)
                utf8DecodeBlock(T, e, false, block, ends, dst, &o)
            else
                utf8DecodeBlock(T, e, true, block, ends, dst, &o);
            p += take;
        }
        while (src.len - p >= 16 and dst.len - o >= 16) {
            const w = simd.load16(src[p..]);
            if (below(0x80, w)) {
                storeWide(T, e, dst, o, w);
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
    dst[o..][0..16].* = simd.lookup16(v, simd.loadVolatile(V16, &compress8[lo]));
    dst[o + n_lo ..][0..16].* = simd.lookup16(v, simd.loadVolatile(V16, &compress8[hi]) +% splat(V16, 8));
    return n_lo + @popCount(hi);
}

fn utf8ToLatin1Avx512(comptime checked: bool, src: []const u8, dst: []u8) struct { usize, usize } {
    // Whole blocks, then at most one partial block, each its own copy of
    // the step, so the loop tests no lengths but its own.
    var p: usize = 0;
    var o: usize = 0;
    const done = while (src.len - p >= 64) {
        if (!utf8ToLatin1Step(checked, true, src, dst, &p, &o)) break false;
    } else p == src.len or utf8ToLatin1Step(checked, false, src, dst, &p, &o);
    // A block that stopped after a lead byte left its character to the
    // scalar code, which also finds any error from there.
    if (!done and p > 0 and src[p - 1] >= 0xC0) p -= 1;
    return .{ p, o };
}

/// One step of UTF-8 to Latin-1 at `src[p.*..]`: a block of 64 bytes when
/// `full`, else the rest of the input, in one load, masked. Advances `p`
/// and `o` and returns true, or returns false where the scalar code must
/// take over. A two-byte character decodes at its continuation byte, from
/// the byte before it, which for byte 0 is the last of the block before: a
/// load at `p - 1`, not a carry through the loop.
inline fn utf8ToLatin1Step(
    comptime checked: bool,
    comptime full: bool,
    src: []const u8,
    dst: []u8,
    p: *usize,
    o: *usize,
) bool {
    const V = V64;
    const rem = src.len - p.*;
    const n = if (full) 64 else rem;
    const v: V = if (full) simd.load(u8, src[p.*..]) else simd.loadShort(u8, src[p.*..]);
    // ASCII, unless it follows a lead byte, which the checked form must
    // report.
    if (below(0x80, v) and !(checked and p.* > 0 and src[p.* - 1] >= 0xC0)) {
        if (dst.len - o.* >= 64) {
            store(u8, native, dst, o.*, v);
        } else if (n <= dst.len - o.*) {
            simd.storePartial(dst[o.*..], v, n);
        } else return false;
        p.* += n;
        o.* += n;
        // A long run of ASCII, two blocks a step.
        if (full) while (src.len - p.* >= 128 and dst.len - o.* >= 128) {
            const a = simd.load(u8, src[p.*..]);
            const b = simd.load(u8, src[p.* + 64 ..]);
            if (!below(0x80, a | b)) break;
            store(u8, native, dst, o.*, a);
            store(u8, native, dst, o.* + 64, b);
            p.* += 128;
            o.* += 128;
        };
        return true;
    }
    const before: V = if (p.* == 0)
        simd.prev(1, v, splat(V, 0))
    else if (full)
        simd.load(u8, src[p.* - 1 ..])
    else
        simd.loadShort(u8, src[p.* - 1 ..][0..n]);
    const live = if (full) ~@as(u64, 0) else simd.lowBits(u64, n);
    // The bytes to keep: all but the leads, which are 0xC0 and up.
    const keep = simd.bitmask(v < splat(V, 0xC0)) & live;
    if (checked) {
        // Only C2 and C3 lead characters that fit Latin-1, each followed
        // by exactly one continuation; a lead in the last byte of the
        // input is cut short.
        const lead = ~keep & live;
        const cont = simd.bitmask(v & splat(V, 0xC0) == splat(V, 0x80));
        const latin = simd.bitmask(v & splat(V, 0xFE) == splat(V, 0xC2));
        const after = simd.bitmask(before & splat(V, 0xFE) == splat(V, 0xC2));
        const end = if (n == rem) @as(u64, 1) << @intCast(n - 1) else 0;
        if (((lead & ~latin) | (cont ^ after) | (lead & end)) & live != 0) return false;
    }
    // A continuation byte after C2 is the character; after C3 it is 0x40
    // more, which sets its bit 6. Valid input has no other lead, and
    // nothing but a continuation after one.
    const c3: @Vector(64, bool) = @bitCast(simd.bitmask(before == splat(V, 0xC3)));
    const decoded = @select(u8, c3, v ^ splat(V, 0x40), v);
    const count: usize = @popCount(keep);
    if (count > dst.len - o.*) return false;
    // A whole store where the buffer has room: the bytes past `count` are
    // rewritten by the next block or left past the result.
    if (dst.len - o.* >= 64)
        store(u8, native, dst, o.*, simd.compress(decoded, keep))
    else
        simd.storePartial(dst[o.*..], simd.compress(decoded, keep), count);
    p.* += n;
    o.* += count;
    return true;
}

fn utf8ToLatin1Long(comptime checked: bool, src: []const u8, dst: []u8) Result {
    const p, const o = utf8ToLatin1Avx512(checked, src, dst);
    if (checked) return tail(scalar.utf8ToLatin1(src[p..], dst[o..]), p, o);
    return .ok(o + scalar.validUtf8ToLatin1(src[p..], dst[o..]));
}

fn utf8ToLatin1Impl(comptime checked: bool, src: []const u8, dst: []u8) Result {
    const run = struct {
        fn f(s: []const u8, d: []u8) Result {
            if (checked) return scalar.utf8ToLatin1(s, d);
            return .ok(scalar.validUtf8ToLatin1(s, d));
        }
    }.f;
    if (v512) {
        // Up to a block in one masked step.
        if (src.len <= 64) {
            if (src.len == 0) return .ok(0);
            var p: usize = 0;
            var o: usize = 0;
            if (utf8ToLatin1Step(checked, false, src, dst, &p, &o)) return .ok(o);
        }
        return longPath(true, utf8ToLatin1Long, .{checked}, src, dst);
    }
    var p: usize = 0;
    var o: usize = 0;
    var steps: Steps = .{};
    if (use_simd) while (true) {
        while (src.len - p >= 16 and dst.len - o >= 32) {
            if (src.len - p >= 64 and dst.len - o >= 64) {
                const block = simd.load(u8, src[p..]);
                if (below(0x80, block)) {
                    store(u8, native, dst, o, block);
                    p += 64;
                    o += 64;
                    // A run of ASCII in a loop of its own, with one bound,
                    // as in `utf8ToUnits`.
                    var k = @min(src.len - p, dst.len - o) / 64;
                    while (k > 0) : (k -= 1) {
                        const b = simd.load(u8, src[p..]);
                        if (!below(0x80, b)) break;
                        store(u8, native, dst, o, b);
                        p += 64;
                        o += 64;
                    }
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
    // Signed, one instruction without AVX-512: the lanes are below 0x800.
    const ascii = @as(@Vector(8, i16), @bitCast(v)) < splat(@Vector(8, i16), 0x80);
    const two = (splat(U, 0xC0) | v >> splat(U, 6)) | (splat(U, 0x80) | (v & splat(U, 0x3F))) << splat(U, 8);
    const mask: u8 = simd.bitmask(ascii);
    const lanes: [16]u8 = @bitCast(@select(u16, ascii, v, two));
    dst[o.*..][0..16].* = simd.lookup16(lanes, simd.loadVolatile(V16, &utf8_pack2.shuffles[mask]));
    o.* += utf8_pack2.lens[mask];
}

/// All ones in each lane `b` sets, as 16-bit lanes.
inline fn ones16(b: @Vector(16, bool)) @Vector(16, u16) {
    return @select(u16, b, splat(@Vector(16, u16), 0xFFFF), splat(@Vector(16, u16), 0));
}

/// Whether a byte shuffle can take 32 bytes, as two 16-byte lanes that each
/// look up their own bytes: then two groups of the 16-byte encoders below
/// pack in one shuffle, and the upper group stores straight from the
/// register, where taking it out first costs another shuffle-port
/// operation.
const wide_shuffle = fast_shuffle and (simd.isa == .avx2 or simd.isa == .avx512);

/// Encodes 16 code points below U+0800 as UTF-8 at `dst[o.*..]`. Writes 16
/// bytes past the start of each half's output.
inline fn utf8From2x16(v: @Vector(16, u16), dst: []u8, o: *usize) void {
    if (!wide_shuffle) {
        const a: [16]u16 = v;
        utf8From2(a[0..8].*, dst, o);
        utf8From2(a[8..16].*, dst, o);
        return;
    }
    const U = @Vector(16, u16);
    const ascii = @as(@Vector(16, i16), @bitCast(v)) < splat(@Vector(16, i16), 0x80);
    const two = (splat(U, 0xC0) | v >> splat(U, 6)) | (splat(U, 0x80) | (v & splat(U, 0x3F))) << splat(U, 8);
    // Each unit's two bits of the byte mask, where packing the compare to
    // bytes first takes two more shuffle-port operations.
    const bytes: u32 = simd.bitmask(@as(@Vector(32, i8), @bitCast(ones16(ascii))) < splat(@Vector(32, i8), 0));
    const lo: u8 = @intCast(if (simd.has_bmi2) simd.pext(bytes, 0x5555) else simd.bitmask(ascii) & 0xFF);
    const hi: u8 = @intCast(if (simd.has_bmi2) simd.pext(bytes, 0x55550000) else simd.bitmask(ascii) >> 8);
    const t = &utf8_pack2.shuffles;
    const idx: @Vector(32, u8) = @bitCast([2]V16{ simd.loadVolatile(V16, &t[lo]), simd.loadVolatile(V16, &t[hi]) });
    const out: [32]u8 = simd.shuffleLanes(@as(@Vector(32, u8), @bitCast(@select(u16, ascii, v, two))), idx);
    dst[o.*..][0..16].* = out[0..16].*;
    o.* += utf8_pack2.lens[lo];
    dst[o.*..][0..16].* = out[16..32].*;
    o.* += utf8_pack2.lens[hi];
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
            // Bytes as `bmpBytes` lays them out.
            const n = 1 + (i >> k & 1) + (i >> (k + 4) & 1);
            const order: []const u8 = switch (n) {
                1 => &.{0},
                2 => &.{ 3, 1 },
                else => &.{ 2, 3, 1 },
            };
            for (order, 0..) |b, j| s[o + j] = @intCast(4 * k + b);
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
/// in four groups of four lanes, any of them four bytes long. Writes 16
/// bytes past the start of each group's output.
inline fn utf8From16(cp: @Vector(16, u32), take: u16, dst: []u8, o: *usize) void {
    const W = @Vector(16, u32);
    const ge80 = cp >= splat(W, 0x80);
    const ge800 = cp >= splat(W, 0x800);
    const ge10000 = cp >= splat(W, 0x10000);
    const c0 = splat(W, 0x80) | (cp & splat(W, 0x3F));
    const c1 = splat(W, 0x80) | (cp >> splat(W, 6) & splat(W, 0x3F));
    const c2 = splat(W, 0x80) | (cp >> splat(W, 12) & splat(W, 0x3F));
    const b2 = (splat(W, 0xC0) | cp >> splat(W, 6)) | c0 << splat(W, 8);
    const b3 = (splat(W, 0xE0) | cp >> splat(W, 12)) | c1 << splat(W, 8) | c0 << splat(W, 16);
    const b4 = (splat(W, 0xF0) | cp >> splat(W, 18)) | c2 << splat(W, 8) | c1 << splat(W, 16) | c0 << splat(W, 24);
    const bytes = @select(u32, ge10000, b4, @select(u32, ge800, b3, @select(u32, ge80, b2, cp)));
    // A lane's byte count is 1 for being taken, plus 1 for each threshold
    // it reaches.
    const m1 = simd.bitmask(ge80) & take;
    const m2 = simd.bitmask(ge800) & take;
    const m4 = simd.bitmask(ge10000) & take;
    const b: [16]u32 = bytes;
    inline for (0..4) |g| {
        const sh = 4 * g;
        const lanes: @Vector(4, u32) = b[sh..][0..4].*;
        const i = @as(usize, base5[take >> sh & 15]) + base5[m1 >> sh & 15] +
            base5[m2 >> sh & 15] + base5[m4 >> sh & 15];
        dst[o.*..][0..16].* = simd.lookup16(@bitCast(lanes), simd.loadVolatile(V16, &utf8_pack4.shuffles[i]));
        o.* += utf8_pack4.lens[i];
    }
}

/// The code points of the surrogate pairs that fill `v` with each high
/// surrogate in an even lane, as text above U+FFFF has them, or null. Each
/// pair is one 32-bit lane, so it decodes in place, with no shuffle.
inline fn alignedPairs(v: anytype) ?@Vector(@typeInfo(@TypeOf(v)).vector.len / 2, u32) {
    const n = @typeInfo(@TypeOf(v)).vector.len;
    const U = @Vector(n, u16);
    const D = @Vector(n / 2, u32);
    const M = @Int(.unsigned, n);
    const hi: M = simd.bitmask(v & splat(U, 0xFC00) == splat(U, 0xD800));
    const lo: M = simd.bitmask(v & splat(U, 0xFC00) == splat(U, 0xDC00));
    if (hi != ~@as(M, 0) / 3 or lo != ~@as(M, 0) / 3 * 2) return null;
    const d: D = @bitCast(v);
    const bias: u32 = @bitCast(@as(i32, 0x10000 - (0xD800 << 10) - 0xDC00));
    return (d << splat(D, 10) & splat(D, 0x3FFFC00)) +% (d >> splat(D, 16)) +% splat(D, bias);
}

/// Encodes code points above U+FFFF, four bytes of UTF-8 each, at
/// `dst[o.*..]`: each lane holds its bytes in order.
inline fn utf8FromFour(cp: anytype, dst: []u8, o: *usize) void {
    const n = @typeInfo(@TypeOf(cp)).vector.len;
    const D = @Vector(n, u32);
    const b = (splat(D, 0xF0) | cp >> splat(D, 18)) |
        (splat(D, 0x80) | (cp >> splat(D, 12) & splat(D, 0x3F))) << splat(D, 8) |
        (splat(D, 0x80) | (cp >> splat(D, 6) & splat(D, 0x3F))) << splat(D, 16) |
        (splat(D, 0x80) | (cp & splat(D, 0x3F))) << splat(D, 24);
    store(u8, native, dst, o.*, @as(@Vector(4 * n, u8), @bitCast(b)));
    o.* += 4 * n;
}

/// Each unit of `v`'s candidate UTF-8 bytes, below U+10000, in two 16-bit
/// lanes, as simdutf lays them out: the first holds its low seven bits (a
/// one-byte character) then its last continuation byte; the second the
/// lead byte of three, then the lead byte of two where `lt800` is set and
/// the middle continuation byte of three where not. Unpacked to 32-bit
/// lanes by `unpackBmp`, a character is byte 0; bytes 3 and 1; or bytes 2,
/// 3, and 1. Ten operations and no blend, where building the bytes in order
/// took fifteen, two of them blends.
inline fn bmpBytes(v: @Vector(16, u16), lt800: @Vector(16, bool)) [2]@Vector(16, u16) {
    const U = @Vector(16, u16);
    // Each unit's low byte twice.
    const dup = comptime blk: {
        var m: [32]i32 = undefined;
        for (&m, 0..) |*x, i| x.* = i / 2 * 2;
        break :blk m;
    };
    const low: U = @bitCast(@shuffle(u8, @as(@Vector(32, u8), @bitCast(v)), undefined, dup));
    const lead = ((v << splat(U, 2)) & splat(U, 0x3F00) | v >> splat(U, 12)) | splat(U, 0xC0E0);
    return .{
        low & splat(U, 0x3F7F) | splat(U, 0x8000),
        lead ^ @select(u16, lt800, splat(U, 0), splat(U, 0x4000)),
    };
}

/// `bmpBytes`' two vectors as four groups of four 32-bit lanes, units 0-3,
/// 4-7, 8-11, and 12-15: the first and third in the 16-byte halves of the
/// first vector and the others in those of the second, as `punpcklwd` and
/// `punpckhwd` lay them out in each 128-bit half.
inline fn unpackBmp(b: [2]@Vector(16, u16)) [2]@Vector(32, u8) {
    const mask = struct {
        fn f(comptime high: bool) [16]i32 {
            var m: [16]i32 = undefined;
            for (0..2) |h| for (0..4) |k| {
                const i = 8 * h + k + if (high) 4 else 0;
                m[8 * h + 2 * k] = i;
                m[8 * h + 2 * k + 1] = ~@as(i32, i);
            };
            return m;
        }
    }.f;
    return .{
        @bitCast(@shuffle(u16, b[0], b[1], mask(false))),
        @bitCast(@shuffle(u16, b[0], b[1], mask(true))),
    };
}

/// Encodes 16 code points from U+0800 to U+FFFF, each three bytes of
/// UTF-8, at `dst[o.*..]`: a fixed shuffle takes bytes 2, 3, and 1 of each
/// of `bmpBytes`' lanes, where mixed lengths need a table. Writes 52 bytes.
inline fn utf8From16Three(v: @Vector(16, u16), dst: []u8, o: *usize) void {
    const lanes = unpackBmp(bmpBytes(v, @splat(false)));
    const three = comptime blk: {
        const order = [3]usize{ 2, 3, 1 };
        var m: [32]i32 = undefined;
        for (0..2) |h| for (0..16) |j| {
            m[16 * h + j] = @intCast(16 * h + if (j < 12) 4 * (j / 3) + order[j % 3] else 0);
        };
        break :blk m;
    };
    if (neon) {
        // One `tbl` and one volatile store per group: else LLVM merges the
        // overlapping stores into byte moves and two-register lookups.
        const l = [2][2]V16{ @bitCast(lanes[0]), @bitCast(lanes[1]) };
        const idx: V16 = comptime blk: {
            var t: [16]u8 = undefined;
            for (&t, three[0..16]) |*x, m| x.* = m;
            break :blk t;
        };
        inline for ([4]V16{ l[0][0], l[1][0], l[0][1], l[1][1] }, 0..) |part, g|
            simd.storeVolatile(dst[o.* + 12 * g ..], simd.lookup16(part, idx));
        o.* += 48;
        return;
    }
    const a: [32]u8 = @shuffle(u8, lanes[0], undefined, three);
    const b: [32]u8 = @shuffle(u8, lanes[1], undefined, three);
    inline for ([4][16]u8{ a[0..16].*, b[0..16].*, a[16..32].*, b[16..32].* }, 0..) |part, g|
        dst[o.* + 12 * g ..][0..16].* = part;
    o.* += 48;
}

/// Encodes 16 code points below U+10000, none a surrogate, as UTF-8 at
/// `dst[o.*..]`, in four groups of four: `bmpBytes` and `unpackBmp`, then
/// a table shuffle per group. Writes 16 bytes past the start of each
/// group's output.
inline fn utf8FromBmp(v: @Vector(16, u16), dst: []u8, o: *usize) void {
    const U = @Vector(16, u16);
    const lt80 = v < splat(U, 0x80);
    const lt800 = v < splat(U, 0x800);
    const unpacked = unpackBmp(bmpBytes(v, lt800));
    const lo: [32]u8 = unpacked[0];
    const hi: [32]u8 = unpacked[1];
    // Bits 0-15: units of two bytes or more; bits 16-31: of three. Each
    // group's table index is its four bits of each.
    var idx: [4]usize = undefined;
    if (simd.has_bmi2) {
        // Two bits a unit, from byte masks: packing the compares to bytes
        // first takes four more shuffle-port operations.
        const S = @Vector(32, i8);
        const m80: u64 = simd.bitmask(@as(S, @bitCast(ones16(lt80))) < splat(S, 0));
        const m800: u64 = simd.bitmask(@as(S, @bitCast(ones16(lt800))) < splat(S, 0));
        const wide = ~(m80 | m800 << 32);
        inline for (&idx, 0..) |*i, g| i.* = @intCast(simd.pext(wide, @as(u64, 0x55_0000_0055) << 8 * g));
    } else if (neon and native == .little) {
        // Each unit's bit of its group's index in its lane, and the lanes
        // of each group added with two pairwise adds: the four indexes in
        // one word, where two lane masks take twelve vector operations and
        // as many to pick the indexes out.
        const bits = comptime blk: {
            var a: [16]u16 = undefined;
            var b: [16]u16 = undefined;
            for (0..16) |k| {
                a[k] = 1 << (k % 4);
                b[k] = 0x10 << (k % 4);
            }
            break :blk .{ a, b };
        };
        const x: [2]@Vector(8, u16) = @bitCast(@select(u16, lt80, splat(U, 0), bits[0]) |
            @select(u16, lt800, splat(U, 0), bits[1]));
        const r = @"llvm.aarch64.neon.addp.v8i16"(x[0], x[1]);
        const q = @as(@Vector(2, u64), @bitCast(@"llvm.aarch64.neon.addp.v8i16"(r, r)))[0];
        inline for (&idx, 0..) |*i, g| i.* = @as(u8, @truncate(q >> 16 * g));
    } else {
        // Two masks, not one of the compares joined: joined, NEON's mask
        // takes the lanes back out of an integer one at a time.
        const wide = ~(@as(u32, simd.bitmask(lt800)) << 16 | simd.bitmask(lt80));
        inline for (&idx, 0..) |*i, g| i.* = (wide >> 4 * g & 15) | (wide >> (12 + 4 * g) & 0xF0);
    }
    if (wide_shuffle) {
        // Groups 0 and 2 are the lanes of `lo`, 1 and 3 those of `hi`.
        const t = &utf8_pack3.shuffles;
        const ia: @Vector(32, u8) = @bitCast([2]V16{
            simd.loadVolatile(V16, &t[idx[0]]),
            simd.loadVolatile(V16, &t[idx[2]]),
        });
        const ib: @Vector(32, u8) = @bitCast([2]V16{
            simd.loadVolatile(V16, &t[idx[1]]),
            simd.loadVolatile(V16, &t[idx[3]]),
        });
        const a: [32]u8 = simd.shuffleLanes(@as(@Vector(32, u8), lo), ia);
        const b: [32]u8 = simd.shuffleLanes(@as(@Vector(32, u8), hi), ib);
        const parts = [4][16]u8{ a[0..16].*, b[0..16].*, a[16..32].*, b[16..32].* };
        inline for (parts, idx) |part, i| {
            dst[o.*..][0..16].* = part;
            o.* += utf8_pack3.lens[i];
        }
        return;
    }
    const groups = [4]V16{ lo[0..16].*, hi[0..16].*, lo[16..32].*, hi[16..32].* };
    inline for (groups, idx) |lanes, i| {
        dst[o.*..][0..16].* = simd.lookup16(lanes, simd.loadVolatile(V16, &utf8_pack3.shuffles[i]));
        o.* += utf8_pack3.lens[i];
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

// UTF-16 and UTF-32 to UTF-8 with AVX-512: each code point becomes its
// UTF-8 bytes in a 32-bit lane, or in a 16-bit lane when no character needs
// three, and `vpcompressb` drops the bytes the lanes do not use. A lane's
// bytes past the first are never zero, so the bytes to keep are the nonzero
// ones and each taken lane's first.

/// The UTF-8 of the lanes of `cp` that `take` selects, packed, and its
/// length. `vpmultishiftqb` puts bits 18, 12, 6, and 0 up of each lane in
/// its four bytes, lead first, and a mask and the tag bits for the lane's
/// length, looked up by its leading zeros, finish the bytes; a lane of fewer
/// bytes has zeros before them.
inline fn utf8Encode512(cp: @Vector(16, u32), take: u16) struct { V64, usize } {
    const D = @Vector(16, u32);
    const tables = comptime blk: {
        var mask: [32]u32 = undefined;
        var tag: [32]u32 = undefined;
        for (0..32) |lz| {
            // Zero has 32 leading zeros, and indexes entry 0.
            const bits = if (lz == 0) 0 else 32 - lz;
            // Byte 3 is the last byte; a lane of n bytes uses the last n.
            mask[lz], tag[lz] = if (bits <= 7)
                .{ 0x7F000000, 0 }
            else if (bits <= 11)
                .{ 0x3F1F0000, 0x80C00000 }
            else if (bits <= 16)
                .{ 0x3F3F0F00, 0x8080E000 }
            else
                .{ 0x3F3F3F07, 0x808080F0 };
        }
        const ctrl: @Vector(8, u8) = .{ 18, 12, 6, 0, 50, 44, 38, 32 };
        // Each table as its two halves, the operands of `vpermi2d`.
        const halves = [2][2]D{ .{ mask[0..16].*, mask[16..].* }, .{ tag[0..16].*, tag[16..].* } };
        break :blk .{ halves[0], halves[1], std.simd.repeat(64, ctrl) };
    };
    const shifted: D = @bitCast(simd.multishift(@as(V64, tables[2]), @bitCast(cp)));
    const lz: D = @clz(cp);
    const live: @Vector(16, bool) = @bitCast(take);
    const mask = @select(u32, live, simd.permute2(tables[0][0], lz, tables[0][1]), splat(D, 0));
    const tag = @select(u32, live, simd.permute2(tables[1][0], lz, tables[1][1]), splat(D, 0));
    const b: V64 = @bitCast(shifted & mask | tag);
    const keep = simd.bitmask(b != splat(V64, 0)) | simd.pdep(take, 0x8888888888888888);
    return .{ simd.compress(b, keep), @popCount(keep) };
}

/// The UTF-8 of up to 32 code points below U+0800 in `v`, the first `n`,
/// packed, and its length.
inline fn utf8Encode512Two(v: @Vector(32, u16), n: usize) struct { V64, usize } {
    const W = @Vector(32, u16);
    const two = (splat(W, 0xC0) | v >> splat(W, 6)) | (splat(W, 0x80) | (v & splat(W, 0x3F))) << splat(W, 8);
    const b: V64 = @bitCast(@select(u16, v < splat(W, 0x80), v, two));
    const keep = (simd.bitmask(b != splat(V64, 0)) | 0x5555555555555555) & simd.lowBits(u64, 2 * n);
    return .{ simd.compress(b, keep), @popCount(keep) };
}

/// UTF-8 for the first `n` of 32 Latin-1 bytes, packed, and its length.
/// Which bytes to keep comes from the high bits by `pdep`, not from a
/// compare of the result: the shuffle port, which the compress and the
/// widening need, is the bottleneck.
inline fn latin1Encode512(x: @Vector(32, u8), n: usize) struct { V64, usize } {
    const W = @Vector(32, u16);
    const v: W = x;
    const two = (splat(W, 0xC0) | v >> splat(W, 6)) | (splat(W, 0x80) | (v & splat(W, 0x3F))) << splat(W, 8);
    const high: u32 = simd.bitmask(x >= splat(@Vector(32, u8), 0x80));
    const b: V64 = @bitCast(@select(u16, @as(@Vector(32, bool), @bitCast(high)), two, v));
    const keep = (simd.pdep(high, 0xAAAAAAAAAAAAAAAA) | 0x5555555555555555) & simd.lowBits(u64, 2 * n);
    return .{ simd.compress(b, keep), @popCount(keep) };
}

/// UTF-8 for 64 Latin-1 bytes `v`, whose high bits are `high`, as two
/// packed halves and their lengths, in simdutf's layout: one `vpermb` puts
/// bytes `i` and `32 + i` in 16-bit lane `i`, and each half's lane becomes
/// 0xC2 then the byte, 0x40 added to both where it is at least 0xC0; a
/// byte below 0x80 drops the 0xC2 before it. Two `vpermt2b` interleaving
/// lead and continuation bytes made the loop 0.81 of `icelake` on Latin-1
/// text, this one 1.01.
inline fn latin1Encode512Block(v: V64, high: u64) [2]struct { V64, usize } {
    const W = @Vector(32, u16);
    const idx = comptime blk: {
        var m: [64]u8 = undefined;
        for (0..32) |i| {
            m[2 * i] = i;
            m[2 * i + 1] = 32 + i;
        }
        break :blk m;
    };
    const w: W = @bitCast(simd.permute(v, idx));
    const big = simd.bitmask(v >= splat(V64, 0xC0));
    // `vpshldw`, where a shift and an or take two operations.
    const x0 = @"llvm.fshl.v32i16"(w, splat(W, 0xC2C2), splat(W, 8));
    const big0: @Vector(32, bool) = @bitCast(@as(u32, @truncate(big)));
    const big1: @Vector(32, bool) = @bitCast(@as(u32, @truncate(big >> 32)));
    const y0 = @select(u16, big0, x0 +% splat(W, 0xC001), x0);
    const t = @select(u16, big1, splat(W, 0x40C3), splat(W, 0x00C2));
    const y1 = (w & splat(W, 0xFF00)) ^ t;
    // The halves' masks and lengths in general registers: the upper half's
    // bits by `pext`, where LLVM would shift the mask register with
    // `kshiftrq`, on the shuffle port, and its count as the whole count
    // less the lower half's.
    const lo: u32 = @truncate(high);
    const hi = simd.pext(high, 0xFFFFFFFF00000000);
    const n0: usize = @popCount(lo);
    const n: usize = @popCount(high);
    const odd = 0xAAAAAAAAAAAAAAAA;
    return .{
        .{ simd.compress(@as(V64, @bitCast(y0)), simd.pdep(lo, 0x5555555555555555) | odd), 32 + n0 },
        .{ simd.compress(@as(V64, @bitCast(y1)), simd.pdep(hi, 0x5555555555555555) | odd), 32 + n - n0 },
    };
}

/// Stores packed UTF-8 at `dst[o.*..]` and advances `o`; false, storing
/// nothing, if it does not fit.
inline fn put512(dst: []u8, o: *usize, packed_bytes: struct { V64, usize }) bool {
    const bytes, const n = packed_bytes;
    if (n > dst.len - o.*) return false;
    simd.storePartial(dst[o.*..], bytes, n);
    o.* += n;
    return true;
}

/// Code points for the first 32 or fewer UTF-16 units of `src`, `v`, as
/// two vectors of 16, which lanes to take, and how many units that
/// consumes. A pair decodes in its high surrogate's lane, and its low
/// surrogate's lane is not taken; a high surrogate in the last lane waits
/// for the next block, unless the input ends there. In the checked form,
/// null when a surrogate is unpaired.
const Pairs512 = struct { cp: [2]@Vector(16, u32), take: u32, consumed: usize };

inline fn decodePairs512(comptime e: Endian, comptime checked: bool, src: []const u16, v: @Vector(32, u16)) ?Pairs512 {
    const U = @Vector(32, u16);
    const D = @Vector(16, u32);
    const n = @min(src.len, 32);
    const live = simd.lowBits(u32, n);
    const hi = simd.bitmask(v & splat(U, 0xFC00) == splat(U, 0xD800)) & live;
    const lo = simd.bitmask(v & splat(U, 0xFC00) == splat(U, 0xDC00)) & live;
    const more = src.len > 32;
    // From the scalar units, so the next load need not wait for `hi`.
    const last_hi = more and swap16(e, src[31]) & 0xFC00 == 0xD800;
    // The units one later: a load, where the input has them.
    const after = if (more) load16(e, 32, src, 1) else @shuffle(u16, v, splat(U, 0), blk: {
        var m: [32]i32 = undefined;
        for (0..31) |i| m[i] = @intCast(i + 1);
        m[31] = -1;
        break :blk m;
    });
    const wait: u32 = if (last_hi) 1 << 31 else 0;
    if (checked) {
        const next_lo: u32 = simd.bitmask(after & splat(U, 0xFC00) == splat(U, 0xDC00));
        const bad = (hi & ~next_lo & ~wait) | (lo & ~(hi << 1));
        // Bad, or a high surrogate ending the input.
        if (bad != 0 or (hi >> @intCast(n - 1) & 1 != 0 and !last_hi)) return null;
    }
    const bias: u32 = @bitCast(@as(i32, 0x10000 - (0xD800 << 10) - 0xDC00));
    const a: [32]u16 = v;
    const b: [32]u16 = after;
    var cp: [2]D = undefined;
    inline for (0..2) |h| {
        const w: D = @as(@Vector(16, u16), a[16 * h ..][0..16].*);
        const pair = splat(D, bias) +% (w << splat(D, 10)) +% @as(D, @as(@Vector(16, u16), b[16 * h ..][0..16].*));
        cp[h] = @select(u32, @as(@Vector(16, bool), @bitCast(@as(u16, @truncate(hi >> 16 * h)))), pair, w);
    }
    return .{ .cp = cp, .take = ~lo & live & ~wait, .consumed = if (last_hi) 31 else n };
}

inline fn swap16(comptime e: Endian, x: u16) u16 {
    return if (e == native) x else @byteSwap(x);
}

fn utf16ToUtf8Avx512(comptime e: Endian, comptime checked: bool, src: []const u16, dst: []u8) struct { usize, usize } {
    const U = @Vector(32, u16);
    var p: usize = 0;
    var o: usize = 0;
    while (p < src.len) {
        const rem = src.len - p;
        const n = @min(rem, 32);
        var v: U = if (rem >= 32) simd.load(u16, src[p..]) else simd.loadShort(u16, src[p..][0..n]);
        if (e != native) v = @byteSwap(v);
        if (below(0x80, v)) {
            if (n > dst.len - o) break;
            const narrow: @Vector(32, u8) = @truncate(v);
            if (n == 32) {
                dst[o..][0..32].* = narrow;
            } else {
                simd.storePartial(dst[o..], @as(V64, @bitCast([2]@Vector(32, u8){ narrow, @splat(0) })), n);
            }
            p += n;
            o += n;
            // More ASCII likely follows: 64 units a step while it does.
            while (src.len - p >= 64 and dst.len - o >= 64) {
                const a = load16(e, 32, src, p);
                const b = load16(e, 32, src, p + 32);
                if (!below(0x80, a | b)) break;
                dst[o..][0..32].* = @as(@Vector(32, u8), @truncate(a));
                dst[o + 32 ..][0..32].* = @as(@Vector(32, u8), @truncate(b));
                p += 64;
                o += 64;
            }
            continue;
        }
        // A whole block with room for any output stores whole registers,
        // with no mask or page test: the next store rewrites past its bytes.
        const whole = n == 32 and dst.len - o >= 128;
        if (below(0x800, v)) {
            if (whole) {
                const bytes, const k = utf8Encode512Two(v, 32);
                store(u8, native, dst, o, bytes);
                o += k;
                p += 32;
                continue;
            }
            if (!put512(dst, &o, utf8Encode512Two(v, n))) break;
            p += n;
            continue;
        }
        const live = simd.lowBits(u32, n);
        const surrogates = simd.bitmask(v & splat(U, 0xF800) == splat(U, 0xD800)) & live;
        const a: [32]u16 = v;
        if (surrogates == 0 and whole) {
            inline for (0..2) |h| {
                const bytes, const k = utf8Encode512(@as(@Vector(16, u16), a[16 * h ..][0..16].*), 0xFFFF);
                store(u8, native, dst, o, bytes);
                o += k;
            }
            p += 32;
            continue;
        }
        if (surrogates == 0) {
            const o0 = o;
            if (!put512(dst, &o, utf8Encode512(@as(@Vector(16, u16), a[0..16].*), @truncate(live))) or
                (n > 16 and !put512(dst, &o, utf8Encode512(@as(@Vector(16, u16), a[16..32].*), @truncate(live >> 16)))))
            {
                o = o0;
                break;
            }
            p += n;
            continue;
        }
        if (n == 32 and dst.len - o >= 64) if (alignedPairs(v)) |cp| {
            utf8FromFour(cp, dst, &o);
            p += 32;
            continue;
        };
        const d = decodePairs512(e, checked, src[p..], v) orelse break;
        const o0 = o;
        inline for (0..2) |h| {
            if (h == 0 or n > 16) {
                if (!put512(dst, &o, utf8Encode512(d.cp[h], @truncate(d.take >> 16 * h)))) {
                    o = o0;
                    return .{ p, o };
                }
            }
        }
        p += d.consumed;
    }
    return .{ p, o };
}

fn utf32ToUtf8Avx512(comptime checked: bool, src: []const u32, dst: []u8) struct { usize, usize } {
    const D = @Vector(16, u32);
    var p: usize = 0;
    var o: usize = 0;
    while (p < src.len) {
        const rem = src.len - p;
        // Two vectors at a time, for the ASCII and two-byte paths.
        if (rem >= 32) {
            const a = simd.load(u32, src[p..]);
            const b = simd.load(u32, src[p + 16 ..]);
            if (below(0x80, a | b) and dst.len - o >= 32) {
                dst[o..][0..32].* = @as(@Vector(32, u8), @truncate(@as(@Vector(32, u32), @bitCast([2]D{ a, b }))));
                p += 32;
                o += 32;
                continue;
            }
            if (below(0x800, a | b)) {
                if (!put512(
                    dst,
                    &o,
                    utf8Encode512Two(@truncate(@as(@Vector(32, u32), @bitCast([2]D{ a, b }))), 32),
                )) break;
                p += 32;
                continue;
            }
        }
        const n = @min(rem, 16);
        const v: D = if (rem >= 16) simd.load(u32, src[p..]) else simd.loadShort(u32, src[p..][0..n]);
        if (checked and utf32Invalid(v)) break;
        if (!put512(dst, &o, utf8Encode512(v, simd.lowBits(u16, n)))) break;
        p += n;
    }
    return .{ p, o };
}

/// Whether `v` holds a surrogate or a value above U+10FFFF.
inline fn utf32Invalid(v: @Vector(16, u32)) bool {
    const D = @Vector(16, u32);
    const too_big = v > splat(D, 0x10FFFF);
    const surrogates = v & splat(D, 0xFFFFF800) == splat(D, 0xD800);
    return simd.bitmask(too_big) | simd.bitmask(surrogates) != 0;
}

fn utf16ToUtf8Long(comptime e: Endian, comptime checked: bool, src: []const u16, dst: []u8) Result {
    const p, const o = utf16ToUtf8Avx512(e, checked, src, dst);
    if (checked) return tail(scalar.utf16ToUtf8(e, src[p..], dst[o..]), p, o);
    return .ok(o + scalar.validUtf16ToUtf8(e, src[p..], dst[o..]));
}

fn utf16ToUtf8Impl(comptime e: Endian, comptime checked: bool, src: []const u16, dst: []u8) Result {
    const U = @Vector(16, u16);
    const run = struct {
        fn f(s: []const u16, d: []u8) Result {
            if (checked) return scalar.utf16ToUtf8(e, s, d);
            return .ok(scalar.validUtf16ToUtf8(e, s, d));
        }
    }.f;
    if (v512) {
        // Up to 32 ASCII units, before the loop loads its constants: set
        // up first, they cost every short call 2-4 ns.
        if (src.len <= 32 and src.len <= dst.len) {
            var v = simd.loadShort(u16, src);
            if (e != native) v = @byteSwap(v);
            if (below(0x80, v)) {
                const narrow: @Vector(32, u8) = @truncate(v);
                simd.storePartial(dst, @as(V64, @bitCast([2]@Vector(32, u8){ narrow, @splat(0) })), src.len);
                return .ok(src.len);
            }
        }
        return longPath(true, utf16ToUtf8Long, .{ e, checked }, src, dst);
    }
    var p: usize = 0;
    var o: usize = 0;
    // A block writes at most 48 bytes, and each group's store reaches 16
    // past its start.
    var steps: Steps = .{};
    if (use_simd) while (true) {
        while (src.len - p >= 16 and dst.len - o >= 64) {
            const v = load16(e, 16, src, p);
            if (below(0x80, v)) {
                dst[o..][0..16].* = @as(V16, @truncate(v));
                p += 16;
                o += 16;
                // More ASCII likely follows: 32 units a step while it does.
                while (src.len - p >= 32 and dst.len - o >= 32) {
                    const pair = load16(e, 32, src, p);
                    if (!below(0x80, pair)) break;
                    dst[o..][0..32].* = @as(@Vector(32, u8), @truncate(pair));
                    p += 32;
                    o += 32;
                }
                continue;
            }
            if (!fast_shuffle) {
                break;
            }
            if (below(0x800, v)) {
                utf8From2x16(v, dst, &o);
                p += 16;
                continue;
            }
            if (!anyTrue(u16, v & splat(U, 0xF800) == splat(U, 0xD800))) {
                if (!anyTrue(u16, v < splat(U, 0x800)))
                    utf8From16Three(v, dst, &o)
                else
                    utf8FromBmp(v, dst, &o);
                p += 16;
                continue;
            }
            if (alignedPairs(v)) |cp| {
                utf8FromFour(cp, dst, &o);
                p += 16;
                continue;
            }
            if (src.len - p < 17) break;
            const d = decode16(checked, v, load16(e, 16, src, p + 1)) orelse break;
            utf8From16(d.cp, simd.bitmask(d.take), dst, &o);
            p += d.consumed;
        }
        if (fast_shuffle or !(src.len - p >= 16 and dst.len - o >= 64)) break;
        const end = utf16Boundary(e, src, p, @min(steps.next(p), src.len - p));
        if (scalarStep(run, src, end, dst, &p, &o, &steps)) |r| return r;
    };
    return tail(run(src[p..], dst[o..]), p, o);
}

fn utf32ToUtf8Long(comptime checked: bool, src: []const u32, dst: []u8) Result {
    const p, const o = utf32ToUtf8Avx512(checked, src, dst);
    if (checked) return tail(scalar.utf32ToUtf8(src[p..], dst[o..]), p, o);
    return .ok(o + scalar.validUtf32ToUtf8(src[p..], dst[o..]));
}

fn utf32ToUtf8Impl(comptime checked: bool, src: []const u32, dst: []u8) Result {
    const run = struct {
        fn f(s: []const u32, d: []u8) Result {
            if (checked) return scalar.utf32ToUtf8(s, d);
            return .ok(scalar.validUtf32ToUtf8(s, d));
        }
    }.f;
    if (v512) {
        // Up to 16 values in one masked step, for the checked form, which
        // saved six registers on every call (the valid one none).
        if (checked and src.len <= 16) {
            if (src.len == 0) return .ok(0);
            const v = simd.loadShort(u32, src);
            var o: usize = 0;
            if (!utf32Invalid(v) and put512(dst, &o, utf8Encode512(v, simd.lowBits(u16, src.len)))) return .ok(o);
        }
        return longPath(checked, utf32ToUtf8Long, .{checked}, src, dst);
    }
    const W = @Vector(16, u32);
    var p: usize = 0;
    var o: usize = 0;
    var steps: Steps = .{};
    if (use_simd) while (true) {
        while (src.len - p >= 16 and dst.len - o >= 64) {
            const v = simd.load(u32, src[p..]);
            if (below(0x80, v)) {
                dst[o..][0..16].* = @as(V16, @truncate(v));
                p += 16;
                o += 16;
                // More ASCII likely follows: a loop of its own, which keeps
                // the run off the branches below.
                while (src.len - p >= 16 and dst.len - o >= 16) {
                    const next = simd.load(u32, src[p..]);
                    if (!below(0x80, next)) break;
                    dst[o..][0..16].* = @as(V16, @truncate(next));
                    p += 16;
                    o += 16;
                }
                continue;
            } else if (!fast_shuffle) {
                break;
            } else if (below(0x800, v)) {
                utf8From2x16(@truncate(v), dst, &o);
            } else if (below(0x10000, v)) {
                // Narrowed first, so the checks and the encoder take one
                // register of 16-bit lanes where 32-bit ones take two.
                const U = @Vector(16, u16);
                const w = simd.narrow(u16, v);
                if (checked and anyTrue(u16, w & splat(U, 0xF800) == splat(U, 0xD800))) break;
                if (!anyTrue(u16, w < splat(U, 0x800)))
                    utf8From16Three(w, dst, &o)
                else
                    utf8FromBmp(w, dst, &o);
            } else {
                const too_big = v > splat(W, 0x10FFFF);
                const surrogates = v & splat(W, 0xFFFFF800) == splat(W, 0xD800);
                if (checked and @reduce(.Or, too_big != surrogates)) break;
                utf8From16(v, 0xFFFF, dst, &o);
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

fn utf16ToUtf32Avx512(
    comptime e: Endian,
    comptime checked: bool,
    src: []const u16,
    dst: []u32,
) struct { usize, usize } {
    const U = @Vector(32, u16);
    const D = @Vector(16, u32);
    var p: usize = 0;
    var o: usize = 0;
    while (p < src.len) {
        const rem = src.len - p;
        const n = @min(rem, 32);
        var v: U = if (rem >= 32) simd.load(u16, src[p..]) else simd.loadShort(u16, src[p..][0..n]);
        if (e != native) v = @byteSwap(v);
        const a: [32]u16 = v;
        if (simd.bitmask(v & splat(U, 0xF800) == splat(U, 0xD800)) == 0) {
            if (n > dst.len - o) break;
            if (n == 32) {
                store(u32, native, dst, o, @as(D, @as(@Vector(16, u16), a[0..16].*)));
                store(u32, native, dst, o + 16, @as(D, @as(@Vector(16, u16), a[16..32].*)));
            } else {
                const lo: @Vector(16, u16) = a[0..16].*;
                const hi: @Vector(16, u16) = a[16..32].*;
                simd.storePartial(dst[o..], @as(@Vector(16, u32), lo), n);
                if (n > 16) simd.storePartial(dst[o + 16 ..], @as(@Vector(16, u32), hi), n - 16);
            }
            p += n;
            o += n;
            // More of the same likely follows.
            while (src.len - p >= 32 and dst.len - o >= 32) {
                const w = load16(e, 32, src, p);
                if (simd.bitmask(w & splat(U, 0xF800) == splat(U, 0xD800)) != 0) break;
                const c: [32]u16 = w;
                store(u32, native, dst, o, @as(D, @as(@Vector(16, u16), c[0..16].*)));
                store(u32, native, dst, o + 16, @as(D, @as(@Vector(16, u16), c[16..32].*)));
                p += 32;
                o += 32;
            }
            continue;
        }
        if (n == 32 and dst.len - o >= 16) if (alignedPairs(v)) |cp| {
            store(u32, native, dst, o, cp);
            p += 32;
            o += 16;
            continue;
        };
        const d = decodePairs512(e, checked, src[p..], v) orelse break;
        const t0: u16 = @truncate(d.take);
        const t1: u16 = @truncate(d.take >> 16);
        const n0: usize = @popCount(t0);
        const n1: usize = @popCount(t1);
        if (n0 + n1 > dst.len - o) break;
        simd.storePartial(dst[o..], simd.compress(d.cp[0], t0), n0);
        simd.storePartial(dst[o + n0 ..], simd.compress(d.cp[1], t1), n1);
        p += d.consumed;
        o += n0 + n1;
    }
    return .{ p, o };
}

fn utf16ToUtf32Impl(comptime e: Endian, comptime checked: bool, src: []const u16, dst: []u32) Result {
    const U = @Vector(16, u16);
    const run = struct {
        fn f(s: []const u16, d: []u32) Result {
            if (checked) return scalar.utf16ToUtf32(e, s, d);
            return .ok(scalar.validUtf16ToUtf32(e, s, d));
        }
    }.f;
    if (v512) {
        const p, const o = utf16ToUtf32Avx512(e, checked, src, dst);
        return tail(run(src[p..], dst[o..]), p, o);
    }
    var p: usize = 0;
    var o: usize = 0;
    var steps: Steps = .{};
    if (use_simd) while (true) {
        while (src.len - p >= 16 and dst.len - o >= 16) {
            // Text without surrogates, 32 units a step, with one bound,
            // widened from 8-unit loads, which fold into `vpmovzxwd`.
            var k = @min(src.len - p, dst.len - o) / 32;
            while (k > 0) : (k -= 1) {
                const w = load16(e, 32, src, p);
                if (anyTrue(u16, w & splat(@Vector(32, u16), 0xF800) == splat(@Vector(32, u16), 0xD800))) break;
                // Swapped units widen from the register they were swapped
                // in, where swapping each load would add a shuffle. NEON
                // widens from the registers it tested.
                if (neon) {
                    storeWideUnits(dst, o, w);
                } else if (e == native) {
                    inline for (0..4) |q| {
                        store(u32, native, dst, o + 8 * q, @as(@Vector(8, u16), src[p + 8 * q ..][0..8].*));
                    }
                } else {
                    store(u32, native, dst, o, w);
                }
                p += 32;
                o += 32;
            }
            if (src.len - p < 16 or dst.len - o < 16) break;
            const v = load16(e, 16, src, p);
            if (!anyTrue(u16, v & splat(U, 0xF800) == splat(U, 0xD800))) {
                storeWideUnits(dst, o, v);
                p += 16;
                o += 16;
                continue;
            }
            if (alignedPairs(v)) |cp| {
                dst[o..][0..8].* = cp;
                p += 16;
                o += 8;
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
                const kept = simd.lookup16(@bitCast(lanes), simd.loadVolatile(V16, &compress32[keep]));
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

fn utf32ToUtf16Avx512(
    comptime e: Endian,
    comptime checked: bool,
    src: []const u32,
    dst: []u16,
) struct { usize, usize } {
    const D = @Vector(16, u32);
    const W = @Vector(32, u16);
    var p: usize = 0;
    var o: usize = 0;
    while (p < src.len) {
        const rem = src.len - p;
        // Two vectors at a time while no code point needs a pair.
        if (rem >= 32 and dst.len - o >= 32) {
            const a = simd.load(u32, src[p..]);
            const b = simd.load(u32, src[p + 16 ..]);
            const ab: @Vector(32, u32) = @bitCast([2]D{ a, b });
            if (below(0x10000, a | b) and
                (!checked or !@reduce(.Or, ab & splat(@Vector(32, u32), 0xF800) == splat(@Vector(32, u32), 0xD800))))
            {
                var w: W = simd.narrow(u16, ab);
                if (e != native) w = @byteSwap(w);
                store(u16, native, dst, o, w);
                p += 32;
                o += 32;
                continue;
            }
        }
        const n = @min(rem, 16);
        const v: D = if (rem >= 16) simd.load(u32, src[p..]) else simd.loadShort(u32, src[p..][0..n]);
        if (checked and utf32Invalid(v)) break;
        o += utf32ToUtf16Step(e, v, n, dst[o..]) orelse break;
        p += n;
    }
    return .{ p, o };
}

/// Stores the first `n` values of `v` as UTF-16 in byte order `e` at the
/// start of `dst`, and returns how many units, or null if they do not fit.
inline fn utf32ToUtf16Step(comptime e: Endian, v: @Vector(16, u32), n: usize, dst: []u16) ?usize {
    const D = @Vector(16, u32);
    const W = @Vector(32, u16);
    // Each lane as one unit, or as a high and a low surrogate.
    const pairs: u16 = simd.bitmask(v >= splat(D, 0x10000)) & simd.lowBits(u16, n);
    const s = v -% splat(D, 0x10000);
    const hi = splat(D, 0xD800) | s >> splat(D, 10);
    const lo = splat(D, 0xDC00) | (s & splat(D, 0x3FF));
    const pair = hi | lo << splat(D, 16);
    const keep: u32 = @truncate(simd.pdep(simd.lowBits(u16, n), 0x55555555) | simd.pdep(pairs, 0xAAAAAAAA));
    const count: usize = @popCount(keep);
    if (count > dst.len) return null;
    var w = simd.compress(@as(W, @bitCast(@select(u32, @as(@Vector(16, bool), @bitCast(pairs)), pair, v))), keep);
    if (e != native) w = @byteSwap(w);
    simd.storePartial(dst, w, count);
    return count;
}

fn utf32ToUtf16Long(comptime e: Endian, comptime checked: bool, src: []const u32, dst: []u16) Result {
    const p, const o = utf32ToUtf16Avx512(e, checked, src, dst);
    if (checked) return tail(scalar.utf32ToUtf16(e, src[p..], dst[o..]), p, o);
    return .ok(o + scalar.validUtf32ToUtf16(e, src[p..], dst[o..]));
}

fn utf32ToUtf16Impl(comptime e: Endian, comptime checked: bool, src: []const u32, dst: []u16) Result {
    const run = struct {
        fn f(s: []const u32, d: []u16) Result {
            if (checked) return scalar.utf32ToUtf16(e, s, d);
            return .ok(scalar.validUtf32ToUtf16(e, s, d));
        }
    }.f;
    if (v512) {
        // Up to 16 values in one masked step, for the checked form, which
        // saved six registers on every call (the valid one none).
        if (checked and src.len <= 16) {
            if (src.len == 0) return .ok(0);
            const v = simd.loadShort(u32, src);
            if (!utf32Invalid(v)) if (utf32ToUtf16Step(e, v, src.len, dst)) |n| return .ok(n);
        }
        return longPath(checked, utf32ToUtf16Long, .{ e, checked }, src, dst);
    }
    const W = @Vector(16, u32);
    const U32x4 = @Vector(4, u32);
    var p: usize = 0;
    var o: usize = 0;
    var steps: Steps = .{};
    if (use_simd) while (true) {
        // Two blocks a step while neither has a pair or a surrogate: the
        // checks of both reduce to one test.
        while (src.len - p >= 32 and dst.len - o >= 32) {
            const a = simd.load(u32, src[p..]);
            const b = simd.load(u32, src[p + 16 ..]);
            if (!below(0x10000, a | b)) break;
            if (checked) {
                const sa = a & splat(W, 0xF800) == splat(W, 0xD800);
                const sb = b & splat(W, 0xF800) == splat(W, 0xD800);
                if (@reduce(.Or, @select(bool, sa, sa, sb))) break;
            }
            store(u16, e, dst, o, simd.narrow(u16, @as(@Vector(32, u32), @bitCast([2]W{ a, b }))));
            p += 32;
            o += 32;
        }
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
                const mask = simd.bitmask(pairs);
                const s = cp -% splat(U32x4, 0x10000);
                const pair = (splat(U32x4, 0xD800) | s >> splat(U32x4, 10)) |
                    (splat(U32x4, 0xDC00) | (s & splat(U32x4, 0x3FF))) << splat(U32x4, 16);
                const units = simd.lookup16(
                    @bitCast(@select(u32, pairs, pair, cp)),
                    simd.loadVolatile(V16, &utf16_pairs[mask]),
                );
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
    if (use_simd) {
        // One bound for both: two compares made LLVM build flags with
        // `setae` and `and` at every iteration.
        const lim = @min(src.len, dst.len);
        var step = firstStep(u16, src, src.len, 64);
        while (lim - p >= 64) : (step = 64) {
            const v: @Vector(64, u16) = @bitCast(
                [2]@Vector(32, u16){ load16(e, 32, src, p), load16(e, 32, src, p + 32) },
            );
            if (checked and !below(0x100, v)) break;
            if (v512) {
                // The low bytes of both vectors in one permute and one store.
                const halves: [2]V64 = @bitCast(v);
                const even = comptime blk: {
                    var t: [64]u8 = undefined;
                    for (&t, 0..) |*x, i| x.* = @intCast(2 * i);
                    break :blk t;
                };
                store(u8, native, dst, p, simd.permute2(halves[0], even, halves[1]));
            } else {
                dst[p..][0..64].* = @as(@Vector(64, u8), @truncate(v));
            }
            p += step;
        }
        while (lim - p >= 32) {
            const v = load16(e, 32, src, p);
            if (checked and !below(0x100, v)) break;
            dst[p..][0..32].* = @as(@Vector(32, u8), @truncate(v));
            p += 32;
        }
        // The last 1-31 units as two 16-unit vectors, the second ending
        // at the end, rewriting some already narrowed: scalar code took
        // 15-20 ns on 16 units.
        if (!v512 and src.len - p -% 1 < 31 and src.len >= 16 and dst.len >= src.len) {
            const q = src.len - 16;
            const s = @min(p, q);
            const lo = load16(e, 16, src, s);
            const hi = load16(e, 16, src, q);
            if (!checked or below(0x100, lo | hi)) {
                dst[s..][0..16].* = @as(V16, @truncate(lo));
                dst[q..][0..16].* = @as(V16, @truncate(hi));
                p = src.len;
            }
        }
        // The last 1-31 units in one masked step, returning directly.
        if (v512 and p < src.len and src.len - p < 32 and src.len <= dst.len) {
            const n = src.len - p;
            var v = simd.loadShort(u16, src[p..]);
            if (e != native) v = @byteSwap(v);
            if (!checked or below(0x100, v)) {
                simd.storePartial(dst[p..], @as(V64, @bitCast([2]@Vector(32, u8){ @truncate(v), @splat(0) })), n);
                return .ok(src.len);
            }
        }
    }
    if (checked) return tail(scalar.utf16ToLatin1(e, src[p..], dst[p..]), p, p);
    return .ok(p + scalar.validUtf16ToLatin1(e, src[p..], dst[p..]));
}

fn utf32ToLatin1Impl(comptime checked: bool, src: []const u32, dst: []u8) Result {
    // The checked form saved six registers on every call; the valid one
    // none, and its loops take 16 values without a mask.
    if (v512 and checked) {
        // Up to 64 values in steps of 16, the last masked: the call to the
        // long path cost 64 values more than the registers it saves.
        if (src.len <= 64 and src.len <= dst.len) short: {
            var p: usize = 0;
            while (src.len - p >= 16) : (p += 16) {
                const v = simd.load(u32, src[p..]);
                if (!below(0x100, v)) break :short;
                dst[p..][0..16].* = @as(V16, @truncate(v));
            }
            if (p == src.len) return .ok(p);
            const v = simd.loadShort(u32, src[p..]);
            if (!below(0x100, v)) break :short;
            const bytes: V64 = @bitCast([4]V16{ @truncate(v), @splat(0), @splat(0), @splat(0) });
            simd.storePartial(dst[p..], bytes, src.len - p);
            return .ok(src.len);
        }
        return longPath(true, utf32ToLatin1Rest, .{checked}, src, dst);
    }
    return utf32ToLatin1Rest(checked, src, dst);
}

fn utf32ToLatin1Rest(comptime checked: bool, src: []const u32, dst: []u8) Result {
    var p: usize = 0;
    if (use_simd) {
        const lim = @min(src.len, dst.len);
        var step = firstStep(u32, src, src.len, 64);
        while (lim - p >= 64) : (step = 64) {
            const v: @Vector(64, u32) = src[p..][0..64].*;
            if (checked and !below(0x100, v)) break;
            store(u8, native, dst, p, simd.narrow(u8, v));
            p += step;
        }
        while (lim - p >= 16) {
            const v = simd.load(u32, src[p..]);
            if (checked and !below(0x100, v)) break;
            dst[p..][0..16].* = @as(V16, @truncate(v));
            p += 16;
        }
        if (v512) while (p < src.len) {
            const n = @min(src.len - p, 16);
            if (n > dst.len - p) break;
            const v = simd.loadShort(u32, src[p..][0..n]);
            if (checked and !below(0x100, v)) break;
            simd.storePartial(dst[p..], @as(V64, @bitCast([4]V16{ @truncate(v), @splat(0), @splat(0), @splat(0) })), n);
            p += n;
        };
    }
    if (checked) return tail(scalar.utf32ToLatin1(src[p..], dst[p..]), p, p);
    return .ok(p + scalar.validUtf32ToLatin1(src[p..], dst[p..]));
}

// UTF-16 byte-order swap: a copy, validated like UTF-16 to UTF-8.

fn utf16SwapImpl(comptime e: Endian, comptime checked: bool, src: []const u16, dst: []u16) Result {
    var p: usize = 0;
    // A low surrogate first has no high one before it; after that, each
    // block checks that a unit is a high surrogate exactly when the next
    // is a low one, which also covers the first unit of the next block.
    if (use_simd and !(checked and src.len > 0 and swap16(e, src[0]) & 0xFC00 == 0xDC00)) {
        const n = simd.block_len / 2;
        // Less than a block in one masked load and store. The lanes past
        // the input load as zeros, which pair with nothing.
        if (simd.has_masked and fast_shuffle and src.len < n and dst.len >= src.len) {
            const raw = simd.loadShort(u16, src);
            const swapped = @byteSwap(raw);
            const v = if (e == native) raw else swapped;
            if (!checked or !unpaired(v, std.simd.shiftElementsLeft(v, 1, 0))) {
                if (src.len > 0) simd.storePartial(dst, swapped, src.len);
                return .ok(src.len);
            }
        }
        if (!checked and src.len >= 4 and dst.len >= src.len) return .ok(swapValid(e, src, dst));
        if (swapBlocks(n, e, checked, src, dst, &p)) return .ok(src.len);
        // Less than a block left: 8 units at a time, then 4.
        if (src.len - p < n and swapBlocks(8, e, checked, src, dst, &p)) return .ok(src.len);
        if (src.len - p < 8 and swapBlocks(4, e, checked, src, dst, &p)) return .ok(src.len);
    }
    // A block that ends in a high surrogate checked its low one: the
    // scalar code takes the pair whole.
    if (checked and p > 0 and swap16(e, src[p - 1]) & 0xFC00 == 0xD800) p -= 1;
    if (checked) return tail(scalar.utf16ToUtf16Swapped(e, src[p..], dst[p..]), p, p);
    return .ok(p + scalar.validUtf16ToUtf16Swapped(src[p..], dst[p..]));
}

/// Swaps `src`, at least 4 units, into `dst`, at least as long: four
/// blocks a step, then the last one to four with no loop, the last of them
/// ending at the end and rewriting some units with the same values. A
/// loop of one block a step is five instructions, which take one cycle
/// where they lie in one 64-byte line of code and two where they straddle
/// two, as the address of the caller's copy decides (4 KiB 0.58 of
/// `icelake` in one build, level in another).
fn swapValid(comptime e: Endian, src: []const u16, dst: []u16) usize {
    const n = simd.block_len / 2;
    const to: Endian = if (e == .little) .big else .little;
    // On NEON plain loads, which LLVM pairs (`ldp`), as it pairs the
    // stores; nothing here loads the unit after a block.
    const ld = struct {
        inline fn f(comptime m: usize, s: []const u16, i: usize) @Vector(m, u16) {
            if (!neon) return load16(e, m, s, i);
            const v = @as(*align(1) const @Vector(m, u16), @ptrCast(s[i..][0..m])).*;
            return if (e == native) v else @byteSwap(v);
        }
    }.f;
    const len = src.len;
    // Less than a block, at least 4 units: the first and last 16, 8, or 4.
    if (len < n) {
        inline for (.{ 16, 8, 4 }) |m| {
            if (len >= m) {
                const a = ld(m, src, 0);
                const b = ld(m, src, len - m);
                store(u16, to, dst, 0, a);
                store(u16, to, dst, len - m, b);
                return len;
            }
        }
        unreachable;
    }
    var p: usize = 0;
    if (len > 4 * n) {
        store(u16, to, dst, 0, ld(n, src, 0));
        p = firstStep(u16, dst, len, n);
        while (len - p > 4 * n) {
            inline for (0..4) |k| store(u16, to, dst, p + k * n, ld(n, src, p + k * n));
            p += 4 * n;
        }
    }
    const rem = len - p;
    inline for (1..4) |k| {
        if (rem > k * n) store(u16, to, dst, p + (k - 1) * n, ld(n, src, p + (k - 1) * n));
    }
    store(u16, to, dst, len - n, ld(n, src, len - n));
    return len;
}

/// Whether some unit of `v` is a high surrogate where the unit after it,
/// in `next`, is not a low one, or the reverse.
inline fn unpaired(v: anytype, next: @TypeOf(v)) bool {
    const U = @TypeOf(v);
    const high = v & splat(U, 0xFC00) == splat(U, 0xD800);
    const low_next = next & splat(U, 0xFC00) == splat(U, 0xDC00);
    return anyTrue(@typeInfo(U).vector.child, high != low_next);
}

/// Swaps `m`-unit blocks from `p.*` on, advancing it, and returns whether
/// that finished the input. The units before `p.*` are swapped and, when
/// checked, paired.
inline fn swapBlocks(
    comptime m: usize,
    comptime e: Endian,
    comptime checked: bool,
    src: []const u16,
    dst: []u16,
    p: *usize,
) bool {
    const U = @Vector(m, u16);
    const to: Endian = if (e == .little) .big else .little;
    // One bound for both: a unit past each block when checked.
    const lim = @min(if (checked) src.len -| 1 else src.len, dst.len);
    var step = if (m == simd.block_len / 2) firstStep(u16, dst, src.len, m) else m;
    while (lim - p.* >= m) : (step = m) {
        const v = load16(e, m, src, p.*);
        // Pairs checked only where the block or the unit after it holds a
        // surrogate, where the check takes a second load and four
        // operations a vector.
        const surrogates = checked and (anyTrue(u16, v & splat(U, 0xF800) == splat(U, 0xD800)) or
            swap16(e, src[p.* + m]) & 0xFC00 == 0xDC00);
        if (surrogates and unpaired(v, load16(e, m, src, p.* + 1))) return false;
        store(u16, to, dst, p.*, v);
        p.* += step;
        // After a block without surrogates, two blocks a step while neither
        // holds one: one test for both, where a block a step took ten
        // instructions (4 KiB 1.41x). Not after one with: in text of
        // surrogate pairs every try fails (emoji 0.63x).
        if (checked and m == simd.block_len / 2 and !surrogates) while (lim - p.* >= 2 * m) {
            const a = load16(e, m, src, p.*);
            const b = load16(e, m, src, p.* + m);
            const s = splat(U, 0xD800);
            if (anyTrue(u16, (a & splat(U, 0xF800) == s) | (b & splat(U, 0xF800) == s)) or
                swap16(e, src[p.* + 2 * m]) & 0xFC00 == 0xDC00) break;
            store(u16, to, dst, p.*, a);
            store(u16, to, dst, p.* + m, b);
            p.* += 2 * m;
        };
    }
    if (p.* == src.len) return true;
    // The rest as the block that ends with the input, rewriting some units
    // with the same values. Its units before `p.*` are paired already; its
    // last has no next unit, so it must not be a high surrogate.
    if (src.len - p.* > m or src.len < m or dst.len < src.len) return false;
    const q = src.len - m;
    const v = load16(e, m, src, q);
    if (checked and unpaired(v, std.simd.shiftElementsLeft(v, 1, 0))) return false;
    store(u16, to, dst, q, v);
    return true;
}

// Latin-1 to UTF-8, UTF-16, and UTF-32.

/// Up to 64 bytes, in one load and two steps of 32, before the loop loads
/// its constants: set up first, they cost every short call 2-4 ns (16 bytes
/// 1.25x, 64 bytes of Latin-1 1.19x the loop's 32-byte steps).
inline fn latin1ToUtf8Short(src: []const u8, dst: []u8) struct { usize, usize } {
    var o: usize = 0;
    if (src.len == 0) return .{ 0, 0 };
    const a: [64]u8 = simd.loadShort(u8, src);
    const n = @min(src.len, 32);
    if (!put512(dst, &o, latin1Encode512(a[0..32].*, n))) return .{ 0, 0 };
    if (src.len > n and !put512(dst, &o, latin1Encode512(a[32..64].*, src.len - n))) return .{ n, o };
    return .{ src.len, o };
}

/// Up to 64 bytes where the output has room for whole registers, 64 bytes
/// for each 32 of input: stored whole, the second half over the first's
/// slack, with no mask or page test, which took registers the call then
/// saved. Null where the room is short.
inline fn latin1ToUtf8Whole(src: []const u8, dst: []u8) ?usize {
    if (src.len == 0) return 0;
    if (dst.len < 64 or (src.len > 32 and dst.len < 128)) return null;
    const a: [64]u8 = simd.loadShort(u8, src);
    const n = @min(src.len, 32);
    const lo, const k = latin1Encode512(a[0..32].*, n);
    store(u8, native, dst, 0, lo);
    if (src.len <= 32) return k;
    const hi, const m = latin1Encode512(a[32..64].*, src.len - 32);
    store(u8, native, dst, k, hi);
    return k + m;
}

/// Inline: shared by the checked and valid forms, LLVM kept it out of line,
/// so that a call saved registers twice and returned through memory (256
/// bytes of Latin-1 1.13x inline).
inline fn latin1ToUtf8Avx512(src: []const u8, dst: []u8) struct { usize, usize } {
    var p: usize = 0;
    // ASCII blocks first, in loops of their own: before the main loop,
    // which loads a dozen constants first (256 bytes 1.2x). Two blocks a
    // step, then one. Only after an ASCII first block: Latin-1 text tested
    // its first block in both loops before the main loop tested it again.
    if (src.len >= 64 and dst.len >= 64 and below(0x80, simd.load(u8, src))) {
        while (src.len - p >= 128 and dst.len - p >= 128) {
            const a = simd.load(u8, src[p..]);
            const b = simd.load(u8, src[p + 64 ..]);
            if (!below(0x80, a | b)) break;
            store(u8, native, dst, p, a);
            store(u8, native, dst, p + 64, b);
            p += 128;
        }
        while (src.len - p >= 64 and dst.len - p >= 64) {
            const v = simd.load(u8, src[p..]);
            if (!below(0x80, v)) break;
            store(u8, native, dst, p, v);
            p += 64;
        }
    }
    var o: usize = p;
    outer: while (p < src.len) {
        const rem = src.len - p;
        if (rem < 64) {
            const n = @min(rem, 32);
            const v: @Vector(32, u8) = if (rem >= 32) src[p..][0..32].* else blk: {
                const a: [64]u8 = simd.loadShort(u8, src[p..][0..n]);
                break :blk a[0..32].*;
            };
            if (!put512(dst, &o, latin1Encode512(v, n))) break;
            p += n;
            continue;
        }
        var v = simd.load(u8, src[p..]);
        // The high bits by `vpmovb2m` and tested in a general register,
        // where `vptestmb` would take the shuffle port.
        var high = simd.bitmask(v >= splat(V64, 0x80));
        if (high == 0 and dst.len - o >= 64) {
            store(u8, native, dst, o, v);
            p += 64;
            o += 64;
            // A long run of ASCII, two blocks a step.
            while (src.len - p >= 128 and dst.len - o >= 128) {
                const a = simd.load(u8, src[p..]);
                const b = simd.load(u8, src[p + 64 ..]);
                if (!below(0x80, a | b)) break;
                store(u8, native, dst, o, a);
                store(u8, native, dst, o + 64, b);
                p += 128;
                o += 128;
            }
            continue;
        }
        // Each half to two-byte UTF-8, without branching on whether a
        // half is ASCII: in Latin-1 text that branch mispredicts. Whole
        // stores, which the next half rewrites past its bytes. Then the
        // blocks after it while they are not ASCII, as many as surely
        // fit without checking the room again: the loop is short enough
        // that its branches and bookkeeping showed. Each block loaded and
        // tested once: the first came in tested.
        if (dst.len - o < 128) break;
        var k = @min((src.len - p) / 64, (dst.len - o) / 128);
        while (true) {
            inline for (latin1Encode512Block(v, high)) |half| {
                const bytes, const n = half;
                store(u8, native, dst, o, bytes);
                o += n;
            }
            p += 64;
            k -= 1;
            if (k == 0) continue :outer;
            v = simd.load(u8, src[p..]);
            high = simd.bitmask(v >= splat(V64, 0x80));
            if (high == 0) continue :outer;
        }
    }
    return .{ p, o };
}

fn latin1ToUtf8Impl(comptime checked: bool, src: []const u8, dst: []u8) Result {
    const run = struct {
        fn f(s: []const u8, d: []u8) Result {
            if (checked) return scalar.latin1ToUtf8(s, d);
            return .ok(scalar.validLatin1ToUtf8(s, d));
        }
    }.f;
    if (v512) {
        if (src.len <= 64) if (latin1ToUtf8Whole(src, dst)) |o| return .ok(o);
        return longPath(true, latin1ToUtf8Long, .{checked}, src, dst);
    }
    var p: usize = 0;
    var o: usize = 0;
    var steps: Steps = .{};
    if (use_simd) while (true) {
        while (src.len - p >= 16 and dst.len - o >= 32) {
            if (src.len - p >= 64 and dst.len - o >= 64) {
                const block = simd.load(u8, src[p..]);
                if (below(0x80, block)) {
                    store(u8, native, dst, o, block);
                    p += 64;
                    o += 64;
                    continue;
                }
                // Each 16 bytes to two-byte UTF-8, without branching on
                // whether they are ASCII: in Latin-1 text that branch
                // mispredicts.
                if (fast_shuffle and dst.len - o >= 128) {
                    const a: [64]u8 = block;
                    inline for (0..4) |k| utf8From2x16(@as(V16, a[16 * k ..][0..16].*), dst, &o);
                    p += 64;
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
                utf8From2x16(w, dst, &o);
            }
            p += 16;
        }
        if (fast_shuffle or !(src.len - p >= 16 and dst.len - o >= 32)) break;
        if (scalarStep(run, src, p + @min(steps.next(p), src.len - p), dst, &p, &o, &steps)) |r| return r;
    };
    return tail(run(src[p..], dst[o..]), p, o);
}

fn latin1ToUtf8Long(comptime checked: bool, src: []const u8, dst: []u8) Result {
    const p, const o = if (src.len <= 64) latin1ToUtf8Short(src, dst) else latin1ToUtf8Avx512(src, dst);
    if (checked) return tail(scalar.latin1ToUtf8(src[p..], dst[o..]), p, o);
    return .ok(o + scalar.validLatin1ToUtf8(src[p..], dst[o..]));
}

fn latin1ToUnits(comptime T: type, comptime e: Endian, comptime checked: bool, src: []const u8, dst: []T) Result {
    // With room for all of it, blocks and one masked tail, and none of the
    // checks on the output's room: 64 bytes took 8.4 ns, simdutf 6.2.
    if (v512 and dst.len >= src.len) {
        if (src.len < 64) {
            if (src.len > 0) storeWidened(T, e, dst, 0, simd.loadShort(u8, src), src.len);
            return .ok(src.len);
        }
        var p: usize = 0;
        var step = firstStep(T, dst, src.len, 64);
        while (src.len - p >= 64) : (step = 64) {
            store(T, e, dst, p, simd.load(u8, src[p..]));
            p += step;
        }
        if (p < src.len) storeWidened(T, e, dst, p, simd.loadTail(src, p, src.len), src.len - p);
        return .ok(src.len);
    }
    var p: usize = 0;
    if (use_simd) {
        const lim = @min(src.len, dst.len);
        var step = firstStep(T, dst, src.len, 64);
        while (lim - p >= 64) : (step = 64) {
            // UTF-32 keeps one 64-byte load: 16-byte loads cost SSE 15% at
            // 4 KiB.
            if (v512 or (T == u32 and !neon))
                store(T, e, dst, p, simd.load(u8, src[p..]))
            else
                widenAscii(T, e, src[p..], dst[p..]);
            p += step;
        }
        while (lim - p >= 16) {
            store(T, e, dst, p, if (T == u32) @as(V16, src[p..][0..16].*) else widenLoad(src[p..]));
            p += 16;
        }
        if (v512 and p < src.len and src.len - p <= dst.len - p) {
            storeWidened(T, e, dst, p, simd.loadShort(u8, src[p..][0 .. src.len - p]), src.len - p);
            p = src.len;
        }
        // Done: the checked form's result built here, not after an empty
        // scalar pass (16 bytes 0.7 ns slower than the valid form).
        if (p == src.len) return .ok(p);
    }
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

const Mix = enum { ascii, latin1, two_byte, cjk, cjk_text, emoji, mixed, edges };

const edges = [_]u32{ 0, 0x7F, 0x80, 0xFF, 0x100, 0x7FF, 0x800, 0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF };

fn randomCodePoint(r: std.Random, mix: Mix) u32 {
    const ascii = r.uintLessThan(u32, 0x80);
    return switch (mix) {
        .ascii => ascii,
        .latin1 => if (r.boolean()) ascii else r.intRangeLessThan(u32, 0x80, 0x100),
        .two_byte => if (r.uintLessThan(u8, 8) == 0) ascii else r.intRangeLessThan(u32, 0x80, 0x800),
        .cjk => if (r.uintLessThan(u8, 8) == 0) ascii else r.intRangeLessThan(u32, 0x3000, 0xA000),
        // Runs of three-byte characters dozens long, as Chinese and
        // Japanese text has between its spaces and ASCII punctuation.
        .cjk_text => if (r.uintLessThan(u8, 32) == 0) ascii else r.intRangeLessThan(u32, 0x3000, 0xA000),
        .emoji => if (r.uintLessThan(u8, 8) == 0) ascii else r.intRangeLessThan(u32, 0x1F300, 0x1FB00),
        .mixed => switch (r.uintLessThan(u8, 5)) {
            0 => ascii,
            1 => r.intRangeLessThan(u32, 0x80, 0x800),
            2 => r.intRangeLessThan(u32, 0x800, 0xD800),
            3 => r.intRangeLessThan(u32, 0xE000, 0x10000),
            else => r.intRangeLessThan(u32, 0x10000, 0x110000),
        },
        // The ends of each length class, zero included.
        .edges => edges[r.uintLessThan(usize, edges.len)],
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
    try dispatch.forEachLevel(validTextCases, .{});
}

fn validTextCases() !void {
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

test "long inputs match the scalar reference at every alignment" {
    try dispatch.forEachLevel(alignmentCases, .{});
}

/// The fixed-ratio loops start long inputs on a 64-byte boundary of their
/// input or output: every offset of both, valid and with an error late on.
fn alignmentCases() !void {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    var cps: [1500]u32 = undefined;
    for (&cps) |*cp| cp.* = randomCodePoint(r, .latin1);
    const formats = .{ Format.latin1, Format.utf16le, Format.utf16be, Format.utf32 };
    inline for (formats) |from| inline for (formats) |to| if (from != to) {
        const F = from.Unit();
        const T = to.Unit();
        var in: [1500 + 64]F = undefined;
        var want: [1500]T = undefined;
        var got: [1500 + 64]T = undefined;
        for (0..64 / @sizeOf(F)) |i| {
            const src = in[i..][0..cps.len];
            const o = (7 * i + 3) % (64 / @sizeOf(T));
            for (src, cps) |*u, cp| u.* = @intCast(if (from == .utf16be) @byteSwap(@as(u16, @intCast(cp))) else cp);
            // An error in the last 64 units, for the formats that have one.
            if (from != .latin1 and to == .latin1 and i % 2 == 1) {
                const at = cps.len - 1 - r.uintLessThan(usize, 64);
                src[at] = if (from == .utf16be) 0x0001 else 0x100;
            }
            if (from == .utf16le and to == .utf16be and i % 2 == 1) {
                src[cps.len - 1 - r.uintLessThan(usize, 64)] = 0xDC00;
            }
            inline for (.{ true, false }) |checked| {
                const w = refConvert(from, to, true, src, &want);
                if (checked or w.err == .none) {
                    const g = simdConvert(from, to, checked, src, got[o..][0..cps.len]);
                    try testing.expectEqual(w, g);
                    if (w.err == .none) try testing.expectEqualSlices(T, want[0..w.count], got[o..][0..w.count]);
                }
            }
        }
    };
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
    try dispatch.forEachLevel(errorCases, .{});
}

fn errorCases() !void {
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
    for ([_]Mix{ .latin1, .cjk, .cjk_text, .mixed }) |mix| {
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

test "inputs past a million units match the scalar reference" {
    try dispatch.forEachLevel(largeCases, .{});
}

/// Long runs leave one loop for millions of iterations, so counters and
/// offsets that overflow or drift late show only here: valid text of every
/// mix that converts, and one error near the end.
fn largeCases() !void {
    @setEvalBranchQuota(10_000);
    const n = 32 * 21845 + 35;
    const a = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    const cps = try a.alloc(u32, n);
    defer a.free(cps);
    const bufs = .{
        try a.alloc(u8, 4 * n), try a.alloc(u16, 2 * n), try a.alloc(u16, 2 * n),
        try a.alloc(u32, n),    try a.alloc(u8, n),
    };
    defer inline for (bufs) |b| a.free(b);
    for ([_]Mix{ .ascii, .latin1, .mixed }) |mix| {
        for (cps) |*cp| cp.* = randomCodePoint(r, mix);
        const n8 = scalar.validUtf32ToUtf8(cps, bufs[0]);
        const n16 = scalar.validUtf32ToUtf16(.little, cps, bufs[1]);
        _ = scalar.validUtf32ToUtf16(.big, cps, bufs[2]);
        @memcpy(bufs[3], cps);
        const latin1 = scalar.utf32ToLatin1(cps, bufs[4]).err == .none;
        const texts = .{ bufs[0][0..n8], bufs[1][0..n16], bufs[2][0..n16], bufs[3], bufs[4] };
        inline for (conversions) |pair| {
            const from, const to = pair;
            const src = texts[@backingInt(from)];
            if ((from != .latin1 and to != .latin1) or latin1) {
                const T = to.Unit();
                const size = needed(from, to, src);
                const want = try a.alloc(T, size);
                defer a.free(want);
                const got = try a.alloc(T, size);
                defer a.free(got);
                inline for (.{ true, false }) |checked| {
                    const w = refConvert(from, to, checked, src, want);
                    try testing.expectEqual(w, simdConvert(from, to, checked, src, got));
                    try testing.expectEqualSlices(T, want[0..w.count], got[0..w.count]);
                }
                // An error near the end, for the formats that have one.
                if (from != .latin1) {
                    const at = src.len - 1 - r.uintLessThan(usize, 100);
                    const old = src[at];
                    src[at] = switch (from) {
                        .utf8 => 0xFF,
                        .utf16le => 0xDC00,
                        .utf16be => 0x00DC,
                        .utf32 => 0x110000,
                        .latin1 => unreachable,
                    };
                    defer src[at] = old;
                    const w = refConvert(from, to, true, src, want);
                    try testing.expectEqual(w, simdConvert(from, to, true, src, got));
                }
            }
        }
    }
}
