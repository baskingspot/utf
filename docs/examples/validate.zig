const std = @import("std");
const utf = @import("utf");

test "a validator answers yes or no" {
    try std.testing.expect(utf.validate.utf8("Héllo, 世界"));
    try std.testing.expect(!utf.validate.utf8("a\xFFb"));
}

test "the checked form says what failed, and where" {
    const result = utf.validate.utf8WithErrors("a\xFFb");
    try std.testing.expectEqual(utf.Error.header_bits, result.err);
    try std.testing.expectEqual(@as(usize, 1), result.count);
}

test "UTF-16 names the byte order in memory" {
    // 0x00D8 is U+00D8 in little-endian bytes, and D800, an unpaired high
    // surrogate, when the same bytes are read big-endian.
    const units = [_]u16{ 0x00D8, 0x00E9 };
    try std.testing.expect(utf.validate.utf16le(&units));
    try std.testing.expect(!utf.validate.utf16be(&units));
}

test "ASCII is its own check" {
    try std.testing.expect(utf.validate.ascii("plain text"));
    const result = utf.validate.asciiWithErrors("plain\xC3\xA9");
    try std.testing.expectEqual(utf.Error.not_ascii, result.err);
    try std.testing.expectEqual(@as(usize, 5), result.count);
}
