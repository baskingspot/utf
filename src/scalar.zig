//! Scalar reference implementations, one code unit at a time. They define
//! the expected result for every SIMD path: a SIMD function must return
//! exactly what its scalar counterpart returns, error kind and position
//! included, on every input.

const std = @import("std");
const testing = std.testing;
const result = @import("result.zig");
const Result = result.Result;

/// Validates UTF-8, classifying errors exactly as simdutf's scalar
/// `validate_with_errors` does, so simdutf can serve as a differential
/// oracle. On failure `count` is the index of the first byte of the
/// ill-formed sequence.
pub fn validateUtf8(bytes: []const u8) Result {
    var i: usize = 0;
    while (i < bytes.len) {
        const lead = bytes[i];
        if (lead < 0x80) {
            i += 1;
            continue;
        }
        // The lead's high bits give the length, as simdutf reads them:
        // 110xxxxx, 1110xxxx, 11110xxx. A lone continuation is too long;
        // 11111xxx is a bad header.
        const len: usize = if (lead & 0xE0 == 0xC0)
            2
        else if (lead & 0xF0 == 0xE0)
            3
        else if (lead & 0xF8 == 0xF0)
            4
        else if (lead & 0xC0 == 0x80)
            return .fail(.too_long, i)
        else
            return .fail(.header_bits, i);
        if (i + len > bytes.len) return .fail(.too_short, i);
        var cp: u32 = lead & (@as(u8, 0x7F) >> @intCast(len));
        for (bytes[i + 1 .. i + len]) |b| {
            if (b & 0xC0 != 0x80) return .fail(.too_short, i);
            cp = (cp << 6) | (b & 0x3F);
        }
        switch (len) {
            2 => if (cp < 0x80) return .fail(.overlong, i),
            3 => {
                if (cp < 0x800) return .fail(.overlong, i);
                if (cp >= 0xD800 and cp <= 0xDFFF) return .fail(.surrogate, i);
            },
            else => {
                if (cp <= 0xFFFF) return .fail(.overlong, i);
                if (cp > 0x10FFFF) return .fail(.too_large, i);
            },
        }
        i += len;
    }
    return .ok(bytes.len);
}

test "validateUtf8 accepts well-formed text and every boundary code point" {
    const cases = [_][]const u8{
        "",
        "plain ASCII",
        "\x00\x7f",
        "\xc2\x80\xdf\xbf", // U+0080, U+07FF
        "\xe0\xa0\x80\xed\x9f\xbf\xee\x80\x80\xef\xbf\xbf", // U+0800, U+D7FF, U+E000, U+FFFF
        "\xf0\x90\x80\x80\xf4\x8f\xbf\xbf", // U+10000, U+10FFFF
        "héllo wörld ✓ 日本語 🎉",
    };
    for (cases) |s| try testing.expectEqual(Result.ok(s.len), validateUtf8(s));
}

test "validateUtf8 names the first ill-formed sequence and where it starts" {
    const cases = [_]struct { []const u8, result.Error, usize }{
        .{ "ab\x80", .too_long, 2 },
        .{ "\xc0\x80", .overlong, 0 }, // simdutf: C0 and C1 are overlong
        .{ "\xc1\xbf", .overlong, 0 },
        .{ "x\xf5\x80\x80\x80", .too_large, 1 }, // simdutf: F5-F7 are too large
        .{ "\xf8\x80\x80\x80", .header_bits, 0 },
        .{ "\xff", .header_bits, 0 },
        .{ "\xe0\x80\x80", .overlong, 0 }, // U+0000 in three bytes
        .{ "\xf0\x80\x80\x80", .overlong, 0 },
        .{ "\xed\xa0\x80", .surrogate, 0 }, // U+D800
        .{ "\xed\xbf\xbf", .surrogate, 0 }, // U+DFFF
        .{ "\xf4\x90\x80\x80", .too_large, 0 }, // U+110000
        .{ "ok\xe2\x82", .too_short, 2 }, // truncated at the end
        .{ "\xe2\x28\xa1", .too_short, 0 }, // a non-continuation inside
        .{ "\xc3", .too_short, 0 },
    };
    for (cases) |c| try testing.expectEqual(Result.fail(c[1], c[2]), validateUtf8(c[0]));
}
