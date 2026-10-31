const std = @import("std");
extern fn @"llvm.masked.load.v64i8.p0"(*const anyopaque, u32, @Vector(64, bool), @Vector(64, u8)) @Vector(64, u8);
fn bench(p: [*]const u8, len: usize) u64 {
    const mask: @Vector(64, bool) = @bitCast((@as(u64, 1) << @intCast(len)) - 1);
    var acc: @Vector(64, u8) = @splat(0);
    const t0 = rdtsc();
    const n = 1_000_000;
    for (0..n) |_| {
        var q = p;
        std.mem.doNotOptimizeAway(&q);
        acc +%= @"llvm.masked.load.v64i8.p0"(q, 1, mask, @splat(0));
    }
    std.mem.doNotOptimizeAway(&acc);
    return (rdtsc() - t0) / (n / 1000);
}
pub fn main() !void {
    const linux = std.os.linux;
    const page = 4096;
    const mem = linux.mmap(null, 3 * page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    const base: [*]u8 = @ptrFromInt(mem);
    base[0] = 1; // touch page 0 only
    _ = linux.mprotect(base + 2 * page, page, .{});
    std.debug.print("within page:        {d} cycles*1000/load (TSC)\n", .{bench(base + 100, 16)});
    std.debug.print("rest on untouched:  {d} cycles*1000/load (TSC)\n", .{bench(base + page - 16, 16)});
    base[page] = 1; // touch page 1
    std.debug.print("rest on touched:    {d} cycles*1000/load (TSC)\n", .{bench(base + page - 16, 16)});
    std.debug.print("rest on PROT_NONE:  {d} cycles*1000/load (TSC)\n", .{bench(base + 2 * page - 16, 16)});
}

fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return @as(u64, hi) << 32 | lo;
}
