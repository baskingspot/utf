//! bench-utf's timed loop around an out-of-line call that returns at once.
const std = @import("std");
const testingx = @import("testingx");

const Out = struct { n: usize, kind: enum(u8) { valid, len, count } };

fn noop(in: []align(4) const u8, out: []align(4) u8) Out {
    _ = out;
    asm volatile ("" ::: .{ .memory = true });
    return .{ .n = in.len, .kind = .count };
}

var current: []align(4) const u8 = undefined;
var current_out: []align(4) u8 = undefined;

fn row(b: *testingx.B) !void {
    const in = current;
    const out = current_out;
    while (try b.loop()) {
        std.mem.doNotOptimizeAway(in.ptr);
        std.mem.doNotOptimizeAway(@call(.never_inline, noop, .{ in, out }).n);
    }
    b.setBytes(@intCast(in.len));
}

/// The same with Go's classic loop over `b.n`.
fn rowN(b: *testingx.B) !void {
    const in = current;
    const out = current_out;
    for (0..b.n) |_| {
        std.mem.doNotOptimizeAway(in.ptr);
        std.mem.doNotOptimizeAway(@call(.never_inline, noop, .{ in, out }).n);
    }
    b.setBytes(@intCast(in.len));
}

pub fn main(init: std.process.Init) !void {
    var buf: [64]u8 align(4) = undefined;
    current = buf[0..16];
    current_out = buf[16..32];
    for (0..5) |_| {
        inline for (.{ row, rowN }, .{ "b.loop()", "b.n" }) |f, name| {
            var r = try testingx.benchmark(std.heap.smp_allocator, init.io, f, .{ .benchtime = .{ .count = 50_000_000 } });
            defer r.deinit(std.heap.smp_allocator);
            std.debug.print("zig {s} {d:.3} ns/op\n", .{ name, @as(f64, @floatFromInt(r.t_ns)) / @as(f64, @floatFromInt(r.n)) });
        }
    }
}
