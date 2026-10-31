//! Layout driver: one operation on a generated input of N code units, the
//! input at SRC_OFF bytes past a page and the output at DST_OFF bytes past
//! another, for utf (out of line) and simdutf (C API), interleaved. Prints
//! Go benchmark lines: Benchmark<op>/n=<n>/src=<off>/dst=<off>/arm=<arm>.
//! Env: OPS (comma list), N, SRC_OFFS, DST_OFFS (comma lists), SAMPLES, TEXT
//! (ascii or latin1: one byte in nine 0xE9).
const std = @import("std");
const utf = @import("utf");

const Res = extern struct { err: c_int, count: usize };
extern fn @"_ZN7simdutf29convert_valid_utf32_to_latin1EPKDimPc"([*]const u32, usize, [*]u8) usize;
extern fn simdutf_convert_utf32_to_latin1_with_errors([*]const u32, usize, [*]u8) Res;
extern fn simdutf_convert_valid_utf16le_to_latin1([*]const u16, usize, [*]u8) usize;
extern fn simdutf_convert_utf16le_to_latin1_with_errors([*]const u16, usize, [*]u8) Res;
extern fn simdutf_convert_valid_utf16le_to_utf8([*]const u16, usize, [*]u8) usize;
extern fn simdutf_convert_utf16le_to_utf8_with_errors([*]const u16, usize, [*]u8) Res;
extern fn simdutf_convert_valid_utf8_to_utf16le([*]const u8, usize, [*]u16) usize;
extern fn simdutf_convert_utf8_to_utf16le_with_errors([*]const u8, usize, [*]u16) Res;
extern fn simdutf_convert_valid_utf8_to_utf32([*]const u8, usize, [*]u32) usize;
extern fn simdutf_convert_utf8_to_latin1_with_errors([*]const u8, usize, [*]u8) Res;
extern fn simdutf_convert_valid_utf8_to_latin1([*]const u8, usize, [*]u8) usize;
extern fn simdutf_convert_latin1_to_utf16be([*]const u8, usize, [*]u16) usize;
extern fn simdutf_convert_latin1_to_utf32([*]const u8, usize, [*]u32) usize;
extern fn simdutf_convert_latin1_to_utf8([*]const u8, usize, [*]u8) usize;
extern fn simdutf_convert_latin1_to_utf16le([*]const u8, usize, [*]u16) usize;
extern fn simdutf_utf16_length_from_utf8([*]const u8, usize) usize;
extern fn simdutf_count_utf8([*]const u8, usize) usize;
extern fn @"_ZN7simdutf23change_endianness_utf16EPKDsmPDs"([*]const u16, usize, [*]u16) void;

