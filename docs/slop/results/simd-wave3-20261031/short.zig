//! Short inputs through `simd.loadShort`: validation of 7-63 bytes, called
//! out of line, with the input 16 bytes past a 64-byte boundary (`mid`) or
//! ending 1 byte before a page whose next page is mapped but never touched
//! (`edge`), where a masked load's masked-off bytes reach that page.
const std = @import("std");
const testingx = @import("testingx");
const utf = @import("utf");
const B = testingx.B;

const sizes = [_]usize{ 7, 16, 33, 48, 63 };
const latin = "Le cœur a ses raisons que la raison ne connaît point. Où êtes-vous allés? Ça va très bien. ";

const Where = enum { mid, edge };
var u8in: [2][sizes.len][]u8 = undefined;
var u16in: [2][sizes.len][]u16 = undefined;
var u32in: [2][sizes.len][]u32 = undefined;

fn text(buf: []u8) void {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        const n = std.unicode.utf8ByteSequenceLength(latin[j]) catch unreachable;
        if (i + n > buf.len) break;
        @memcpy(buf[i..][0..n], latin[j..][0..n]);
        i += n;
        j = (j + n) % latin.len;
    }
    @memset(buf[i..], ' ');
}

/// `bytes` bytes, 16 past a 64-byte boundary or ending 1 byte before the
/// end of a page that is followed by a mapped page nothing touches.
fn place(where: Where, bytes: usize) ![*]u8 {
    const page = std.heap.page_size_min;
    const linux = std.os.linux;
    const mem = linux.mmap(null, 2 * page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    const base: [*]u8 = @ptrFromInt(mem);
    return switch (where) {
        .mid => base + 64 + 16,
        .edge => base + page - 1 - bytes - (page - 1 - bytes) % 4,
    };
}

pub fn benchmarkMain(b: *B) !void {
    @setEvalBranchQuota(100_000);
    for ([_]Where{ .mid, .edge }, 0..) |w, wi| {
        for (sizes, 0..) |size, si| {
            const p = try place(w, size);
            u8in[wi][si] = p[0..size];
            text(u8in[wi][si]);
            const q = try place(w, size / 4 * 4);
            const units16: [*]u16 = @ptrCast(@alignCast(q));
            u16in[wi][si] = units16[0 .. size / 2];
            for (u16in[wi][si], 0..) |*x, i| x.* = @intCast(0x41 + i % 26 + (i % 3) * 0x100);
            const units32: [*]u32 = @ptrCast(@alignCast(q));
            u32in[wi][si] = units32[0 .. size / 4];
            for (u32in[wi][si], 0..) |*x, i| x.* = @intCast(0x41 + i % 26 + (i % 3) * 0x1000);
        }
    }
    inline for (.{ "mid", "edge" }, 0..) |wn, wi| {
        inline for (sizes, 0..) |size, si| {
            const sfx = std.fmt.comptimePrint("/{s}/size={d}", .{ wn, size });
            try b.add("utf8" ++ sfx, Run(.utf8, wi, si).run);
            try b.add("utf8Err" ++ sfx, Run(.utf8e, wi, si).run);
            try b.add("utf16le" ++ sfx, Run(.utf16, wi, si).run);
            try b.add("utf32" ++ sfx, Run(.utf32, wi, si).run);
            try b.add("utf32Err" ++ sfx, Run(.utf32e, wi, si).run);
        }
    }
}

const Op = enum { utf8, utf8e, utf16, utf32, utf32e };

fn Run(comptime op: Op, comptime wi: usize, comptime si: usize) type {
    return struct {
        fn call() bool {
            return switch (op) {
                .utf8 => @call(.never_inline, utf.validate.utf8, .{esc(u8in[wi][si])}),
                .utf8e => @call(.never_inline, utf.validate.utf8WithErrors, .{esc(u8in[wi][si])}).err == .none,
                .utf16 => @call(.never_inline, utf.validate.utf16le, .{esc(u16in[wi][si])}),
                .utf32 => @call(.never_inline, utf.validate.utf32, .{esc(u32in[wi][si])}),
                .utf32e => @call(.never_inline, utf.validate.utf32WithErrors, .{esc(u32in[wi][si])}).err == .none,
            };
        }
        fn run(b: *B) !void {
            b.setBytes(@intCast(sizes[si]));
            var n: usize = 0;
            defer b.keepAlive(n);
            while (try b.loop()) n += @intFromBool(call());
            if (!call()) return b.fail();
        }
    };
}

inline fn esc(s: anytype) @TypeOf(s) {
    var p = s;
    std.mem.doNotOptimizeAway(&p);
    return p;
}
