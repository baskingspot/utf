//! Writes bench.zig's inputs for the C++ simdutf driver: `dir/manifest`, one
//! line per row, `<row>\t<function>\t<file>`.
const std = @import("std");
const in = @import("inputs.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    const dir_path = "/home/user/vb/in";
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir_path);
    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);
    var manifest: std.ArrayList(u8) = .empty;
    inline for (in.ops) |op| {
        inline for (in.texts) |t| {
            if (in.applies(op.kind, t[0])) for (in.sizes) |size| {
                const data = try in.make(a, op.kind, t[1], size, op.form == .err);
                const file = try std.fmt.allocPrint(a, "{s}-{s}-{d}", .{ comptime in.rowName(op), t[0], size });
                try dir.writeFile(io, .{ .sub_path = file, .data = data });
                const func = @tagName(op.kind) ++ if (op.form == .plain) "" else "_with_errors";
                try manifest.print(a, "Benchmark{s}/text={s}/size={d}\t{s}\t{s}/{s}\n", .{ comptime in.rowName(op), t[0], size, func, dir_path, file });
            };
        }
    }
    try dir.writeFile(io, .{ .sub_path = "manifest", .data = manifest.items });
}
