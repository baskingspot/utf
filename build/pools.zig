//! `utf-pools IN OUT`: copies the assembly of a tier object (build.zig's
//! `addDispatch`) from IN to OUT, with each function's constant pool in a
//! section of its own. LLVM puts the pool entries that fit no mergeable
//! section, 64-byte AVX-512 vectors and single bytes, into one `.rodata`
//! section for the whole object, whatever `-fdata-sections` says, so a
//! program that calls one kernel linked every kernel's constants. Each pool
//! is used by the function after it alone, so its own section is collected
//! with that function.
const std = @import("std");

const plain = "\t.section\t.rodata,\"a\",@progbits\n";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 3) return error.Usage;
    const cwd = std.Io.Dir.cwd();
    const in = try cwd.readFileAlloc(io, args[1], gpa, .unlimited);
    var out: std.ArrayList(u8) = .empty;
    var rest = in;
    var n: usize = 0;
    while (std.mem.find(u8, rest, plain)) |i| : (n += 1) {
        try out.appendSlice(gpa, rest[0..i]);
        try out.print(gpa, "\t.section\t.rodata.utf_pool{d},\"a\",@progbits\n", .{n});
        rest = rest[i + plain.len ..];
    }
    try out.appendSlice(gpa, rest);
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out.items });
}
