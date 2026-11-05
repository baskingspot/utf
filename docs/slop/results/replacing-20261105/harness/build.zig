const std = @import("std");

// Interleaved A/B/C of Ghostty's UTF-8 decoder (src/simd/vt.zig): simdutf
// (Ghostty's vendored 9.0.0) in Ghostty's loop, utf in the same loop, and
// utf's `convert.utf8ToUtf32Replacing`, from this tree, in one process.
// `-Ddispatch=false` builds utf for the target CPU alone, as `-Dcpu`
// names it; by default a generic x86-64 CPU dispatches at run time.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize: std.lang.Optimize = .fast;
    const dispatch = b.option(bool, "dispatch", "Pass `.dispatch` to utf");
    const exe = b.addExecutable(.{
        .name = "ab",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    exe.root_module.addIncludePath(b.path("."));
    exe.root_module.addCSourceFiles(.{
        .files = &.{ "simdutf.cpp", "main.cpp" },
        .flags = &.{ "-std=c++17", "-fno-sanitize=undefined" },
    });
    const utf = if (dispatch) |d|
        b.dependency("utf", .{ .target = target, .optimize = optimize, .dispatch = d }).module("utf")
    else
        b.dependency("utf", .{ .target = target, .optimize = optimize }).module("utf");
    const shim = b.addLibrary(.{
        .name = "shim",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("shim.zig"),
            .strip = false,
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "utf", .module = utf }},
        }),
        .use_llvm = true,
    });
    exe.root_module.linkLibrary(shim);
    b.installArtifact(exe);
}
