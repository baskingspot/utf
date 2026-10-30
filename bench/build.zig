//! The benchmark harness's Zig programs (bench/README.md), a build of its
//! own so the package's build and fetch graph never see them. Everything is
//! ReleaseFast for the host CPU. The C++, Go, and Rust programs are built by
//! the justfile with their own toolchains.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const utf = b.dependency("utf", .{ .target = target, .optimize = optimize }).module("utf");
    const testingx = b.dependency("testingx", .{ .target = target }).module("testingx");

    // The two Zig arms are one program: `impl` picks Zig's std or this package.
    for ([_][]const u8{ "std", "utf" }) |impl| {
        const options = b.addOptions();
        options.addOption([]const u8, "impl", impl);
        const exe = b.addExecutable(.{
            .name = b.fmt("bench-{s}", .{impl}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("zig/arm.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "utf", .module = utf },
                    .{ .name = "testingx", .module = testingx },
                    .{ .name = "build_options", .module = options.createModule() },
                },
            }),
        });
        b.installArtifact(exe);
    }

    // `just bench-corpus` runs this from the repository root.
    const corpus = b.addExecutable(.{
        .name = "bench-corpus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/corpus.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(corpus);

    // `just oracle` runs this from the repository root, with the C++ oracle
    // built.
    const oracle = b.createModule(.{
        .root_source_file = b.path("oracle/Oracle.zig"),
        .target = target,
        .optimize = optimize,
    });
    const compare = b.addExecutable(.{
        .name = "oracle-compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("oracle/compare.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "utf", .module = utf },
                .{ .name = "Oracle", .module = oracle },
            },
        }),
    });
    b.installArtifact(compare);
}
