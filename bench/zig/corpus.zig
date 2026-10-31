//! Generates the benchmark corpus in `bench/corpus-gen/` from the fetched
//! lipsum texts in `bench/corpus-gen/lipsum/` (bench/README.md). Run from
//! the repository root by `just bench-corpus`, which then checks every file
//! against `bench/corpus/SHA256SUMS`. The output depends only on the lipsum
//! bytes and the fixed seeds here, so the sums pin it.
//!
//! One directory per kind of input; `bench/ops.tsv` maps each operation to
//! one. Every file in an `-err` directory is its valid twin with an error
//! in its last character.
//!
//!     ascii/            the ASCII texts of utf8/: ascii-N and latin
//!     ascii-err/        ascii/ with the last byte made 0xFF
//!     utf8/             valid UTF-8: the lipsum texts, and ASCII text of each size
//!     utf8-err/         utf8/ with the lead byte of its last character made 0xFF
//!     utf16le/          valid UTF-16LE: the lipsum texts, and utf8/'s ASCII widened
//!     utf16le-err/      utf16le/ with the last code unit made 0xD800
//!     utf16be/          utf16le/ byte-swapped
//!     utf16be-err/      utf16le-err/ byte-swapped
//!     utf32/            utf8/ in UTF-32LE
//!     utf32-err/        utf32/ with the last code point made 0xD800
//!     latin1/           Latin-1: ascii/, and latin1-N, text with accented letters
//!     latin1-as-utf8/   latin1/ in UTF-8, and likewise in UTF-16LE, UTF-16BE,
//!                       and UTF-32: inputs every conversion to Latin-1 can take
//!     binary/           random bytes of each size
//!     base64/           binary/ in standard padded base64
//!     base64url/        binary/ in URL-safe base64 without padding
//!     base64-unpadded/  binary/ in standard base64 without padding
//!     base64-mime/      base64/ wrapped at 76 columns with CRLF, as MIME does

const std = @import("std");
const mem = std.mem;
const Io = std.Io;

const root = "bench/corpus-gen";
const sizes = [_]usize{ 16, 64, 256, 4096, 65536, 1048576 };

const dirs = [_][]const u8{
    "ascii",             "ascii-err",         "utf8",            "utf8-err",
    "utf16le",           "utf16le-err",       "utf16be",         "utf16be-err",
    "utf32",             "utf32-err",         "latin1",          "latin1-as-utf8",
    "latin1-as-utf16le", "latin1-as-utf16be", "latin1-as-utf32", "binary",
    "base64",            "base64url",         "base64-unpadded", "base64-mime",
};

