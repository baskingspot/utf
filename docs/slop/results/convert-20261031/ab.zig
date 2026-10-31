//! Interleaved A/B of utf's transcoders and length functions: this tree as
//! `new`, another as `old`, and simdutf (linked from nixpkgs; pin its kernel
//! with SIMDUTF_FORCE_IMPLEMENTATION), on five corpora at sizes from 16 bytes
//! to 1 MiB. Prints Go benchmark lines (benchstat reads them): one per sample,
//! samples interleaved across arms.
//!
//! Build: zig build-exe -OReleaseFast -mcpu=<cpu> -lc -L<simdutf>/lib -lsimdutf \
//!   -rpath <simdutf>/lib --dep utf --dep old -Mroot=ab.zig \
//!   -Mutf=<repo>/src/root.zig -Mold=<old tree>/src/root.zig
//! Run pinned: BENCH_FILTER=<label substring> BENCH_ARMS=new,simdutf taskset -c 2 ./ab
const std = @import("std");
const utf = @import("utf");
const old = @import("old");

/// The scalar reference under the public names, for the generic build.
const Scalar = struct {
    const s = utf.scalar_convert;
    noinline fn utf8ToUtf16le(a: []const u8, b: []u16) utf.Result { return s.utf8ToUtf16(.little, a, b); }
    noinline fn validUtf8ToUtf16le(a: []const u8, b: []u16) usize { return s.validUtf8ToUtf16(.little, a, b); }
    noinline fn utf16leToUtf8(a: []const u16, b: []u8) utf.Result { return s.utf16ToUtf8(.little, a, b); }
    noinline fn validUtf16leToUtf8(a: []const u16, b: []u8) usize { return s.validUtf16ToUtf8(.little, a, b); }
    noinline fn utf8ToUtf32(a: []const u8, b: []u32) utf.Result { return s.utf8ToUtf32(a, b); }
    noinline fn validUtf8ToUtf32(a: []const u8, b: []u32) usize { return s.validUtf8ToUtf32(a, b); }
    noinline fn utf32ToUtf8(a: []const u32, b: []u8) utf.Result { return s.utf32ToUtf8(a, b); }
    noinline fn validUtf32ToUtf8(a: []const u32, b: []u8) usize { return s.validUtf32ToUtf8(a, b); }
    noinline fn utf16leToUtf32(a: []const u16, b: []u32) utf.Result { return s.utf16ToUtf32(.little, a, b); }
    noinline fn validUtf16leToUtf32(a: []const u16, b: []u32) usize { return s.validUtf16ToUtf32(.little, a, b); }
    noinline fn utf32ToUtf16le(a: []const u32, b: []u16) utf.Result { return s.utf32ToUtf16(.little, a, b); }
    noinline fn validUtf32ToUtf16le(a: []const u32, b: []u16) usize { return s.validUtf32ToUtf16(.little, a, b); }
    noinline fn utf8ToLatin1(a: []const u8, b: []u8) utf.Result { return s.utf8ToLatin1(a, b); }
    noinline fn validUtf8ToLatin1(a: []const u8, b: []u8) usize { return s.validUtf8ToLatin1(a, b); }
    noinline fn utf16leToUtf16be(a: []const u16, b: []u16) utf.Result { return s.utf16ToUtf16Swapped(.little, a, b); }
    noinline fn validUtf16leToUtf16be(a: []const u16, b: []u16) usize { return s.validUtf16ToUtf16Swapped(a, b); }
    noinline fn utf16leToLatin1(a: []const u16, b: []u8) utf.Result { return s.utf16ToLatin1(.little, a, b); }
    noinline fn validUtf16leToLatin1(a: []const u16, b: []u8) usize { return s.validUtf16ToLatin1(.little, a, b); }
    noinline fn utf32ToLatin1(a: []const u32, b: []u8) utf.Result { return s.utf32ToLatin1(a, b); }
    noinline fn validUtf32ToLatin1(a: []const u32, b: []u8) usize { return s.validUtf32ToLatin1(a, b); }
    noinline fn latin1ToUtf8(a: []const u8, b: []u8) utf.Result { return s.latin1ToUtf8(a, b); }
    noinline fn validLatin1ToUtf8(a: []const u8, b: []u8) usize { return s.validLatin1ToUtf8(a, b); }
    noinline fn latin1ToUtf16le(a: []const u8, b: []u16) utf.Result { return s.latin1ToUtf16(.little, a, b); }
    noinline fn validLatin1ToUtf16le(a: []const u8, b: []u16) usize { return s.validLatin1ToUtf16(.little, a, b); }
    noinline fn latin1ToUtf32(a: []const u8, b: []u32) utf.Result { return s.latin1ToUtf32(a, b); }
    noinline fn validLatin1ToUtf32(a: []const u8, b: []u32) usize { return s.validLatin1ToUtf32(a, b); }
};

