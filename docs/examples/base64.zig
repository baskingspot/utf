const std = @import("std");
const utf = @import("utf");

test "encode and decode with the standard alphabet" {
    var encoded: [16]u8 = undefined;
    const characters = utf.base64.encode(&encoded, "hello", .{});
    try std.testing.expectEqualStrings("aGVsbG8=", encoded[0..characters]);

    var decoded: [8]u8 = undefined;
    const result = utf.base64.decode(&decoded, "aGVsbG8=", .{});
    try std.testing.expectEqual(utf.Error.none, result.err);
    try std.testing.expectEqualStrings("hello", decoded[0..result.count]);
}

test "the URL alphabet, without padding" {
    var encoded: [16]u8 = undefined;
    const characters = utf.base64.encode(&encoded, "\xFB\xFF", .{
        .alphabet = .url,
        .padding = false,
    });
    try std.testing.expectEqualStrings("-_8", encoded[0..characters]);
}

test "decode skips whitespace, and the last-chunk rule is an option" {
    var decoded: [8]u8 = undefined;

    const loose = utf.base64.decode(&decoded, "aGVs\nbG8=", .{});
    try std.testing.expectEqualStrings("hello", decoded[0..loose.count]);

    const strict = utf.base64.decode(&decoded, "aGVsbG8", .{ .last_chunk = .strict });
    try std.testing.expectEqual(utf.Error.base64_input_remainder, strict.err);
    try std.testing.expectEqual(@as(usize, 7), strict.count);
}

test "decode in place" {
    var buffer: [8]u8 = "aGVsbG8=".*;
    const result = utf.base64.decode(&buffer, buffer[0..], .{});
    try std.testing.expectEqual(utf.Error.none, result.err);
    try std.testing.expectEqualStrings("hello", buffer[0..result.count]);
}