const Out = struct {
    io: Io,
    dir: Io.Dir,
    gpa: mem.Allocator,

    fn write(out: Out, sub: []const u8, name: []const u8, data: []const u8) !void {
        var buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ sub, name });
        try out.dir.writeFile(out.io, .{ .sub_path = path, .data = data });
    }

    /// Writes valid UTF-8 `text` to utf8/, its UTF-32 to utf32/, and their
    /// copies with an error at the end to utf8-err/ and utf32-err/: the
    /// last character's first byte becomes 0xFF, a byte no UTF-8 sequence
    /// holds, and the last code point becomes a surrogate. An ASCII text
    /// also goes to ascii/, ascii-err/, and the Latin-1 directories.
    fn utf8(out: Out, name: []const u8, text: []const u8) !void {
        try out.write("utf8", name, text);
        const bad = try out.gpa.dupe(u8, text);
        var last = bad.len - 1;
        while (bad[last] & 0xC0 == 0x80) last -= 1;
        bad[last] = 0xFF;
        try out.write("utf8-err", name, bad);

        const wide = try utf32(out.gpa, text);
        try out.write("utf32", name, wide);
        const bad_wide = try out.gpa.dupe(u8, wide);
        mem.writeInt(u32, bad_wide[bad_wide.len - 4 ..][0..4], 0xD800, .little);
        try out.write("utf32-err", name, bad_wide);

        for (text) |c| {
            if (c >= 0x80) return;
        }
        try out.write("ascii", name, text);
        const bad_ascii = try out.gpa.dupe(u8, text);
        bad_ascii[bad_ascii.len - 1] = 0xFF;
        try out.write("ascii-err", name, bad_ascii);
        try out.latin1(name, text);
    }

    /// Writes valid UTF-16LE `data` to utf16le/ and byte-swapped to
    /// utf16be/, and both with the last code unit made a high surrogate,
    /// which nothing follows, to the `-err` directories.
    fn utf16le(out: Out, name: []const u8, data: []const u8) !void {
        try out.write("utf16le", name, data);
        try out.write("utf16be", name, try swap16(out.gpa, data));
        const bad = try out.gpa.dupe(u8, data);
        mem.writeInt(u16, bad[bad.len - 2 ..][0..2], 0xD800, .little);
        try out.write("utf16le-err", name, bad);
        try out.write("utf16be-err", name, try swap16(out.gpa, bad));
    }

    /// Writes Latin-1 `text` to latin1/ and in each Unicode form to the
    /// `latin1-as-` directories.
    fn latin1(out: Out, name: []const u8, text: []const u8) !void {
        try out.write("latin1", name, text);
        var as_utf8: std.ArrayList(u8) = .empty;
        const as_utf16 = try out.gpa.alloc(u8, 2 * text.len);
        const as_utf32 = try out.gpa.alloc(u8, 4 * text.len);
        for (text, 0..) |c, i| {
            var buf: [2]u8 = undefined;
            const n = std.unicode.utf8Encode(c, &buf) catch unreachable;
            try as_utf8.appendSlice(out.gpa, buf[0..n]);
            mem.writeInt(u16, as_utf16[2 * i ..][0..2], c, .little);
            mem.writeInt(u32, as_utf32[4 * i ..][0..4], c, .little);
        }
        try out.write("latin1-as-utf8", name, as_utf8.items);
        try out.write("latin1-as-utf16le", name, as_utf16);
        try out.write("latin1-as-utf16be", name, try swap16(out.gpa, as_utf16));
        try out.write("latin1-as-utf32", name, as_utf32);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const cwd = Io.Dir.cwd();
    var dir = try cwd.openDir(io, root, .{});
    defer dir.close(io);
    for (dirs) |sub| try dir.createDirPath(io, sub);
    const out: Out = .{ .io = io, .dir = dir, .gpa = gpa };

    // The lipsum texts, renamed to the language in lower case:
    // Arabic-Lipsum.utf8.txt is utf8/arabic.
    var lipsum = try dir.openDir(io, "lipsum", .{ .iterate = true });
    defer lipsum.close(io);
    var it = lipsum.iterate();
    while (try it.next(io)) |entry| {
        const lang_end = mem.find(u8, entry.name, "-Lipsum.") orelse continue;
        const lang = try std.ascii.allocLowerString(gpa, entry.name[0..lang_end]);
        const kind = entry.name[lang_end + "-Lipsum.".len ..];
        const data = try lipsum.readFileAlloc(io, entry.name, gpa, .unlimited);
        if (mem.eql(u8, kind, "utf8.txt")) {
            try out.utf8(lang, data);
        } else if (mem.eql(u8, kind, "utf16.txt")) {
            try out.utf16le(lang, data);
        }
    }

    for (sizes) |n| {
        const name = try std.fmt.allocPrint(gpa, "ascii-{d}", .{n});
        const text = try gpa.alloc(u8, n);
        asciiText(text, n);
        try out.utf8(name, text);
        const wide = try gpa.alloc(u8, 2 * n);
        for (text, 0..) |c, i| {
            wide[2 * i] = c;
            wide[2 * i + 1] = 0;
        }
        try out.utf16le(name, wide);

        const latin1_name = try std.fmt.allocPrint(gpa, "latin1-{d}", .{n});
        const latin1 = try gpa.alloc(u8, n);
        latin1Text(latin1, n);
        try out.latin1(latin1_name, latin1);

        const random_name = try std.fmt.allocPrint(gpa, "random-{d}", .{n});
        const random = try gpa.alloc(u8, n);
        var prng: std.Random.DefaultPrng = .init(0xba5e64 ^ n);
        prng.random().bytes(random);
        try out.write("binary", random_name, random);
        const b64 = std.base64;
        const encoded = b64.standard.Encoder.encode(try gpa.alloc(u8, b64.standard.Encoder.calcSize(n)), random);
        try out.write("base64", random_name, encoded);
        try out.write("base64url", random_name, b64.url_safe_no_pad.Encoder.encode(
            try gpa.alloc(u8, b64.url_safe_no_pad.Encoder.calcSize(n)),
            random,
        ));
        try out.write("base64-unpadded", random_name, b64.standard_no_pad.Encoder.encode(
            try gpa.alloc(u8, b64.standard_no_pad.Encoder.calcSize(n)),
            random,
        ));
        try out.write("base64-mime", random_name, try mime(gpa, encoded));
    }
}

