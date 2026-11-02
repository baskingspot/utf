const std = @import("std");
const utf = @import("utf");

test "size the output, then convert" {
    const source = "Héllo, 世界";
    const units = utf.length.utf16FromUtf8(source);

    var buffer: [64]u16 = undefined;
    try std.testing.expect(units <= buffer.len);

    const result = utf.convert.utf8ToUtf16le(source, buffer[0..units]);
    try std.testing.expectEqual(utf.Error.none, result.err);
    try std.testing.expectEqual(units, result.count);
    try std.testing.expectEqual(@as(u16, 'H'), buffer[0]);
}

test "a checked conversion names the character that failed, and what it wrote before it" {
    var buffer: [8]u8 = undefined;
    const units = [_]u16{ 'A', 0xE9, 0xD800, 'B' };

    const result = utf.convert.utf16leToUtf8(&units, &buffer);
    try std.testing.expectEqual(utf.Error.surrogate, result.err);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqual(@as(usize, 3), result.written);
    try std.testing.expectEqualStrings("Aé", buffer[0..result.written]);
}

test "UTF-8 to Latin-1 rejects a code point above U+00FF" {
    var buffer: [8]u8 = undefined;
    const result = utf.convert.utf8ToLatin1("日本", &buffer);
    try std.testing.expectEqual(utf.Error.too_large, result.err);
    try std.testing.expectEqual(@as(usize, 0), result.count);
}

test "the valid form assumes well-formed input and a sized buffer" {
    const source = "plain ASCII";
    const units = utf.length.utf16FromUtf8(source);

    var buffer: [32]u16 = undefined;
    const written = utf.convert.validUtf8ToUtf16le(source, buffer[0..units]);
    try std.testing.expectEqual(units, written);
}
