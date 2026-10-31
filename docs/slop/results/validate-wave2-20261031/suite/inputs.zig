//! The inputs every arm times, the same bytes in each: texts in UTF-8,
//! UTF-16LE/BE, and UTF-32, at sizes in bytes of that encoding, valid and
//! with an error in the last character. Each input starts 16 bytes past a
//! 64-byte boundary, as a malloc'd buffer does.
const std = @import("std");

pub const texts = .{
    .{ "ascii", "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs! 0123456789 " },
    .{ "latin", "Le cœur a ses raisons que la raison ne connaît point. Où êtes-vous allés? Ça va très bien, merci. Die Größe der Bäume überrascht. " },
    .{ "arabic", "اللغة العربية هي إحدى أكثر اللغات انتشاراً في العالم، يتحدثها أكثر من ٤٢٢ مليون نسمة. " },
    .{ "chinese", "中文是世界上使用人数最多的语言之一，汉字有着悠久的历史和丰富的文化内涵。" },
    .{ "emoji", "😀😃😄😁😆😅🤣😂🙂🙃😉😊😇🥰😍🤩😘😗☺😚😙🥲😋😛😜🤪😝🤑🤗🤭" },
};
pub const sizes = [_]usize{ 7, 16, 23, 32, 45, 64, 128, 256, 1024, 4096, 65536, 1 << 20 };

pub const Kind = enum { utf8, ascii, utf16le, utf16be, utf32 };
pub const Form = enum { plain, with_errors, err };

pub const Op = struct { kind: Kind, form: Form };

pub fn rowName(comptime op: Op) []const u8 {
    const k = switch (op.kind) {
        .utf8 => "Utf8",
        .ascii => "Ascii",
        .utf16le => "Utf16le",
        .utf16be => "Utf16be",
        .utf32 => "Utf32",
    };
    return "Validate" ++ k ++ switch (op.form) {
        .plain => "",
        .with_errors => "WithErrors",
        .err => "Err",
    };
}

pub const ops = blk: {
    var list: []const Op = &.{};
    for (std.enums.values(Kind)) |k| for (std.enums.values(Form)) |f| {
        list = list ++ .{Op{ .kind = k, .form = f }};
    };
    break :blk list;
};

/// Whether a kind is timed on a text: ASCII only on ASCII text.
pub fn applies(kind: Kind, text: []const u8) bool {
    return kind == .utf8 or (kind == .ascii) == std.mem.eql(u8, text, "ascii");
}

fn alloc(a: std.mem.Allocator, n: usize) ![]u8 {
    return (try a.alignedAlloc(u8, .@"64", n + 64))[16..][0..n];
}

/// `size` bytes of repeated `seed`, cut at a character boundary and padded
/// with spaces.
fn utf8Text(a: std.mem.Allocator, seed: []const u8, size: usize) ![]u8 {
    const buf = try alloc(a, size);
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        const n = std.unicode.utf8ByteSequenceLength(seed[j]) catch unreachable;
        if (i + n > size) break;
        @memcpy(buf[i..][0..n], seed[j..][0..n]);
        i += n;
        j = (j + n) % seed.len;
    }
    @memset(buf[i..], ' ');
    return buf;
}

/// The input for one kind, text, and size, as bytes; `bad` puts an error
/// in its last character.
pub fn make(a: std.mem.Allocator, kind: Kind, seed: []const u8, size_in: usize, bad: bool) ![]u8 {
    const unit: usize = switch (kind) {
        .utf8, .ascii => 1,
        .utf16le, .utf16be => 2,
        .utf32 => 4,
    };
    const size = size_in - size_in % unit;
    const text = try utf8Text(a, seed, size);
    switch (kind) {
        .utf8, .ascii => {
            if (bad) {
                var last = text.len - 1;
                while (text[last] & 0xC0 == 0x80) last -= 1;
                text[last] = 0xFF;
            }
            return text;
        },
        .utf16le, .utf16be => {
            const out = try alloc(a, size);
            const u: []u16 = @alignCast(std.mem.bytesAsSlice(u16, out));
            var n: usize = 0;
            var it = std.unicode.Utf8View.initUnchecked(text).iterator();
            while (it.nextCodepoint()) |cp| {
                if (cp >= 0x10000) {
                    if (n + 2 > u.len) break;
                    const c = cp - 0x10000;
                    u[n] = @intCast(0xD800 + (c >> 10));
                    u[n + 1] = @intCast(0xDC00 + (c & 0x3FF));
                    n += 2;
                } else {
                    if (n + 1 > u.len) break;
                    u[n] = @intCast(cp);
                    n += 1;
                }
            }
            @memset(u[n..], ' ');
            if (bad) {
                if (u.len >= 2 and u[u.len - 2] & 0xFC00 == 0xD800) u[u.len - 2] = ' ';
                u[u.len - 1] = 0xDC00;
            }
            for (u) |*x| x.* = std.mem.nativeTo(u16, x.*, if (kind == .utf16le) .little else .big);
            return out;
        },
        .utf32 => {
            const out = try alloc(a, size);
            const u: []u32 = @alignCast(std.mem.bytesAsSlice(u32, out));
            var it = std.unicode.Utf8View.initUnchecked(text).iterator();
            for (u) |*x| x.* = it.nextCodepoint() orelse ' ';
            if (bad) u[u.len - 1] = 0x110000;
            return out;
        },
    }
}
