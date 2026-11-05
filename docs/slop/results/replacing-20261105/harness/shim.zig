//! Ghostty's decodeUtf8 (src/simd/vt.zig) as it calls utf today, a loop
//! that restarts `utf8ToUtf32` after each error, and the same decoder as one
//! call to `utf8ToUtf32Replacing`. Both call utf out of line, as a
//! dispatched build does: inlined, the same kernel moved 16-byte rows by
//! up to 40% with the code around it.
const utf = @import("utf");

/// Ghostty's `maximalSubpart`.
fn maximalSubpart(p: []const u8) usize {
    if (p.len == 0) return 0;
    const b0 = p[0];
    if (b0 < 0xC2 or b0 > 0xF4) return 1;
    const seq: usize, const lo: [3]u8, const hi: [3]u8 = switch (b0) {
        0xC2...0xDF => .{ 2, .{ 0x80, 0, 0 }, .{ 0xBF, 0, 0 } },
        0xE0 => .{ 3, .{ 0xA0, 0x80, 0 }, .{ 0xBF, 0xBF, 0 } },
        0xE1...0xEC, 0xEE...0xEF => .{ 3, .{ 0x80, 0x80, 0 }, .{ 0xBF, 0xBF, 0 } },
        0xED => .{ 3, .{ 0x80, 0x80, 0 }, .{ 0x9F, 0xBF, 0 } },
        0xF0 => .{ 4, .{ 0x90, 0x80, 0x80 }, .{ 0xBF, 0xBF, 0xBF } },
        0xF1...0xF3 => .{ 4, .{ 0x80, 0x80, 0x80 }, .{ 0xBF, 0xBF, 0xBF } },
        else => .{ 4, .{ 0x80, 0x80, 0x80 }, .{ 0x8F, 0xBF, 0xBF } },
    };
    var valid: usize = 1;
    var i: usize = 0;
    while (i < seq - 1 and valid < p.len) : (i += 1) {
        const cb = p[valid];
        if (cb < lo[i] or cb > hi[i]) break;
        valid += 1;
    }
    return valid;
}

fn loopDecode(input: [*]const u8, count: usize, output: [*]u32) callconv(.c) usize {
    var in = input[0..count];
    var out: usize = 0;
    while (in.len > 0) {
        const r = @call(.never_inline, utf.convert.utf8ToUtf32, .{ in, output[out..][0..in.len] });
        out += r.written;
        if (r.err == .none) return out;
        output[out] = 0xFFFD;
        out += 1;
        in = in[r.count + maximalSubpart(in[r.count..]) ..];
    }
    return out;
}

fn replacingDecode(input: [*]const u8, count: usize, output: [*]u32) callconv(.c) usize {
    return @call(.never_inline, utf.convert.utf8ToUtf32Replacing, .{ input[0..count], output[0..count] });
}

comptime {
    @export(&loopDecode, .{ .name = "loop_decode_utf8" });
    @export(&replacingDecode, .{ .name = "replacing_decode_utf8" });
}
