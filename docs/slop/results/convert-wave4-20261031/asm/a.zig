const utf = @import("utf");
export fn swap_le(s: [*]const u16, n: usize, d: [*]u16) usize {
    return utf.convert.validUtf16leToUtf16be(s[0..n], d[0..n]);
}
export fn l1u8(s: [*]const u8, n: usize, d: [*]u8, m: usize) usize {
    return utf.convert.validLatin1ToUtf8(s[0..n], d[0..m]);
}
export fn u8l1(s: [*]const u8, n: usize, d: [*]u8, m: usize) usize {
    return utf.convert.validUtf8ToLatin1(s[0..n], d[0..m]);
}
export fn l1u16(s: [*]const u8, n: usize, d: [*]u16, m: usize) usize {
    return utf.convert.validLatin1ToUtf16le(s[0..n], d[0..m]);
}
export fn u16l1(s: [*]const u16, n: usize, d: [*]u8, m: usize) usize {
    return utf.convert.utf16leToLatin1(s[0..n], d[0..m]).count;
}
export fn u8u16(s: [*]const u8, n: usize, d: [*]u16, m: usize) usize {
    return utf.convert.validUtf8ToUtf16le(s[0..n], d[0..m]);
}
export fn u16u32(s: [*]const u16, n: usize, d: [*]u32, m: usize) usize {
    return utf.convert.validUtf16leToUtf32(s[0..n], d[0..m]);
}
export fn l1u16be(s: [*]const u8, n: usize, d: [*]u16, m: usize) usize {
    return utf.convert.validLatin1ToUtf16be(s[0..n], d[0..m]);
}
export fn u32u16c(s: [*]const u32, n: usize, d: [*]u16, m: usize) usize {
    return utf.convert.utf32ToUtf16le(s[0..n], d[0..m]).count;
}
