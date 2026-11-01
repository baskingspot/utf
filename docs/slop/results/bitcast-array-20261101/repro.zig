export fn f(v: *const @Vector(128, u8), out: *[64]u16) void {
    out.* = @bitCast(v.*);
}
export fn g(v: *const @Vector(128, u8), out: *[64]u16) void {
    const w: @Vector(64, u16) = @bitCast(v.*);
    out.* = w;
}
