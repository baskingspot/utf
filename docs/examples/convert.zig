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

test "UTF-8 to UTF-32 replaces each maximal subpart with U+FFFD" {
    const source = "a\xF1\x80\x80\xE1\x80\xC2b";
    var buffer: [source.len]u32 = undefined;

    const written = utf.convert.utf8ToUtf32Replacing(source, &buffer);
    try std.testing.expectEqualSlices(u32, &.{ 'a', 0xFFFD, 0xFFFD, 0xFFFD, 'b' }, buffer[0..written]);
}

test "the valid form assumes well-formed input and a sized buffer" {
    const source = "plain ASCII";
    const units = utf.length.utf16FromUtf8(source);

    var buffer: [32]u16 = undefined;
    const written = utf.convert.validUtf8ToUtf16le(source, buffer[0..units]);
    try std.testing.expectEqual(units, written);
}

test "UTF-16 of the BMP alone converts both ways, and from UTF-8 stops at a four-byte character" {
    // Code points below U+10000, no surrogates, in the machine's byte order.
    const units = [_]u16{ 'A', 0xE9, 0x0E01, 'B' };
    var bytes: [16]u8 = undefined;
    const to = utf.convert.bmpToUtf8(&units, &bytes);
    try std.testing.expectEqual(utf.BmpResult{ .read = 4, .written = 7 }, to);
    try std.testing.expectEqualStrings("AéกB", bytes[0..to.written]);

    var back: [8]u16 = undefined;
    const from = utf.convert.utf8ToBmp("Aé😀B", &back);
    try std.testing.expectEqual(utf.BmpResult{ .read = 3, .written = 2 }, from);
    try std.testing.expectEqualSlices(u16, &.{ 'A', 0xE9 }, back[0..from.written]);
}
