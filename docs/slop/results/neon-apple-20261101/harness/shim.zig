//! Ghostty's DecodeUTF8 (src/simd/vt.cpp) and base64 decode
//! (src/simd/base64.cpp) written with utf, exported under a prefix.
const utf = @import("utf");
const prefix = @import("opts").prefix;

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

fn decodeUtf8(input: [*]const u8, count: usize, output: [*]u32) callconv(.c) usize {
    var in = input[0..count];
    var out: usize = 0;
    while (in.len > 0) {
        const r = utf.convert.utf8ToUtf32(in, output[out..][0..in.len]);
        if (r.err == .none) {
            out += r.count;
            break;
        }
        out += utf.length.countUtf8(in[0..r.count]);
        const skip = r.count + maximalSubpart(in[r.count..]);
        output[out] = 0xFFFD;
        out += 1;
        in = in[skip..];
    }
    return out;
}

fn b64Decode(input: [*]const u8, len: usize, output: [*]u8) callconv(.c) isize {
    const r = utf.base64.decode(output[0..utf.base64.maxDecodedLen(len)], input[0..len], .{});
    if (r.err != .none) return -1;
    return @intCast(r.count);
}

fn toUtf16(input: [*]const u8, len: usize, output: [*]u16) callconv(.c) usize {
    const r = utf.convert.utf8ToUtf16le(input[0..len], output[0..len]);
    return r.count;
}

comptime {
    @export(&toUtf16, .{ .name = prefix ++ "_to_utf16" });
    @export(&decodeUtf8, .{ .name = prefix ++ "_decode_utf8" });
    @export(&b64Decode, .{ .name = prefix ++ "_b64_decode" });
}
