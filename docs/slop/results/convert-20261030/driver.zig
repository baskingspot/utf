//! Throughput of utf's transcoders against its scalar reference, Zig's
//! std.unicode, and simdutf (linked from nixpkgs), on four corpora at sizes
//! from 16 bytes to 1 MiB. Prints Go benchmark lines (benchstat reads them):
//! one per sample, samples interleaved across arms.
//!
//! Build: zig build-exe -OReleaseFast -mcpu=<cpu> -lc -lsimdutf \
//!   --dep utf -Mroot=bench.zig -Mutf=<repo>/src/root.zig
//! Run pinned: taskset -c 2 ./bench [filter]
const std = @import("std");
const utf = @import("utf");
const cv = utf.convert;
const sc = utf.scalar_convert;
const ln = utf.length;

const Res = extern struct { err: c_int, count: usize };
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
extern fn simdutf_utf16_length_from_utf8([*]const u8, usize) usize;
extern fn simdutf_utf8_length_from_utf16le([*]const u16, usize) usize;
extern fn simdutf_count_utf8([*]const u8, usize) usize;
extern fn simdutf_validate_utf8([*]const u8, usize) bool;
extern fn simdutf_validate_utf16le([*]const u16, usize) bool;

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
    return if (@TypeOf(x) == utf.Result) x.count else x;
}

