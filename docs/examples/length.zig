const std = @import("std");
const utf = @import("utf");

test "count code points" {
    try std.testing.expectEqual(@as(usize, 3), utf.length.countUtf8("aé日"));
    try std.testing.expectEqual(
        @as(usize, 3),
        utf.length.countUtf16le(&[_]u16{ 0x61, 0xD83D, 0xDE00, 0x7A }),
    );
}

test "size every conversion" {
    try std.testing.expectEqual(@as(usize, 4), utf.length.utf16FromUtf8("a😀z"));

    const units = [_]u16{ 0x61, 0xD83D, 0xDE00, 0x7A };
    try std.testing.expectEqual(@as(usize, 6), utf.length.utf8FromUtf16le(&units));
}