const Src = enum { u8, u16, u32 };
fn ours(comptime f: anytype) *const fn ([*]const u8, usize, [*]u8) usize {
    return struct {
        fn run(s: [*]const u8, n: usize, d: [*]u8) usize {
            const P = @typeInfo(@TypeOf(f)).@"fn".params;
            const S = std.meta.Child(P[0].type.?);
            const src: [*]const S = @ptrCast(@alignCast(s));
            if (P.len == 1) return @call(.never_inline, f, .{src[0..n]});
            const D = std.meta.Child(P[1].type.?);
            const dst: [*]D = @ptrCast(@alignCast(d));
            const r = @call(.never_inline, f, .{ src[0..n], dst[0 .. 4 * n] });
            return if (@TypeOf(r) == usize) r else r.count;
        }
    }.run;
}
fn theirs(comptime f: anytype) *const fn ([*]const u8, usize, [*]u8) usize {
    return struct {
        fn run(s: [*]const u8, n: usize, d: [*]u8) usize {
            const P = @typeInfo(@TypeOf(f)).@"fn".params;
            const src: P[0].type.? = @ptrCast(@alignCast(s));
            if (P.len == 2) return f(src, n);
            const dst: P[2].type.? = @ptrCast(@alignCast(d));
            if (@typeInfo(@TypeOf(f)).@"fn".return_type.? == void) {
                f(src, n, dst);
                return n;
            }
            const r = f(src, n, dst);
            return if (@TypeOf(r) == usize) r else r.count;
        }
    }.run;
}
const Op = struct { name: []const u8, unit: usize, utf: *const fn ([*]const u8, usize, [*]u8) usize, simdutf: *const fn ([*]const u8, usize, [*]u8) usize };
const ops = [_]Op{
    .{ .name = "ValidUtf32ToLatin1", .unit = 4, .utf = ours(utf.convert.validUtf32ToLatin1), .simdutf = theirs(@"_ZN7simdutf29convert_valid_utf32_to_latin1EPKDimPc") },
    .{ .name = "Utf32ToLatin1", .unit = 4, .utf = ours(utf.convert.utf32ToLatin1), .simdutf = theirs(simdutf_convert_utf32_to_latin1_with_errors) },
    .{ .name = "ValidUtf16leToLatin1", .unit = 2, .utf = ours(utf.convert.validUtf16leToLatin1), .simdutf = theirs(simdutf_convert_valid_utf16le_to_latin1) },
    .{ .name = "Utf16leToLatin1", .unit = 2, .utf = ours(utf.convert.utf16leToLatin1), .simdutf = theirs(simdutf_convert_utf16le_to_latin1_with_errors) },
    .{ .name = "ValidUtf16leToUtf8", .unit = 2, .utf = ours(utf.convert.validUtf16leToUtf8), .simdutf = theirs(simdutf_convert_valid_utf16le_to_utf8) },
    .{ .name = "Utf16leToUtf8", .unit = 2, .utf = ours(utf.convert.utf16leToUtf8), .simdutf = theirs(simdutf_convert_utf16le_to_utf8_with_errors) },
    .{ .name = "ValidUtf8ToUtf16le", .unit = 1, .utf = ours(utf.convert.validUtf8ToUtf16le), .simdutf = theirs(simdutf_convert_valid_utf8_to_utf16le) },
    .{ .name = "Utf8ToUtf16le", .unit = 1, .utf = ours(utf.convert.utf8ToUtf16le), .simdutf = theirs(simdutf_convert_utf8_to_utf16le_with_errors) },
    .{ .name = "ValidUtf8ToUtf32", .unit = 1, .utf = ours(utf.convert.validUtf8ToUtf32), .simdutf = theirs(simdutf_convert_valid_utf8_to_utf32) },
    .{ .name = "Utf8ToLatin1", .unit = 1, .utf = ours(utf.convert.utf8ToLatin1), .simdutf = theirs(simdutf_convert_utf8_to_latin1_with_errors) },
    .{ .name = "ValidUtf8ToLatin1", .unit = 1, .utf = ours(utf.convert.validUtf8ToLatin1), .simdutf = theirs(simdutf_convert_valid_utf8_to_latin1) },
    .{ .name = "Latin1ToUtf16be", .unit = 1, .utf = ours(utf.convert.latin1ToUtf16be), .simdutf = theirs(simdutf_convert_latin1_to_utf16be) },
    .{ .name = "Latin1ToUtf32", .unit = 1, .utf = ours(utf.convert.latin1ToUtf32), .simdutf = theirs(simdutf_convert_latin1_to_utf32) },
    .{ .name = "ValidLatin1ToUtf8", .unit = 1, .utf = ours(utf.convert.validLatin1ToUtf8), .simdutf = theirs(simdutf_convert_latin1_to_utf8) },
    .{ .name = "Latin1ToUtf8", .unit = 1, .utf = ours(utf.convert.latin1ToUtf8), .simdutf = theirs(simdutf_convert_latin1_to_utf8) },
    .{ .name = "Latin1ToUtf16le", .unit = 1, .utf = ours(utf.convert.latin1ToUtf16le), .simdutf = theirs(simdutf_convert_latin1_to_utf16le) },
    .{ .name = "Utf16FromUtf8", .unit = 1, .utf = ours(utf.length.utf16FromUtf8), .simdutf = theirs(simdutf_utf16_length_from_utf8) },
    .{ .name = "CountUtf8", .unit = 1, .utf = ours(utf.length.countUtf8), .simdutf = theirs(simdutf_count_utf8) },
    .{ .name = "ValidUtf16leToUtf16be", .unit = 2, .utf = ours(utf.convert.validUtf16leToUtf16be), .simdutf = theirs(@"_ZN7simdutf23change_endianness_utf16EPKDsmPDs") },
};

