//! Shims for the Zig 0.16 and 0.17 APIs. Private to the module.

// Zig 0.17's `zig fmt` rewrites these to their `@backingInt` forms, which
// Zig 0.16 cannot compile. Keep them out of the formatter's reach.
// zig fmt: off
pub fn enumToInt(e: anytype) @typeInfo(@TypeOf(e)).@"enum".tag_type {
    return @intFromEnum(e);
}
pub fn enumFromInt(comptime E: type, raw: anytype) E {
    return @enumFromInt(raw);
}
// zig fmt: on

/// Zig 0.17 removed the `**` array-repeat operator.
pub fn repeat(comptime T: type, value: T, comptime n: usize) [n]T {
    return @splat(value);
}

pub fn repeatSlice(comptime s: []const u8, comptime n: usize) [s.len * n]u8 {
    var out: [s.len * n]u8 = undefined;
    for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    return out;
}

// Zig 0.17 split a container's `fields` into parallel arrays.
pub fn fieldCount(comptime info: anytype) usize {
    if (comptime @hasField(@TypeOf(info), "field_names")) return info.field_names.len;
    return info.fields.len;
}

pub fn fieldName(comptime info: anytype, comptime i: usize) [:0]const u8 {
    if (comptime @hasField(@TypeOf(info), "field_names")) return info.field_names[i];
    return info.fields[i].name;
}

pub fn FieldType(comptime info: anytype, comptime i: usize) type {
    if (comptime @hasField(@TypeOf(info), "field_names")) return info.field_types[i];
    return info.fields[i].type;
}