const Res = extern struct { err: c_int, count: usize };
const C = struct {
    extern fn simdutf_convert_utf8_to_utf16le_with_errors([*]const u8, usize, [*]u16) Res;
    extern fn simdutf_convert_valid_utf8_to_utf16le([*]const u8, usize, [*]u16) usize;
    extern fn simdutf_convert_utf16le_to_utf8_with_errors([*]const u16, usize, [*]u8) Res;
    extern fn simdutf_convert_valid_utf16le_to_utf8([*]const u16, usize, [*]u8) usize;
    extern fn simdutf_convert_utf8_to_utf32_with_errors([*]const u8, usize, [*]u32) Res;
    extern fn simdutf_convert_valid_utf8_to_utf32([*]const u8, usize, [*]u32) usize;
    extern fn simdutf_convert_utf32_to_utf8_with_errors([*]const u32, usize, [*]u8) Res;
    extern fn simdutf_convert_valid_utf32_to_utf8([*]const u32, usize, [*]u8) usize;
    extern fn simdutf_convert_utf16le_to_utf32_with_errors([*]const u16, usize, [*]u32) Res;
    extern fn simdutf_convert_valid_utf16le_to_utf32([*]const u16, usize, [*]u32) usize;
    extern fn simdutf_convert_utf32_to_utf16le([*]const u32, usize, [*]u16) usize;
    extern fn simdutf_convert_utf8_to_latin1_with_errors([*]const u8, usize, [*]u8) Res;
    extern fn simdutf_convert_valid_utf8_to_latin1([*]const u8, usize, [*]u8) usize;
    extern fn simdutf_convert_latin1_to_utf8([*]const u8, usize, [*]u8) usize;
    extern fn simdutf_convert_latin1_to_utf16le([*]const u8, usize, [*]u16) usize;
    extern fn simdutf_convert_latin1_to_utf32([*]const u8, usize, [*]u32) usize;
    extern fn simdutf_convert_utf16le_to_latin1_with_errors([*]const u16, usize, [*]u8) Res;
    extern fn simdutf_convert_valid_utf16le_to_latin1([*]const u16, usize, [*]u8) usize;
    extern fn simdutf_convert_utf32_to_latin1_with_errors([*]const u32, usize, [*]u8) Res;
    extern fn simdutf_utf16_length_from_utf8([*]const u8, usize) usize;
    extern fn simdutf_utf8_length_from_utf16le([*]const u16, usize) usize;
    extern fn simdutf_utf8_length_from_utf32([*]const u32, usize) usize;
    extern fn simdutf_utf8_length_from_latin1([*]const u8, usize) usize;
    extern fn simdutf_count_utf8([*]const u8, usize) usize;
    extern fn simdutf_count_utf16le([*]const u16, usize) usize;
    extern fn simdutf_validate_utf16le_with_errors([*]const u16, usize) Res;
    extern fn @"_ZN7simdutf23change_endianness_utf16EPKDsmPDs"([*]const u16, usize, [*]u16) void;
    /// The harness's checked byte swap: validate, then swap.
    fn swap_checked(p: [*]const u16, n: usize, o: [*]u16) Res {
        const v = simdutf_validate_utf16le_with_errors(p, n);
        if (v.err != 0) return v;
        @"_ZN7simdutf23change_endianness_utf16EPKDsmPDs"(p, n, o);
        return .{ .err = 0, .count = n };
    }
    fn swap_valid(p: [*]const u16, n: usize, o: [*]u16) usize {
        @"_ZN7simdutf23change_endianness_utf16EPKDsmPDs"(p, n, o);
        return n;
    }
};

const Input = struct {
    utf8: []const u8,
    utf16: []const u16,
    utf32: []const u32,
    latin1: []const u8,
};

var out8: [8 << 20]u8 = undefined;
var out16: [4 << 20]u16 = undefined;
var out32: [2 << 20]u32 = undefined;

const Run = *const fn (*const Input) usize;
const Arm = struct { []const u8, Run };
const Src = enum { utf8, utf16, utf32, latin1 };
const Op = struct { name: []const u8, src: Src, arms: []const Arm };

