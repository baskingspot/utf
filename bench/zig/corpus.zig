//! Generates the benchmark corpus in `bench/corpus-gen/` from the fetched
//! lipsum texts in `bench/corpus-gen/lipsum/` (bench/README.md). Run from
//! the repository root by `just bench-corpus`, which then checks every file
//! against `bench/corpus/SHA256SUMS`. The output depends only on the lipsum
//! bytes and the fixed seeds here, so the sums pin it.
//!
//! One directory per kind of input; each arm maps an operation to one:
//!
//!     utf8/      valid UTF-8: the lipsum texts, and ASCII text of each size
//!     utf8-err/  utf8/ with the lead byte of its last character made 0xFF
//!     utf16le/   valid UTF-16LE: the lipsum texts, and utf8/'s ASCII widened
//!     binary/    random bytes of each size
//!     base64/    binary/ in standard padded base64

const std = @import("std");
const mem = std.mem;
const Io = std.Io;

const root = "bench/corpus-gen";
const sizes = [_]usize{ 16, 64, 256, 4096, 65536, 1048576 };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const cwd = Io.Dir.cwd();
    var dir = try cwd.openDir(io, root, .{});
    defer dir.close(io);
    for ([_][]const u8{ "utf8", "utf8-err", "utf16le", "binary", "base64" }) |sub| {
        try dir.createDirPath(io, sub);
    }

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
            try writeUtf8(io, dir, gpa, lang, data);
        } else if (mem.eql(u8, kind, "utf16.txt")) {
            try write(io, dir, "utf16le", lang, data);
        }
    }

    for (sizes) |n| {
        const name = try std.fmt.allocPrint(gpa, "ascii-{d}", .{n});
        const text = try gpa.alloc(u8, n);
        asciiText(text, n);
        try writeUtf8(io, dir, gpa, name, text);
        const wide = try gpa.alloc(u8, 2 * n);
        for (text, 0..) |c, i| {
            wide[2 * i] = c;
            wide[2 * i + 1] = 0;
        }
        try write(io, dir, "utf16le", name, wide);

        const random_name = try std.fmt.allocPrint(gpa, "random-{d}", .{n});
        const random = try gpa.alloc(u8, n);
        var prng: std.Random.DefaultPrng = .init(0xba5e64 ^ n);
        prng.random().bytes(random);
        try write(io, dir, "binary", random_name, random);
        const encoder = std.base64.standard.Encoder;
        const encoded = try gpa.alloc(u8, encoder.calcSize(n));
        try write(io, dir, "base64", random_name, encoder.encode(encoded, random));
    }
}

/// Writes `text` to utf8/ and its copy with an error near the end to
/// utf8-err/: the last character's first byte becomes 0xFF, a byte no
/// UTF-8 sequence holds.
fn writeUtf8(io: Io, dir: Io.Dir, gpa: mem.Allocator, name: []const u8, text: []const u8) !void {
    try write(io, dir, "utf8", name, text);
    const bad = try gpa.dupe(u8, text);
    var last = bad.len - 1;
    while (bad[last] & 0xC0 == 0x80) last -= 1;
    bad[last] = 0xFF;
    try write(io, dir, "utf8-err", name, bad);
}

fn write(io: Io, dir: Io.Dir, sub: []const u8, name: []const u8, data: []const u8) !void {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ sub, name });
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

/// Lower-case words of 1 to 10 letters, separated by spaces, with a period
/// and a newline now and then: ASCII prose, from a seed that depends only
/// on the size.
fn asciiText(out: []u8, n: usize) void {
    var prng: std.Random.DefaultPrng = .init(0xa5c11 ^ n);
    const r = prng.random();
    var i: usize = 0;
    while (i < out.len) {
        const word = 1 + r.uintLessThan(usize, 10);
        for (0..word) |_| {
            if (i == out.len) return;
            out[i] = 'a' + r.uintLessThan(u8, 26);
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
