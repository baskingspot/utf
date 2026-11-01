//! The four calls Ghostty's libghostty-vt makes, as C exports.
const utf = @import("utf");

export fn c_utf8_to_utf32(src: [*]const u8, n: usize, dst: [*]u32, m: usize) usize {
    const r = utf.convert.utf8ToUtf32(src[0..n], dst[0..m]);
    return if (r.err == .none) r.count else 0;
}
export fn c_count_utf8(src: [*]const u8, n: usize) usize {
    return utf.length.countUtf8(src[0..n]);
}
export fn c_base64_decode(dst: [*]u8, m: usize, src: [*]const u8, n: usize) usize {
    const r = utf.base64.decode(dst[0..m], src[0..n], .{});
    return if (r.err == .none) r.count else 0;
}
export fn c_base64_max(n: usize) usize {
    return utf.base64.maxDecodedLen(n);
}
