//! Validation throughput of the package tree it is built from, on the
//! inputs in inputs.zig.
const std = @import("std");
const testingx = @import("testingx");
const utf = @import("utf");
const in = @import("inputs.zig");
const B = testingx.B;

const Input = struct { name: []const u8, data: []const u8 };
var table: [in.ops.len][]Input = undefined;
var current: []const u8 = undefined;

pub fn benchmarkMain(b: *B) !void {
    const a = std.heap.page_allocator;
    inline for (in.ops, 0..) |op, oi| {
        var list: std.ArrayList(Input) = .empty;
        inline for (in.texts) |t| {
            if (in.applies(op.kind, t[0])) for (in.sizes) |size| {
                const data = try in.make(a, op.kind, t[1], size, op.form == .err);
                const name = try std.fmt.allocPrint(a, "text={s}/size={d}", .{ t[0], size });
                try list.append(a, .{ .name = name, .data = data });
            };
        }
        table[oi] = list.items;
        try b.add(comptime in.rowName(op), Row(oi).run);
    }
}

fn Row(comptime oi: usize) type {
    const op = in.ops[oi];
    return struct {
        fn run(b: *B) !void {
            for (table[oi]) |x| {
                current = x.data;
                _ = try b.run(x.name, row);
            }
        }
        fn row(b: *B) !void {
            const data = current;
            // testingx's loop() is a call, about 2.8 ns here, which would
            // swamp a short input; 16 calls per iteration amortize it.
            const reps = 16;
            b.setBytes(@intCast(data.len * reps));
            var ok: usize = 0;
            defer b.keepAlive(ok);
            while (try b.loop()) {
                for (0..reps) |_| {
                    var p: []const u8 = data;
                    std.mem.doNotOptimizeAway(&p);
                    ok += @intFromBool(call(p));
                }
            }
            if ((ok == 0) != (op.form == .err)) return b.fail();
        }
        /// Each call is a real call, as from a caller that does not
        /// inline the package, so inlining into this loop does not decide
        /// an A/B.
        inline fn call(p: []const u8) bool {
            const v = utf.validate;
            const u16s: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, p));
            const u32s: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, p));
            const ni: std.builtin.CallModifier = .never_inline;
            return switch (op.form) {
                .plain => switch (op.kind) {
                    .utf8 => @call(ni, v.utf8, .{p}),
                    .ascii => @call(ni, v.ascii, .{p}),
                    .utf16le => @call(ni, v.utf16le, .{u16s}),
                    .utf16be => @call(ni, v.utf16be, .{u16s}),
                    .utf32 => @call(ni, v.utf32, .{u32s}),
                },
                .with_errors, .err => (switch (op.kind) {
                    .utf8 => @call(ni, v.utf8WithErrors, .{p}),
                    .ascii => @call(ni, v.asciiWithErrors, .{p}),
                    .utf16le => @call(ni, v.utf16leWithErrors, .{u16s}),
                    .utf16be => @call(ni, v.utf16beWithErrors, .{u16s}),
                    .utf32 => @call(ni, v.utf32WithErrors, .{u32s}),
                }).err == .none,
            };
        }
    };
}
