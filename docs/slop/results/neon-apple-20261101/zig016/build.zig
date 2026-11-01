const std = @import("std");

// Interleaved A/B on the operations Ghostty calls: simdutf (Ghostty's
// vendored 9.0.0), utf at a base revision, and utf from this tree, in one
// process.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize: std.builtin.OptimizeMode = .ReleaseFast;
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
    inline for (.{ "base", "new", "alt" }) |arm| {
        const utf = b.dependency("utf_" ++ arm, .{ .target = target, .optimize = optimize }).module("utf");
        const opts = b.addOptions();
        opts.addOption([]const u8, "prefix", arm);
        const shim = b.addLibrary(.{
            .name = "shim_" ++ arm,
            .linkage = .static,
            .root_module = b.createModule(.{
                .root_source_file = b.path("shim.zig"),
                .strip = false,
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "utf", .module = utf },
                    .{ .name = "opts", .module = opts.createModule() },
                },
            }),
            .use_llvm = true,
        });
        exe.root_module.linkLibrary(shim);
        b.getInstallStep().dependOn(&b.addInstallFile(shim.getEmittedAsm(), arm ++ ".s").step);
    }
    b.installArtifact(exe);
}
