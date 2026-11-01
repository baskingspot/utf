const std = @import("std");
pub fn build(b: *std.Build) void {
    const cpu = b.option([]const u8, "utf-cpu", "cpu") orelse "native";
    const dispatch = b.option(bool, "utf-dispatch", "dispatch");
    const optimize = b.option(std.builtin.OptimizeMode, "utf-optimize", "opt") orelse .fast;
    const target = b.resolveTargetQuery(std.Target.Query.parse(.{ .cpu_features = cpu }) catch unreachable);
    const dep = if (dispatch) |d| b.dependency("utf", .{ .target = target, .optimize = optimize, .dispatch = d }) else b.dependency("utf", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{ .name = "calls", .root_module = b.createModule(.{
        .root_source_file = b.path("zig/calls.zig"), .target = target, .optimize = optimize,
        .imports = &.{.{ .name = "utf", .module = dep.module("utf") }},
    }) });
    b.installArtifact(exe);
}
