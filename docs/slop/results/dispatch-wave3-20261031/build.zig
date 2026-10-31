const std = @import("std");
const testingx = @import("testingx");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "mode", "") orelse .ReleaseFast;
    const tree = b.option([]const u8, "tree", "new or old") orelse "new";
    const src = b.option([]const u8, "src", "bench source") orelse "bench.zig";
    const dispatch = b.option(bool, "utf-dispatch", "forwarded to utf's -Ddispatch");
    const utf = if (dispatch) |d|
        b.dependency(tree, .{ .target = target, .optimize = optimize, .dispatch = d })
    else
        b.dependency(tree, .{ .target = target, .optimize = optimize });
    const tx = b.dependency("testingx", .{ .target = target });
    const exe = testingx.addBenchExe(b, .{
        .name = "ab",
        .root_source_file = b.path(src),
        .target = target,
        .optimize = optimize,
        .module = tx.module("testingx"),
        .imports = &.{.{ .name = "utf", .module = utf.module("utf") }},
    });
    b.installArtifact(exe);
    const audit = b.addExecutable(.{ .name = "audit", .root_module = b.createModule(.{
        .root_source_file = b.path("audit.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "utf", .module = utf.module("utf") }},
    }) });
    b.installArtifact(audit);
}
