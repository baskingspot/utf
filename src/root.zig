//! SIMD UTF-8, UTF-16, and UTF-32 validation and transcoding, and base64,
//! in Zig, with no C.

const std = @import("std");
const result = @import("result.zig");

pub const Error = result.Error;
pub const Result = result.Result;
pub const scalar = @import("scalar.zig");
pub const scalar_convert = @import("scalar_convert.zig");
pub const convert = @import("convert.zig");
pub const length = @import("length.zig");
pub const base64 = @import("base64.zig");
pub const validate = @import("validate.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("simd.zig");
    _ = @import("dispatch.zig");
}
