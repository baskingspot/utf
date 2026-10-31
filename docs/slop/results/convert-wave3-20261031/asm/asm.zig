//! Every public conversion and length function of `utf`, exported under its
//! own name with a C ABI, for reading the generated code.
const utf = @import("utf");
const std = @import("std");

comptime {
    for (.{ utf.convert, utf.length }) |M| {
        for (@typeInfo(M).@"struct".decls) |d| {
            const F = @field(M, d.name);
            if (@typeInfo(@TypeOf(F)) != .@"fn") continue;
            const params = @typeInfo(@TypeOf(F)).@"fn".params;
            const S = params[0].type.?;
            const R = @typeInfo(@TypeOf(F)).@"fn".return_type.?;
            if (params.len == 1) {
                const W = struct {
                    fn f(p: [*]const std.meta.Child(S), n: usize) callconv(.c) usize {
                        return F(p[0..n]);
                    }
                };
                @export(&W.f, .{ .name = "x_" ++ d.name });
            } else {
                const D = params[1].type.?;
                const W = struct {
                    fn f(p: [*]const std.meta.Child(S), n: usize, q: [*]std.meta.Child(D), m: usize, err: *u8) callconv(.c) usize {
                        const r = F(p[0..n], q[0..m]);
                        if (R == usize) return r;
                        err.* = @intFromEnum(r.err);
                        return r.count;
                    }
                };
                @export(&W.f, .{ .name = "x_" ++ d.name });
            }
        }
    }
}
