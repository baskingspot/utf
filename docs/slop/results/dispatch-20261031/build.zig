const std = @import("std");
const testingx = @import("testingx");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const dispatch = b.option(bool, "utf-dispatch", "forwarded to utf's -Ddispatch");
    const utf = if (dispatch) |d|
        b.dependency("utf", .{ .target = target, .optimize = optimize, .dispatch = d })
    else
        b.dependency("utf", .{ .target = target, .optimize = optimize });
    const tx = b.dependency("testingx", .{ .target = target });
    const exe = testingx.addBenchExe(b, .{
        .name = "ab",
        .root_source_file = b.path("bench.zig"),
        .target = target,
        .optimize = optimize,
        .module = tx.module("testingx"),
        .imports = &.{.{ .name = "utf", .module = utf.module("utf") }},
    });
    b.installArtifact(exe);
}