/// Valid UTF-8 as UTF-32LE.
fn utf32(gpa: mem.Allocator, text: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepoint()) |c| {
        var buf: [4]u8 = undefined;
        mem.writeInt(u32, &buf, c, .little);
        try list.appendSlice(gpa, &buf);
    }
    return list.items;
}

/// UTF-16 with each code unit's bytes swapped.
fn swap16(gpa: mem.Allocator, data: []const u8) ![]u8 {
    const swapped = try gpa.alloc(u8, data.len);
    for (0..data.len / 2) |i| {
        swapped[2 * i] = data[2 * i + 1];
        swapped[2 * i + 1] = data[2 * i];
    }
    return swapped;
}

/// Base64 in lines of 76 characters, each ended by CRLF, as RFC 2045's
/// MIME bodies are.
fn mime(gpa: mem.Allocator, encoded: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < encoded.len) : (i += 76) {
        try list.appendSlice(gpa, encoded[i..@min(i + 76, encoded.len)]);
        try list.appendSlice(gpa, "\r\n");
    }
    return list.items;
}

/// Lower-case words of 1 to 10 letters, separated by spaces, with a period
/// and a newline now and then: ASCII prose, from a seed that depends only
/// on the size.
fn asciiText(out: []u8, n: usize) void {
    var prng: std.Random.DefaultPrng = .init(0xa5c11 ^ n);
    words(out, prng.random(), 0);
}

/// `asciiText` with one letter in eight an accented Latin-1 letter
/// (0xE0-0xFF, without the division sign 0xF7), about the mix of French or
/// German prose.
fn latin1Text(out: []u8, n: usize) void {
    var prng: std.Random.DefaultPrng = .init(0x1a71 ^ n);
    words(out, prng.random(), 8);
}

/// Fills `out` with words; one letter in `accent` (none when 0) is
/// accented.
fn words(out: []u8, r: std.Random, accent: u8) void {
    var i: usize = 0;
    while (i < out.len) {
        const word = 1 + r.uintLessThan(usize, 10);
        for (0..word) |_| {
            if (i == out.len) return;
            out[i] = 'a' + r.uintLessThan(u8, 26);
            if (accent != 0 and r.uintLessThan(u8, accent) == 0) {
                out[i] = 0xE0 + r.uintLessThan(u8, 31);
                if (out[i] >= 0xF7) out[i] += 1;
            }
            i += 1;
        }
        if (i == out.len) return;
        out[i] = switch (r.uintLessThan(u8, 16)) {
            0 => '.',
            1 => '\n',
            else => ' ',
        };
        i += 1;
    }
}
