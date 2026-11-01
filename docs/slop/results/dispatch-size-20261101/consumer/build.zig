//! A consumer that calls what Ghostty's libghostty-vt calls, as an
//! executable and a shared library. `-Dutf-dispatch` passes `.dispatch`.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip the outputs (default: true)") orelse true;
    const dispatch = b.option(bool, "utf-dispatch", "utf's -Ddispatch");
    const dep = if (dispatch) |d|
        b.dependency("utf", .{ .target = target, .optimize = optimize, .dispatch = d })
    else
        b.dependency("utf", .{ .target = target, .optimize = optimize });
    const imports: []const std.Build.Module.Import = &.{.{ .name = "utf", .module = dep.module("utf") }};
    b.installArtifact(b.addExecutable(.{ .name = "consumer", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = imports,
    }) }));
    b.installArtifact(b.addLibrary(.{ .name = "consumer", .linkage = .dynamic, .root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .pic = true,
        .imports = imports,
    }) }));
}
