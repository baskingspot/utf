// A model of bench/zig/arm.zig's `written()`: the checked call out of line or
// inlined, its `Result` turned into the harness's `Out` union by choosing a
// variant or by building one variant from scalars. Built like tail-ab.zig.
const std = @import("std");
const utf = @import("utf");
const Out = union(enum) { valid: bool, count: usize, len: usize };
fn written(r: utf.Result) Out {
    return if (r.err == .none) .{ .len = r.count * 2 } else .{ .valid = false };
}
fn writtenOne(r: utf.Result) Out {
    if (r.err != .none) return .{ .valid = false };
    return .{ .len = r.count * 2 };
}
noinline fn runA(in: []const u8, out: []u16) Out {
    return written(utf.convert.latin1ToUtf16le(in, out));
}
noinline fn runB(in: []const u8, out: []u16) Out {
    return writtenOne(utf.convert.latin1ToUtf16le(in, out));
}
noinline fn runC(in: []const u8, out: []u16) Out {
    return written(@call(.never_inline, utf.convert.latin1ToUtf16le, .{ in, out }));
}
noinline fn runD(in: []const u8, out: []u16) Out {
    const r = @call(.never_inline, utf.convert.latin1ToUtf16le, .{ in, out });
    return .{ .len = (if (r.err == .none) r.count else 0) * 2 };
}
noinline fn runV(in: []const u8, out: []u16) Out {
    return .{ .len = utf.convert.validLatin1ToUtf16le(in, out) * 2 };
}
pub fn main() !void {
    const out = try std.heap.page_allocator.alloc(u8, 8192);
    const inp = try std.heap.page_allocator.alloc(u8, 8192);
    @memset(out, 0);
    @memset(inp, 'a');
    const dst: []u16 = @alignCast(std.mem.bytesAsSlice(u16, out[0..256]));
    inline for (.{ runA, runB, runC, runD, runV }, .{ "ternary", "early-return", "ternary-outofline", "one-variant-outofline", "valid" }) |f, name| {
        var best: f64 = 1e9;
        var len: usize = 16;
        std.mem.doNotOptimizeAway(&len);
        for (0..7) |_| {
            const t0 = now();
            for (0..1_000_000) |_| {
                std.mem.doNotOptimizeAway(inp.ptr);
                std.mem.doNotOptimizeAway(switch (@call(.never_inline, f, .{ inp[0..len], dst })) {
                    .valid => |v| @intFromBool(v),
                    .count, .len => |n| n,
                });
            }
            best = @min(best, @as(f64, @floatFromInt(now() - t0)) / 1e6);
        }
        std.debug.print("{s}: {d:.2} ns\n", .{ name, best });
    }
}
fn now() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
