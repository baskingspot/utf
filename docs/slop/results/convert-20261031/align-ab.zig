const std = @import("std");
const utf = @import("utf");
const old = @import("old");
const names = .{ "utf32ToLatin1", "validUtf32ToLatin1", "utf16leToLatin1", "validUtf16leToLatin1", "latin1ToUtf16le", "validLatin1ToUtf16le", "latin1ToUtf32", "utf16leToUtf16be", "validUtf16leToUtf16be" };
pub fn main() !void {
    const out_page = try std.heap.page_allocator.alloc(u8, 4 << 20);
    const in_page = try std.heap.page_allocator.alloc(u8, 4 << 20);
    @memset(out_page, 0);
    @memset(in_page, 0x41);
    const n_env = std.c.getenv("N");
    const n: usize = if (n_env) |e| std.fmt.parseInt(usize, std.mem.span(e), 10) catch 65536 else 65536;
    inline for (names) |name| {
        const P = @typeInfo(@TypeOf(@field(utf.convert, name))).@"fn".params;
        const S = @typeInfo(P[0].type.?).pointer.child;
        const D = @typeInfo(P[1].type.?).pointer.child;
        var tot = [2]f64{ 0, 0 };
        for ([_]usize{ 0, 16, 32, 48 }) |soff| for ([_]usize{ 0, 16, 32, 48 }) |doff| {
            const src: []const S = @alignCast(std.mem.bytesAsSlice(S, in_page[soff..][0 .. n * @sizeOf(S)]));
            const dst: []D = @alignCast(std.mem.bytesAsSlice(D, out_page[doff..][0 .. (n + 64) * @sizeOf(D)]));
            var best = [2]f64{ 1e18, 1e18 };
            for (0..5) |_| inline for (0..2) |arm| {
                const t0 = now();
                const iters = 200;
                for (0..iters) |_| {
                    std.mem.doNotOptimizeAway(src.ptr);
                    const r = if (arm == 0) @field(utf.convert, name)(src, dst) else @field(old.convert, name)(src, dst);
                    std.mem.doNotOptimizeAway(r);
                }
                best[arm] = @min(best[arm], @as(f64, @floatFromInt(now() - t0)) / iters);
            };
            tot[0] += @log(best[0]);
            tot[1] += @log(best[1]);
        };
        std.debug.print("{s:24} n={d}: new {d:.0} ns, old {d:.0} ns, old/new {d:.2} (geomean of 16 offsets)\n", .{ name, n, @exp(tot[0] / 16), @exp(tot[1] / 16), @exp((tot[1] - tot[0]) / 16) });
    }
}
fn now() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
