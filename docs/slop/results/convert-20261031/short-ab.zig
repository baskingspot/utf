const std = @import("std");
const utf = @import("utf");
const old = @import("old");
const names = .{ "latin1ToUtf8", "validLatin1ToUtf8", "utf8ToLatin1", "utf8ToUtf16le", "validUtf8ToUtf16le", "utf8ToUtf32", "utf16leToUtf8", "utf16leToUtf32", "utf32ToUtf16le", "utf32ToUtf8" };
pub fn main() !void {
    const out_page = try std.heap.page_allocator.alloc(u8, 1 << 20);
    const in_page = try std.heap.page_allocator.alloc(u8, 1 << 20);
    @memset(out_page, 0);
    const lens = [_]usize{ 8, 16, 24, 40, 64, 100, 256, 1000 };
    inline for (names) |name| {
        const P = @typeInfo(@TypeOf(@field(utf.convert, name))).@"fn".params;
        const S = @typeInfo(P[0].type.?).pointer.child;
        const D = @typeInfo(P[1].type.?).pointer.child;
        const all: []S = @alignCast(std.mem.bytesAsSlice(S, in_page[16..][0 .. 4096 * @sizeOf(S)]));
        const uni = std.c.getenv("UNI") != null;
        for (all, 0..) |*u, i| u.* = if (S == u8) (if (uni and i % 2 == 0) 0xC3 else if (uni) 0xA9 else 'a') else if (uni) 0xE9 else 'a';
        std.debug.print("{s:20}", .{name});
        for (lens) |n| {
            var src: []const S = all[0..n];
            if (S == u8 and uni and n % 2 == 1) src = all[0 .. n - 1];
            const dst: []D = @alignCast(std.mem.bytesAsSlice(D, out_page[0 .. 4 * (n + 64) * @sizeOf(D)]));
            var best = [2]f64{ 1e18, 1e18 };
            for (0..7) |_| inline for (0..2) |arm| {
                const t0 = now();
                const iters = 100000;
                for (0..iters) |_| {
                    std.mem.doNotOptimizeAway(src.ptr);
                    const r = if (arm == 0) @call(.never_inline, @field(utf.convert, name), .{ src, dst }) else @call(.never_inline, @field(old.convert, name), .{ src, dst });
                    if (@TypeOf(r) == usize) std.mem.doNotOptimizeAway(r) else std.mem.doNotOptimizeAway(r.count);
                }
                best[arm] = @min(best[arm], @as(f64, @floatFromInt(now() - t0)) / iters);
            };
            std.debug.print(" {d}:{d:.1}/{d:.1}", .{ n, best[0], best[1] });
        }
        std.debug.print("\n", .{});
    }
}
fn now() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
