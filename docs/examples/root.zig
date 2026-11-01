//! Every example the guide shows. `zig build test` compiles and runs these
//! against the public module, so a guide page cannot show code that does not
//! build.

const std = @import("std");

pub const validate = @import("validate.zig");
pub const convert = @import("convert.zig");
pub const length = @import("length.zig");
pub const base64 = @import("base64.zig");

test {
    std.testing.refAllDecls(@This());
}