fn r(x: anytype) usize {
    return switch (@TypeOf(x)) {
        usize => x,
        Res => if (x.err == 0) x.count else unreachable,
        else => if (x.err == .none) x.count else unreachable,
    };
}

fn srcOf(comptime in: Src, i: *const Input) switch (in) {
    .utf8, .latin1 => []const u8,
    .utf16 => []const u16,
    .utf32 => []const u32,
} {
    return switch (in) {
        .utf8 => i.utf8,
        .utf16 => i.utf16,
        .utf32 => i.utf32,
        .latin1 => i.latin1,
    };
}

fn dstFor(comptime D: type) []D {
    return switch (D) {
        u8 => &out8,
        u16 => &out16,
        u32 => &out32,
        else => unreachable,
    };
}

/// One of our functions, `(src, dst)` or `(src)`.
fn ours(comptime M: type, comptime fname: []const u8, comptime in: Src) Run {
    return struct {
        fn f(i: *const Input) usize {
            const F = @field(M, fname);
            const params = @typeInfo(@TypeOf(F)).@"fn".params;
            const s = srcOf(in, i);
            if (params.len == 1) return F(s);
            const Dst = @typeInfo(params[1].type.?).pointer.child;
            return r(F(s, dstFor(Dst)));
        }
    }.f;
}

/// One of simdutf's C functions, `(ptr, len, out)` or `(ptr, len)`.
fn theirs(comptime fname: []const u8, comptime in: Src) Run {
    return struct {
        fn f(i: *const Input) usize {
            const F = @field(C, fname);
            const params = @typeInfo(@TypeOf(F)).@"fn".params;
            const s = srcOf(in, i);
            if (params.len == 2) return F(s.ptr, s.len);
            const Dst = @typeInfo(params[2].type.?).pointer.child;
            return r(F(s.ptr, s.len, dstFor(Dst).ptr));
        }
    }.f;
}

// name, input, our checked, our valid, simdutf checked, simdutf valid ("" for none)
const conversions = .{
    .{ "Utf8ToUtf16le", Src.utf8, "utf8ToUtf16le", "validUtf8ToUtf16le", "simdutf_convert_utf8_to_utf16le_with_errors", "simdutf_convert_valid_utf8_to_utf16le" },
    .{ "Utf16leToUtf8", Src.utf16, "utf16leToUtf8", "validUtf16leToUtf8", "simdutf_convert_utf16le_to_utf8_with_errors", "simdutf_convert_valid_utf16le_to_utf8" },
    .{ "Utf8ToUtf32", Src.utf8, "utf8ToUtf32", "validUtf8ToUtf32", "simdutf_convert_utf8_to_utf32_with_errors", "simdutf_convert_valid_utf8_to_utf32" },
    .{ "Utf32ToUtf8", Src.utf32, "utf32ToUtf8", "validUtf32ToUtf8", "simdutf_convert_utf32_to_utf8_with_errors", "simdutf_convert_valid_utf32_to_utf8" },
    .{ "Utf16leToUtf32", Src.utf16, "utf16leToUtf32", "validUtf16leToUtf32", "simdutf_convert_utf16le_to_utf32_with_errors", "simdutf_convert_valid_utf16le_to_utf32" },
    .{ "Utf32ToUtf16le", Src.utf32, "utf32ToUtf16le", "validUtf32ToUtf16le", "simdutf_convert_utf32_to_utf16le", "" },
    .{ "Utf8ToLatin1", Src.utf8, "utf8ToLatin1", "validUtf8ToLatin1", "simdutf_convert_utf8_to_latin1_with_errors", "simdutf_convert_valid_utf8_to_latin1" },
    .{ "Utf16leToUtf16be", Src.utf16, "utf16leToUtf16be", "validUtf16leToUtf16be", "swap_checked", "swap_valid" },
    .{ "Utf16leToLatin1", Src.utf16, "utf16leToLatin1", "validUtf16leToLatin1", "simdutf_convert_utf16le_to_latin1_with_errors", "simdutf_convert_valid_utf16le_to_latin1" },
    .{ "Utf32ToLatin1", Src.utf32, "utf32ToLatin1", "validUtf32ToLatin1", "simdutf_convert_utf32_to_latin1_with_errors", "" },
    .{ "Latin1ToUtf8", Src.latin1, "latin1ToUtf8", "validLatin1ToUtf8", "simdutf_convert_latin1_to_utf8", "" },
    .{ "Latin1ToUtf16le", Src.latin1, "latin1ToUtf16le", "validLatin1ToUtf16le", "simdutf_convert_latin1_to_utf16le", "" },
    .{ "Latin1ToUtf32", Src.latin1, "latin1ToUtf32", "validLatin1ToUtf32", "simdutf_convert_latin1_to_utf32", "" },
};
// name, input, ours, simdutf
const lengths = .{
    .{ "Utf16FromUtf8", Src.utf8, "utf16FromUtf8", "simdutf_utf16_length_from_utf8" },
    .{ "Utf8FromUtf16le", Src.utf16, "utf8FromUtf16le", "simdutf_utf8_length_from_utf16le" },
    .{ "Utf8FromUtf32", Src.utf32, "utf8FromUtf32", "simdutf_utf8_length_from_utf32" },
    .{ "Utf8FromLatin1", Src.latin1, "utf8FromLatin1", "simdutf_utf8_length_from_latin1" },
    .{ "CountUtf8", Src.utf8, "countUtf8", "simdutf_count_utf8" },
    .{ "CountUtf16le", Src.utf16, "countUtf16le", "simdutf_count_utf16le" },
};

