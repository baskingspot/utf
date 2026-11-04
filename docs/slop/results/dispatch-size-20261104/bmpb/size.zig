//! Reads stdin, converts it with one set of BMP converters, and writes the
//! result: `none` copies, `utf-*` calls utf's, `enc-*` encoding's copies;
//! `to8` the UTF-16 to UTF-8 direction, `from8` the other, `both` both;
//! `gen-from8` calls one general converter, `convert.utf8ToUtf16le`.
const std = @import("std");
const utf = @import("utf");
const enc = @import("enc");
const variant = @import("options").variant;
const linux = std.os.linux;

var in: [1 << 16]u8 align(16) = undefined;
var units: [1 << 16]u16 = undefined;
var out: [3 << 16]u8 = undefined;

pub fn main() void {
    const n = linux.read(0, &in, in.len);
    if (n > in.len) return;
    const src = in[0..n];
    var len: usize = n;
    const both = comptime std.mem.endsWith(u8, variant, "both");
    const from8 = both or comptime std.mem.endsWith(u8, variant, "from8");
    const to8 = both or comptime std.mem.endsWith(u8, variant, "to8");
    const is_utf = comptime std.mem.startsWith(u8, variant, "utf");
    var k: usize = n / 2;
    if (comptime std.mem.eql(u8, variant, "none")) {
        @memcpy(out[0..n], src);
    } else if (comptime std.mem.eql(u8, variant, "gen-from8")) {
        // One general converter: UTF-8 to UTF-16LE, checked.
        k = utf.convert.utf8ToUtf16le(src, &units).written;
        len = 2 * k;
        @memcpy(out[0..len], std.mem.sliceAsBytes(units[0..k]));
    } else {
        if (from8) {
            k = if (is_utf) utf.convert.utf8ToBmp(src, &units).written else enc.utf8ToBmp(src, &units).written;
        } else {
            @memcpy(std.mem.sliceAsBytes(units[0..k]), src[0 .. 2 * k]);
        }
        if (to8) {
            len = if (is_utf) utf.convert.bmpToUtf8(units[0..k], &out).written else enc.bmpToUtf8(units[0..k], &out).written;
        } else {
            len = 2 * k;
            @memcpy(out[0..len], std.mem.sliceAsBytes(units[0..k]));
        }
    }
    _ = linux.write(1, &out, len);
}
