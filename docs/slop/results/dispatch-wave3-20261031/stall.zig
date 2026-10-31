//! The `Result` copy: checked and `WithErrors` calls, each made out of line
//! with the result read field by field, so only the callee's own copy can
//! stall. One build per arm.
const std = @import("std");
const testingx = @import("testingx");
const utf = @import("utf");
const B = testingx.B;

const sizes = [_]usize{ 16, 64, 256, 1024, 4096 };
const latin = "Le cœur a ses raisons que la raison ne connaît point. Où êtes-vous allés? Ça va très bien. ";
const ascii = "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs! 0123 ";

var u8in: [2][sizes.len][]u8 = undefined; // ascii, latin UTF-8
var u16in: [sizes.len][]u16 = undefined; // latin as UTF-16LE, `size` bytes
var u32in: [sizes.len][]u32 = undefined; // latin as UTF-32, `size` bytes
var b64in: [sizes.len][]u8 = undefined; // base64 of `size` bytes
var out: []u8 = undefined;

fn alloc(comptime T: type, n: usize) ![]T {
    // 16 bytes past a 64-byte boundary.
    const raw = try std.heap.page_allocator.alignedAlloc(u8, .@"64", n * @sizeOf(T) + 16);
    return @as([*]T, @ptrCast(@alignCast(raw.ptr + 16)))[0..n];
}

fn text(seed: []const u8, size: usize) ![]u8 {
    const buf = try alloc(u8, size);
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

const Op = enum { utf8, ascii, utf16le, utf32, utf8ToUtf16le, latin1ToUtf16le, utf16leToUtf8, utf32ToUtf16le, b64decode };

pub fn benchmarkMain(b: *B) !void {
    @setEvalBranchQuota(100_000);
    out = try alloc(u8, 4 * 4096 + 64);
    for (sizes, 0..) |size, si| {
        u8in[0][si] = try text(ascii, size);
        u8in[1][si] = try text(latin, size);
        u16in[si] = try alloc(u16, size / 2);
        u32in[si] = try alloc(u32, size / 4);
        const l = try text(latin, size / 2);
        _ = utf.convert.validUtf8ToUtf16le(l[0 .. size / 2], u16in[si]);
        const k = try text(latin, size / 4);
        _ = utf.convert.validUtf8ToUtf32(k[0 .. size / 4], u32in[si]);
        const raw = u8in[0][si][0 .. size / 4 * 3];
        b64in[si] = try alloc(u8, utf.base64.encodedLen(raw.len, .{}));
        _ = utf.base64.encode(b64in[si], raw, .{});
    }
    inline for (std.meta.fields(Op)) |f| {
        inline for (sizes, 0..) |size, si| {
            const name = f.name ++ std.fmt.comptimePrint("/size={d}", .{size});
            try b.add(name, Run(@enumFromInt(f.value), si).run);
        }
    }
}

fn Run(comptime op: Op, comptime si: usize) type {
    return struct {
        fn call() utf.Result {
            return switch (op) {
                .utf8 => @call(.never_inline, utf.validate.utf8WithErrors, .{esc(u8in[1][si])}),
                .ascii => @call(.never_inline, utf.validate.asciiWithErrors, .{esc(u8in[0][si])}),
                .utf16le => @call(.never_inline, utf.validate.utf16leWithErrors, .{esc(u16in[si])}),
                .utf32 => @call(.never_inline, utf.validate.utf32WithErrors, .{esc(u32in[si])}),
                .utf8ToUtf16le => @call(.never_inline, utf.convert.utf8ToUtf16le, .{ esc(u8in[1][si]), dst(u16) }),
                .latin1ToUtf16le => @call(.never_inline, utf.convert.latin1ToUtf16le, .{ esc(u8in[1][si]), dst(u16) }),
                .utf16leToUtf8 => @call(.never_inline, utf.convert.utf16leToUtf8, .{ esc(u16in[si]), dst(u8) }),
                .utf32ToUtf16le => @call(.never_inline, utf.convert.utf32ToUtf16le, .{ esc(u32in[si]), dst(u16) }),
                .b64decode => @call(.never_inline, utf.base64.decode, .{ dst(u8), esc(b64in[si]), utf.base64.DecodeOptions{} }),
            };
        }
        fn run(b: *B) !void {
            b.setBytes(@intCast(sizes[si]));
            var n: usize = 0;
            defer b.keepAlive(n);
            while (try b.loop()) {
                const r = call();
                // Field by field: one 8-byte and one 1-byte load.
                var c = r.count;
                var e = r.err;
                std.mem.doNotOptimizeAway(&c);
                std.mem.doNotOptimizeAway(&e);
                n +%= c +% @intFromEnum(e);
            }
            if (call().err != .none) return b.fail();
        }
    };
}

inline fn esc(s: anytype) @TypeOf(s) {
    var p = s;
    std.mem.doNotOptimizeAway(&p);
    return p;
}

inline fn dst(comptime T: type) []T {
    var p: []T = @as([*]T, @ptrCast(@alignCast(out.ptr)))[0 .. out.len / @sizeOf(T)];
    std.mem.doNotOptimizeAway(&p);
    return p;
}
