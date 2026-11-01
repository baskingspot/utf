//! Shims for the Zig 0.16 and 0.17 APIs. Private to the oracle.

// zig fmt: off
pub fn enumToInt(e: anytype) @typeInfo(@TypeOf(e)).@"enum".tag_type {
    return @intFromEnum(e);
}
pub fn enumFromInt(comptime E: type, raw: anytype) E {
    return @enumFromInt(raw);
}
// zig fmt: on