fn now() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
fn env(name: [*:0]const u8, default: []const u8) []const u8 {
    return if (std.c.getenv(name)) |f| std.mem.span(f) else default;
}
fn list(s: []const u8, out: []usize) []usize {
    var it = std.mem.splitScalar(u8, s, ',');
    var k: usize = 0;
    while (it.next()) |x| : (k += 1) out[k] = std.fmt.parseInt(usize, x, 10) catch unreachable;
    return out[0..k];
}

pub fn main() void {
    const n = std.fmt.parseInt(usize, env("N", "65536"), 10) catch unreachable;
    var b1: [16]usize = undefined;
    var b2: [16]usize = undefined;
    const srcs = list(env("SRC_OFFS", "0"), &b1);
    const dsts = list(env("DST_OFFS", "0"), &b2);
    const samples = std.fmt.parseInt(usize, env("SAMPLES", "5"), 10) catch unreachable;
    const latin1 = std.mem.eql(u8, env("TEXT", "ascii"), "latin1");
    const page = 4096;
    const src_mem = std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(page), 4 * n + 2 * page) catch unreachable;
    const dst_mem = std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(page), 4 * 4 * n + 2 * page) catch unreachable;
    @memset(dst_mem, 0);
    var sink: usize = 0;
    var prng: std.Random.DefaultPrng = .init(1);
    const r = prng.random();
    var it = std.mem.splitScalar(u8, env("OPS", "ValidUtf32ToLatin1"), ',');
    while (it.next()) |want| for (ops) |op| {
        if (!std.mem.eql(u8, op.name, want)) continue;
        for (srcs) |so| for (dsts) |do| {
            const s = src_mem[so..];
            const d = dst_mem[do..];
            // Text: ASCII letters, or one in nine a Latin-1 letter (two
            // bytes in UTF-8, where N counts bytes).
            const utf8_src = std.mem.startsWith(u8, op.name, "Utf8To") or std.mem.startsWith(u8, op.name, "ValidUtf8To");
            var i: usize = 0;
            while (i < n) {
                var c: u32 = if (latin1 and r.uintLessThan(u8, 9) == 0) 0xE9 else 'a' + r.uintLessThan(u8, 26);
                if (utf8_src and c >= 0x80 and i + 1 == n) c = 'z';
                switch (op.unit) {
                    1 => if (utf8_src and c >= 0x80) {
                        s[i] = @intCast(0xC0 | c >> 6);
                        s[i + 1] = @intCast(0x80 | (c & 0x3F));
                        i += 1;
                    } else {
                        s[i] = @intCast(c);
                    },
                    2 => std.mem.writeInt(u16, s[2 * i ..][0..2], @intCast(c), .little),
                    else => std.mem.writeInt(u32, s[4 * i ..][0..4], c, .little),
                }
                i += 1;
            }
            const arms = [_]struct { []const u8, *const fn ([*]const u8, usize, [*]u8) usize }{ .{ env("ARM", "utf"), op.utf }, .{ "simdutf", op.simdutf } };
            var iters: [2]usize = undefined;
            for (arms, 0..) |arm, a| {
                var k: usize = 1;
                while (true) : (k *= 2) {
                    const t0 = now();
                    for (0..k) |_| sink +%= arm[1](s.ptr, n, d.ptr);
                    if (now() - t0 > 20 * std.time.ns_per_ms) break;
                }
                iters[a] = k;
            }
            for (0..samples) |_| for (arms, 0..) |arm, a| {
                const t0 = now();
                for (0..iters[a]) |_| {
                    std.mem.doNotOptimizeAway(s.ptr);
                    sink +%= arm[1](s.ptr, n, d.ptr);
                }
                const per = @as(f64, @floatFromInt(now() - t0)) / @as(f64, @floatFromInt(iters[a]));
                std.debug.print("Benchmark{s}/n={d}/src={d}/dst={d}/arm={s} {d} {d:.2} ns/op {d:.2} MB/s\n", .{ op.name, n, so, do, arm[0], iters[a], per, @as(f64, @floatFromInt(n * op.unit)) * 1000.0 / per });
            };
        };
    };
    std.mem.doNotOptimizeAway(sink);
}
