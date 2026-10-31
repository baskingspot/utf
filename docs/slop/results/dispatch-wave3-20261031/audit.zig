//! Every public function returning `Result`, kept, so its code can be read.
const std = @import("std");
const utf = @import("utf");

pub fn main() void {
    inline for (.{ utf.validate, utf.convert, utf.base64 }) |M| {
        inline for (@typeInfo(M).@"struct".decls) |d| {
            const x = @field(M, d.name);
            if (@typeInfo(@TypeOf(x)) == .@"fn") {
                const info = @typeInfo(@TypeOf(x)).@"fn";
                if (!info.is_generic and info.return_type == utf.Result) {
                    var p = &x;
                    std.mem.doNotOptimizeAway(&p);
                }
            }
        }
    }
}