const ops = blk: {
    var list: []const Op = &.{};
    for (conversions) |sp| {
        var arms: []const Arm = &.{
            .{ "new", ours(utf.convert, sp[2], sp[1]) },
            .{ "new-valid", ours(utf.convert, sp[3], sp[1]) },
            .{ "old", ours(old.convert, sp[2], sp[1]) },
            .{ "old-valid", ours(old.convert, sp[3], sp[1]) },
            .{ "simdutf", theirs(sp[4], sp[1]) },
            .{ "scalar", ours(Scalar, sp[2], sp[1]) },
            .{ "scalar-valid", ours(Scalar, sp[3], sp[1]) },
        };
        if (sp[5].len > 0) arms = arms ++ &[_]Arm{.{ "simdutf-valid", theirs(sp[5], sp[1]) }};
        list = list ++ &[_]Op{.{ .name = sp[0], .src = sp[1], .arms = arms }};
    }
    for (lengths) |sp| {
        const arms: []const Arm = &.{
            .{ "new", ours(utf.length, sp[2], sp[1]) },
            .{ "old", ours(old.length, sp[2], sp[1]) },
            .{ "simdutf", theirs(sp[3], sp[1]) },
        };
        list = list ++ &[_]Op{.{ .name = sp[0], .src = sp[1], .arms = arms }};
    }
    break :blk list;
};

const corpora = [_]struct { []const u8, []const u8 }{
    .{ "ascii", @embedFile("corpus/Latin-Lipsum.utf8.txt") },
    .{ "latin", @embedFile("corpus/french.utf8.txt") },
    .{ "cyrillic", @embedFile("corpus/russian.utf8.txt") },
    .{ "cjk", @embedFile("corpus/Chinese-Lipsum.utf8.txt") },
    .{ "emoji", @embedFile("corpus/Emoji-Lipsum.utf8.txt") },
    .{ "latin1t", @embedFile("corpus/latin1t.utf8.txt") },
    .{ "korean", @embedFile("corpus/korean.utf8.txt") },
    .{ "hindi", @embedFile("corpus/hindi.utf8.txt") },
};
const all_sizes = [_]usize{ 16, 64, 256, 1024, 4096, 65536, 1 << 20 };

fn now() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

var text_buf: [1 << 20]u8 = undefined;
var latin1_buf: [1 << 20]u8 = undefined;
var utf16_buf: [1 << 20]u16 = undefined;
var utf32_buf: [1 << 20]u32 = undefined;
var filtered_buf: [1 << 20]u8 = undefined;

/// `size` bytes of `corpus`, repeated as needed, cut back to a character
/// boundary.
fn fill(dst: []u8, corpus: []const u8, size: usize) []u8 {
    var n: usize = 0;
    while (n < size) {
        const k = @min(corpus.len, size - n);
        @memcpy(dst[n..][0..k], corpus[0..k]);
        n += k;
    }
    var end = n;
    var i = end;
    while (i > 0 and dst[i - 1] & 0xC0 == 0x80) i -= 1;
    if (i > 0) {
        const lead = dst[i - 1];
        const len: usize = if (lead < 0x80) 1 else if (lead < 0xE0) 2 else if (lead < 0xF0) 3 else 4;
        if (i - 1 + len > end) end = i - 1;
    }
    return dst[0..end];
}

fn env(name: [*:0]const u8) []const u8 {
    return if (std.c.getenv(name)) |f| std.mem.span(f) else "";
}

