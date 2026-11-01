//! Per-call cost of short calls: each function called out of line in a
//! loop, as the harness's arms do, timed with the TSC, the minimum and the
//! median over rounds of many calls. `calls [FILTER]`; prints
//! `name/len ticks ns`.
const std = @import("std");
const utf = @import("utf");

fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("lfence; rdtsc; lfence"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return @as(u64, hi) << 32 | lo;
}

var in_buf: [4096]u8 align(4096) = undefined;
var out_buf: [8192]u8 align(4096) = undefined;

noinline fn empty(in: []const u8) bool {
    asm volatile ("" ::: .{ .memory = true });
    return in.len != 0;
}

/// `bytes` as a slice of the code units `S` holds.
fn view(comptime S: type, bytes: anytype) S {
    const U = @typeInfo(S).pointer.child;
    const P = if (@typeInfo(S).pointer.attrs.@"const") [*]const U else [*]U;
    return @as(P, @ptrCast(@alignCast(bytes.ptr)))[0 .. bytes.len / @sizeOf(U)];
}

const Case = struct { name: []const u8, run: *const fn ([]const u8, []u8) usize };

fn c(comptime name: []const u8, comptime f: anytype) Case {
    const F = struct {
        fn run(in: []const u8, out: []u8) usize {
            const P = @typeInfo(@TypeOf(f)).@"fn".param_types;
            const r = switch (P.len) {
                1 => switch (P[0].?) {
                    []const u8 => f(in),
                    []const u16 => f(@as([*]const u16, @ptrCast(@alignCast(in.ptr)))[0 .. in.len / 2]),
                    []const u32 => f(@as([*]const u32, @ptrCast(@alignCast(in.ptr)))[0 .. in.len / 4]),
                    else => unreachable,
                },
                2 => f(view(P[0].?, in), view(P[1].?, out)),
                3 => if (P[0].? == []u8) f(out, in, .{}) else unreachable,
                else => unreachable,
            };
            return switch (@TypeOf(r)) {
                bool => @intFromBool(r),
                usize => r,
                utf.Result => if (r.err == .none) r.count else 0,
                else => unreachable,
            };
        }
    };
    return .{ .name = name, .run = F.run };
}

fn emptyRun(in: []const u8, out: []u8) usize {
    _ = out;
    return @intFromBool(empty(in));
}

const cases = [_]Case{
    .{ .name = "empty", .run = emptyRun },
    c("ascii", utf.validate.ascii),
    c("asciiWithErrors", utf.validate.asciiWithErrors),
    c("utf8", utf.validate.utf8),
    c("utf8WithErrors", utf.validate.utf8WithErrors),
    c("utf16le", utf.validate.utf16le),
    c("utf16leWithErrors", utf.validate.utf16leWithErrors),
    c("utf32", utf.validate.utf32),
    c("utf32WithErrors", utf.validate.utf32WithErrors),
    c("countUtf8", utf.length.countUtf8),
    c("countUtf16le", utf.length.countUtf16le),
    c("utf8FromLatin1", utf.length.utf8FromLatin1),
    c("utf16FromUtf32", utf.length.utf16FromUtf32),
    c("latin1ToUtf16le", utf.convert.latin1ToUtf16le),
    c("utf16leToLatin1", utf.convert.utf16leToLatin1),
    c("utf32ToUtf16le", utf.convert.utf32ToUtf16le),
    c("latin1ToUtf8", utf.convert.latin1ToUtf8),
    c("utf8ToLatin1", utf.convert.utf8ToLatin1),
    c("validUtf16leToUtf16be", utf.convert.validUtf16leToUtf16be),
    c("utf16leToUtf32", utf.convert.utf16leToUtf32),
    c("utf32ToLatin1", utf.convert.utf32ToLatin1),
    c("latin1ToUtf32", utf.convert.latin1ToUtf32),
    c("b64encode", utf.base64.encode),
    c("b64decode", utf.base64.decode),
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const filter: []const u8 = if (args.len > 1) args[1] else "";
    // Lengths in bytes from the second argument, comma-separated.
    var lens_buf: [16]usize = undefined;
    var lens: []usize = lens_buf[0..0];
    if (args.len > 2) {
        var it = std.mem.tokenizeScalar(u8, args[2], ',');
        while (it.next()) |t| {
            lens_buf[lens.len] = try std.fmt.parseInt(usize, t, 10);
            lens = lens_buf[0 .. lens.len + 1];
        }
    } else {
        lens_buf[0..3].* = .{ 0, 16, 64 };
        lens = lens_buf[0..3];
    }
    // ASCII letters: valid in every format, and base64.
    for (&in_buf, 0..) |*x, i| x.* = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"[i % 64];
    @memset(&out_buf, 0);
    const iters = 2_000_000;
    const rounds = 15;
    var buf: [256]u8 = undefined;
    inline for (cases) |cs| {
        if (std.mem.indexOf(u8, cs.name, filter) != null) {
            for (lens) |len| {
                var t: [rounds]u64 = undefined;
                const in: []const u8 = in_buf[0..len];
                const out: []u8 = out_buf[2048..];
                for (&t) |*x| {
                    const start = rdtsc();
                    for (0..iters) |_| {
                        std.mem.doNotOptimizeAway(in.ptr);
                        std.mem.doNotOptimizeAway(@call(.never_inline, cs.run, .{ in, out }));
                    }
                    x.* = rdtsc() - start;
                }
                std.mem.sort(u64, &t, {}, std.sort.asc(u64));
                const min = @as(f64, @floatFromInt(t[0])) / iters;
                const med = @as(f64, @floatFromInt(t[rounds / 2])) / iters;
                const line = try std.fmt.bufPrint(&buf, "{s}/{d}\t{d:.2}\t{d:.2}\t{d:.3}\n", .{ cs.name, len, min, med, med / 2.6 });
                std.debug.print("{s}", .{line});
            }
        }
    }
}
