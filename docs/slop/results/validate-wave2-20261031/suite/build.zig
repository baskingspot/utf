//! Scratch validation benchmarks: `-Dsrc=<tree>` picks the package tree, so
//! two trees build side by side (`-Dname` names the binary).
const std = @import("std");
const testingx_build = @import("testingx");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const src = b.option([]const u8, "src", "package tree") orelse "/home/user/workspace/repo";
    const name = b.option([]const u8, "name", "binary name") orelse "vb";
    const suite = b.option([]const u8, "suite", "suite root") orelse "bench.zig";
    // `-Dpkg`: the repository's own module, with its default dispatch.
    const pkg = b.option(bool, "pkg", "use the repository's module") orelse false;
    const utf = if (pkg) (b.lazyDependency("utf", .{ .target = target, .optimize = .ReleaseFast }) orelse return).module("utf") else b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.fmt("{s}/src/root.zig", .{src}) },
        .target = target,
        .optimize = .ReleaseFast,
    });
    // The package's dispatch options, off: `-Dcpu` picks the kernels.
    const options = b.addOptions();
    options.addOption(enum { off, main, kernel }, "role", .off);
    options.addOption([]const u8, "prefix", "vb");
    options.addOption(bool, "pin", false);
    if (!pkg) utf.addImport("dispatch_options", options.createModule());
    const testingx = b.dependency("testingx", .{ .target = target }).module("testingx");
    const exe = testingx_build.addBenchExe(b, .{
        .name = name,
        .module = testingx,
        .root_source_file = b.path(suite),
        .imports = &.{.{ .name = "utf", .module = utf }},
        .target = target,
    });
    b.installArtifact(exe);
    const dump = b.addExecutable(.{ .name = "dump", .root_module = b.createModule(.{
        .root_source_file = b.path("dump.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    }) });
    b.installArtifact(dump);
}