const ops = [_]Op{
    .{ .name = "Utf8ToUtf16le", .src = .utf8, .arms = &.{
        .{ "utf", struct {
            fn f(i: *const Input) usize {
                return r(cv.utf8ToUtf16le(i.utf8, &out16));
            }
        }.f },
        .{ "utf-valid", struct {
            fn f(i: *const Input) usize {
                return cv.validUtf8ToUtf16le(i.utf8, &out16);
            }
        }.f },
        .{ "validate+utf-valid", struct {
            fn f(i: *const Input) usize {
                if (!simdutf_validate_utf8(i.utf8.ptr, i.utf8.len)) unreachable;
                return cv.validUtf8ToUtf16le(i.utf8, &out16);
            }
        }.f },
        .{ "scalar", struct {
            fn f(i: *const Input) usize {
                return r(sc.utf8ToUtf16(.little, i.utf8, &out16));
            }
        }.f },
        .{ "std", struct {
            fn f(i: *const Input) usize {
                return std.unicode.utf8ToUtf16Le(&out16, i.utf8) catch unreachable;
            }
        }.f },
        .{ "simdutf", struct {
            fn f(i: *const Input) usize {
                return simdutf_convert_utf8_to_utf16le_with_errors(i.utf8.ptr, i.utf8.len, &out16).count;
            }
        }.f },
        .{ "simdutf-valid", struct {
            fn f(i: *const Input) usize {
                return simdutf_convert_valid_utf8_to_utf16le(i.utf8.ptr, i.utf8.len, &out16);
            }
        }.f },
    } },
    .{ .name = "Utf16leToUtf8", .src = .utf16, .arms = &.{
        .{ "utf", struct {
            fn f(i: *const Input) usize {
                return r(cv.utf16leToUtf8(i.utf16, &out8));
            }
        }.f },
        .{ "utf-valid", struct {
            fn f(i: *const Input) usize {
                return cv.validUtf16leToUtf8(i.utf16, &out8);
            }
        }.f },
        .{ "validate+utf-valid", struct {
            fn f(i: *const Input) usize {
                if (!simdutf_validate_utf16le(i.utf16.ptr, i.utf16.len)) unreachable;
                return cv.validUtf16leToUtf8(i.utf16, &out8);
            }
        }.f },
        .{ "scalar", struct {
            fn f(i: *const Input) usize {
                return r(sc.utf16ToUtf8(.little, i.utf16, &out8));
            }
        }.f },
        .{ "std", struct {
            fn f(i: *const Input) usize {
                return std.unicode.utf16LeToUtf8(&out8, i.utf16) catch unreachable;
            }
        }.f },
        .{ "simdutf", struct {
            fn f(i: *const Input) usize {
                return simdutf_convert_utf16le_to_utf8_with_errors(i.utf16.ptr, i.utf16.len, &out8).count;
            }
        }.f },
        .{ "simdutf-valid", struct {
            fn f(i: *const Input) usize {
                return simdutf_convert_valid_utf16le_to_utf8(i.utf16.ptr, i.utf16.len, &out8);
            }
        }.f },
    } },
    .{ .name = "Utf8ToUtf32", .src = .utf8, .arms = &.{
        .{ "utf", struct {
            fn f(i: *const Input) usize {
                return r(cv.utf8ToUtf32(i.utf8, &out32));
            }
        }.f },
        .{ "utf-valid", struct {
            fn f(i: *const Input) usize {
                return cv.validUtf8ToUtf32(i.utf8, &out32);
            }
        }.f },
        .{ "scalar", struct {
            fn f(i: *const Input) usize {
                return r(sc.utf8ToUtf32(i.utf8, &out32));
            }
        }.f },
        .{ "std", struct {
            fn f(i: *const Input) usize {
                var it = (std.unicode.Utf8View.init(i.utf8) catch unreachable).iterator();
                var n: usize = 0;
                while (it.nextCodepoint()) |cp| : (n += 1) out32[n] = cp;
                return n;
            }
        }.f },
        .{ "simdutf", struct {
            fn f(i: *const Input) usize {
                return simdutf_convert_utf8_to_utf32_with_errors(i.utf8.ptr, i.utf8.len, &out32).count;
            }
        }.f },
        .{ "simdutf-valid", struct {
            fn f(i: *const Input) usize {
                return simdutf_convert_valid_utf8_to_utf32(i.utf8.ptr, i.utf8.len, &out32);
            }
        }.f },
    } },
    .{ .name = "Utf32ToUtf8", .src = .utf32, .arms = &.{
        .{ "utf", struct {
            fn f(i: *const Input) usize {
                return r(cv.utf32ToUtf8(i.utf32, &out8));
            }
        }.f },
        .{ "utf-valid", struct {
            fn f(i: *const Input) usize {
                return cv.validUtf32ToUtf8(i.utf32, &out8);
            }
        }.f },
        .{ "scalar", struct {
            fn f(i: *const Input) usize {
                return r(sc.utf32ToUtf8(i.utf32, &out8));
            }
        }.f },
        .{ "std", struct {
            fn f(i: *const Input) usize {
                var n: usize = 0;
                for (i.utf32) |cp| n += std.unicode.utf8Encode(@intCast(cp), out8[n..]) catch unreachable;
                return n;
            }
        }.f },
        .{ "simdutf", struct {
            fn f(i: *const Input) usize {
                return simdutf_convert_utf32_to_utf8_with_errors(i.utf32.ptr, i.utf32.len, &out8).count;
            }
        }.f },
        .{ "simdutf-valid", struct {
            fn f(i: *const Input) usize {
                return simdutf_convert_valid_utf32_to_utf8(i.utf32.ptr, i.utf32.len, &out8);
            }
        }.f },
    } },
    .{ .name = "Utf16leToUtf32", .src = .utf16, .arms = &.{
        .{ "utf", struct {
            fn f(i: *const Input) usize {
                return r(cv.utf16leToUtf32(i.utf16, &out32));
            }
        }.f },
        .{ "utf-valid", struct {
            fn f(i: *const Input) usize {
                return cv.validUtf16leToUtf32(i.utf16, &out32);
            }
        }.f },
        .{ "scalar", struct {
            fn f(i: *const Input) usize {
                return r(sc.utf16ToUtf32(.little, i.utf16, &out32));
            }
        }.f },
        .{ "simdutf", struct {
            fn f(i: *const Input) usize {
                return simdutf_convert_utf16le_to_utf32_with_errors(i.utf16.ptr, i.utf16.len, &out32).count;
            }
        }.f },
        .{ "simdutf-valid", struct {
            fn f(i: *const Input) usize {
                return simdutf_convert_valid_utf16le_to_utf32(i.utf16.ptr, i.utf16.len, &out32);
            }
        }.f },
    } },
    .{ .name = "Utf32ToUtf16le", .src = .utf32, .arms = &.{
        .{ "utf", struct {
            fn f(i: *const Input) usize {
                return r(cv.utf32ToUtf16le(i.utf32, &out16));
            }
        }.f },
        .{ "scalar", struct {
            fn f(i: *const Input) usize {
                return r(sc.utf32ToUtf16(.little, i.utf32, &out16));
            }
        }.f },
        .{ "simdutf", struct {
            fn f(i: *const Input) usize {
                return simdutf_convert_utf32_to_utf16le(i.utf32.ptr, i.utf32.len, &out16);
            }
        }.f },
    } },
    .{ .name = "Utf8ToLatin1", .src = .latin1, .arms = &.{
        .{ "utf", struct {
            fn f(i: *const Input) usize {
                return r(cv.utf8ToLatin1(i.utf8, &out8));
            }
        }.f },
        .{ "utf-valid", struct {
            fn f(i: *const Input) usize {
                return cv.validUtf8ToLatin1(i.utf8, &out8);
            }
        }.f },
        .{ "scalar", struct {
            fn f(i: *const Input) usize {
                return r(sc.utf8ToLatin1(i.utf8, &out8));
            }
        }.f },
        .{ "simdutf", struct {
            fn f(i: *const Input) usize {
                return simdutf_convert_utf8_to_latin1_with_errors(i.utf8.ptr, i.utf8.len, &out8).count;
            }
        }.f },
        .{ "simdutf-valid", struct {
            fn f(i: *const Input) usize {
                return simdutf_convert_valid_utf8_to_latin1(i.utf8.ptr, i.utf8.len, &out8);
            }
        }.f },
    } },
    .{ .name = "Latin1ToUtf8", .src = .latin1, .arms = &.{
        .{ "utf", struct {
            fn f(i: *const Input) usize {
                return r(cv.latin1ToUtf8(i.latin1, &out8));
            }
        }.f },
        .{ "scalar", struct {
            fn f(i: *const Input) usize {
                return r(sc.latin1ToUtf8(i.latin1, &out8));
            }
        }.f },
        .{ "simdutf", struct {
            fn f(i: *const Input) usize {
                return simdutf_convert_latin1_to_utf8(i.latin1.ptr, i.latin1.len, &out8);
            }
        }.f },
    } },
    .{ .name = "Utf16LengthFromUtf8", .src = .utf8, .arms = &.{
        .{ "utf", struct {
            fn f(i: *const Input) usize {
                return ln.utf16FromUtf8(i.utf8);
            }
        }.f },
        .{ "scalar", struct {
            fn f(i: *const Input) usize {
                return sc.utf16FromUtf8(i.utf8);
            }
        }.f },
        .{ "std", struct {
            fn f(i: *const Input) usize {
                return std.unicode.calcUtf16LeLen(i.utf8) catch unreachable;
            }
        }.f },
        .{ "simdutf", struct {
            fn f(i: *const Input) usize {
                return simdutf_utf16_length_from_utf8(i.utf8.ptr, i.utf8.len);
            }
        }.f },
    } },
    .{ .name = "Utf8LengthFromUtf16le", .src = .utf16, .arms = &.{
        .{ "utf", struct {
            fn f(i: *const Input) usize {
                return ln.utf8FromUtf16le(i.utf16);
            }
        }.f },
        .{ "scalar", struct {
            fn f(i: *const Input) usize {
                return sc.utf8FromUtf16(.little, i.utf16);
            }
        }.f },
        .{ "simdutf", struct {
            fn f(i: *const Input) usize {
                return simdutf_utf8_length_from_utf16le(i.utf16.ptr, i.utf16.len);
            }
        }.f },
    } },
    .{ .name = "CountUtf8", .src = .utf8, .arms = &.{
        .{ "utf", struct {
            fn f(i: *const Input) usize {
                return ln.countUtf8(i.utf8);
            }
        }.f },
        .{ "scalar", struct {
            fn f(i: *const Input) usize {
                return sc.countUtf8(i.utf8);
            }
        }.f },
        .{ "std", struct {
            fn f(i: *const Input) usize {
                return std.unicode.utf8CountCodepoints(i.utf8) catch unreachable;
            }
        }.f },
        .{ "simdutf", struct {
            fn f(i: *const Input) usize {
                return simdutf_count_utf8(i.utf8.ptr, i.utf8.len);
            }
        }.f },
    } },
};

