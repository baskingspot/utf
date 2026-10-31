// The dispatch options a build-exe of the driver gives the package: no
// runtime dispatch, so `-mcpu` picks the kernels at comptime.
pub const Role = enum { off, main, kernel };
pub const role: Role = .off;
pub const prefix: []const u8 = "utf_bench";
pub const pin: bool = false;
