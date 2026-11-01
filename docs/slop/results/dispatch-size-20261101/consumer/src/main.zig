//! The four calls Ghostty makes, from an executable.
const std = @import("std");
const utf = @import("utf");

pub fn main(init: std.process.Init) !void {
    var it = init.minimal.args.iterate();
    _ = it.skip();
    const arg: []const u8 = it.next() orelse "aGVsbG8gd29ybGQ=";
    var out: [256]u8 = undefined;
    const d = utf.base64.decode(out[0..@min(out.len, utf.base64.maxDecodedLen(arg.len))], arg, .{});
    var u: [256]u32 = undefined;
    const c = utf.convert.utf8ToUtf32(out[0..d.count], &u);
    const n = utf.length.countUtf8(out[0..d.count]);
    std.process.exit(@truncate(c.count +% n));
}