const corpora = [_]struct { []const u8, []const u8 }{
    .{ "ascii", @embedFile("corpus/Latin-Lipsum.utf8.txt") },
    .{ "latin", @embedFile("corpus/french.utf8.txt") },
    .{ "cyrillic", @embedFile("corpus/russian.utf8.txt") },
    .{ "cjk", @embedFile("corpus/Chinese-Lipsum.utf8.txt") },
    .{ "emoji", @embedFile("corpus/Emoji-Lipsum.utf8.txt") },
};
const sizes = [_]usize{ 16, 64, 256, 1024, 4096, 65536, 1 << 20 };

fn now() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

var text_buf: [1 << 20]u8 = undefined;
var latin_utf8_buf: [1 << 20]u8 = undefined;
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
    // Drop a cut-off final character.
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

pub fn main() void {
    var filter: []const u8 = "";
    if (std.c.getenv("BENCH_FILTER")) |f| filter = std.mem.span(f);
    const samples: usize = 7;
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
    for (ops) |op| for (corpora) |corpus| for (sizes) |size| {
        const name, const raw = corpus;
        if (op.src == .latin1 and !(std.mem.eql(u8, name, "ascii") or std.mem.eql(u8, name, "latin"))) continue;
        const base = if (op.src == .latin1 and std.mem.eql(u8, name, "latin")) filtered_buf[0..flen] else raw;
        const u8s = fill(&text_buf, base, size);
        const n16 = cv.validUtf8ToUtf16le(u8s, &utf16_buf);
        const n32 = cv.validUtf8ToUtf32(u8s, &utf32_buf);
        const nl1 = if (op.src == .latin1) cv.validUtf8ToLatin1(u8s, &latin1_buf) else 0;
        const input: Input = .{ .utf8 = u8s, .utf16 = utf16_buf[0..n16], .utf32 = utf32_buf[0..n32], .latin1 = latin1_buf[0..nl1] };
        const in_bytes: usize = switch (op.src) {
            .utf8 => u8s.len,
            .utf16 => 2 * n16,
            .utf32 => 4 * n32,
            .latin1 => if (std.mem.startsWith(u8, op.name, "Latin1")) nl1 else u8s.len,
        };
        var label_buf: [128]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "{s}/corpus={s}/size={d}", .{ op.name, name, size }) catch unreachable;
        if (filter.len > 0 and std.mem.indexOf(u8, label, filter) == null) continue;
        // Calibrate each arm, and check they agree.
        var iters: [8]usize = undefined;
        var want: ?usize = null;
        for (op.arms, 0..) |arm, a| {
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
