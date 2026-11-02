//! Shims for the Zig 0.16 and 0.17 APIs, for the harness's Zig programs.

// zig fmt: off
pub fn enumToInt(e: anytype) @typeInfo(@TypeOf(e)).@"enum".tag_type {
    return @intFromEnum(e);
}
pub fn enumFromInt(comptime E: type, raw: @typeInfo(E).@"enum".tag_type) E {
    return @enumFromInt(raw);
}
// zig fmt: on

/// A function's parameter types: Zig 0.17 lists them as `param_types`,
/// Zig 0.16 as `params` with a type each.
pub fn paramTypes(comptime info: anytype) []const ?type {
    if (comptime @hasField(@TypeOf(info), "param_types")) return info.param_types;
    comptime var types: [info.params.len]?type = undefined;
    inline for (info.params, 0..) |p, i| types[i] = p.type;
    const out = types;
    return &out;
}
