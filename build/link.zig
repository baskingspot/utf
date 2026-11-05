//! A program that calls one dispatched function, for `zig build link`. A
//! dispatching build links every tier object whole, every kernel's
//! references included, until the linker drops the unreached ones, and an
//! unoptimized build drops none: this checks that those references resolve
//! in a program that calls few of the kernels, on each object format.
const std = @import("std");
const utf = @import("utf");

pub fn main() void {
    var text = "h\xc3\xa9llo".*;
    std.mem.doNotOptimizeAway(&text);
    std.mem.doNotOptimizeAway(utf.validate.utf8(&text));
}
