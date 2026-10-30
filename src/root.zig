//! SIMD UTF-8, UTF-16, and UTF-32 validation and transcoding, and base64,
//! in Zig, with no C.

const std = @import("std");
const result = @import("result.zig");

pub const Error = result.Error;
pub const Result = result.Result;
pub const scalar = @import("scalar.zig");
pub const base64 = @import("base64.zig");

test {
    std.testing.refAllDecls(@This());
}