fn armSelected(arms: []const u8, name: []const u8) bool {
    if (arms.len == 0) return true;
    var it = std.mem.splitScalar(u8, arms, ',');
    while (it.next()) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}

pub fn main() void {
    const filter = env("BENCH_FILTER");
    const arm_filter = env("BENCH_ARMS");
    const sizes_env = env("BENCH_SIZES");
    const samples: usize = if (env("BENCH_SAMPLES").len > 0) std.fmt.parseInt(usize, env("BENCH_SAMPLES"), 10) catch 7 else 7;
    const target_ns: u64 = 4 * std.time.ns_per_ms;

    // The Latin-1 corpus: French with the characters above U+00FF dropped.
    const french = corpora[1][1];
    var flen: usize = 0;
    {
        var it = std.unicode.Utf8View.initUnchecked(french).iterator();
        while (it.nextCodepointSlice()) |s| {
            const cp = std.unicode.utf8Decode(s) catch unreachable;
            if (cp <= 0xFF) {
                @memcpy(filtered_buf[flen..][0..s.len], s);
                flen += s.len;
            }
        }
    }

    var sink: usize = 0;
    for (ops) |op| for (corpora) |corpus| for (all_sizes) |size| {
        const name, const raw = corpus;
        if (sizes_env.len > 0) {
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, ",{d},", .{size}) catch unreachable;
            var wbuf: [128]u8 = undefined;
            const w = std.fmt.bufPrint(&wbuf, ",{s},", .{sizes_env}) catch unreachable;
            if (std.mem.indexOf(u8, w, s) == null) continue;
        }
        const to_latin1 = std.mem.endsWith(u8, op.name, "Latin1") or std.mem.startsWith(u8, op.name, "Latin1") or
            std.mem.endsWith(u8, op.name, "FromLatin1");
        if (to_latin1 and !(std.mem.eql(u8, name, "ascii") or std.mem.eql(u8, name, "latin") or std.mem.eql(u8, name, "latin1t"))) continue;
        const base = if (to_latin1 and std.mem.eql(u8, name, "latin")) filtered_buf[0..flen] else raw;
        const u8s = fill(&text_buf, base, size);
        const n16 = utf.convert.validUtf8ToUtf16le(u8s, &utf16_buf);
        const n32 = utf.convert.validUtf8ToUtf32(u8s, &utf32_buf);
        const nl1 = if (to_latin1) utf.convert.validUtf8ToLatin1(u8s, &latin1_buf) else 0;
        const input: Input = .{ .utf8 = u8s, .utf16 = utf16_buf[0..n16], .utf32 = utf32_buf[0..n32], .latin1 = latin1_buf[0..nl1] };
        const in_bytes: usize = switch (op.src) {
            .utf8 => u8s.len,
            .utf16 => 2 * n16,
            .utf32 => 4 * n32,
            .latin1 => nl1,
        };
        var label_buf: [128]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "{s}/corpus={s}/size={d}", .{ op.name, name, size }) catch unreachable;
        if (filter.len > 0) {
            var ok = false;
            var it = std.mem.splitScalar(u8, filter, '|');
            while (it.next()) |f| if (std.mem.indexOf(u8, label, f) != null) {
                ok = true;
            };
            if (!ok) continue;
        }
        // Calibrate each arm, and check they agree.
        var iters: [8]usize = @splat(0);
        var want: ?usize = null;
        for (op.arms, 0..) |arm, a| {
            if (!armSelected(arm_filter, arm[0])) continue;
            const got = arm[1](&input);
            if (want) |w| if (w != got) std.debug.print("MISMATCH {s} {s}: {d} vs {d}\n", .{ label, arm[0], w, got });
            want = got;
            var n: usize = 1;
            while (true) : (n *= 2) {
                const t0 = now();
                for (0..n) |_| sink +%= arm[1](&input);
                if (now() - t0 > target_ns / 4) break;
            }
            iters[a] = n * 4;
        }
        for (0..samples) |_| for (op.arms, 0..) |arm, a| {
            if (iters[a] == 0) continue;
            const t0 = now();
            for (0..iters[a]) |_| {
                std.mem.doNotOptimizeAway(&input);
                sink +%= arm[1](&input);
            }
            const ns = now() - t0;
            const per = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iters[a]));
            const mbs = @as(f64, @floatFromInt(in_bytes)) * 1000.0 / per;
            std.debug.print("Benchmark{s}/arm={s} {d} {d:.2} ns/op {d:.2} MB/s\n", .{ label, arm[0], iters[a], per, mbs });
        };
    };
    std.mem.doNotOptimizeAway(sink);
}
