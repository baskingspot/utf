//! The benchmark harness's Zig programs (bench/README.md), a build of its
//! own so the package's build and fetch graph never see them. Everything is
//! ReleaseFast for `-Dcpu` (default the host CPU), except that
//! `-Dutf-optimize`, `-Dutf-cpu`, and `-Dutf-dispatch` build the `utf` arm,
//! and only it, another way. The C++, Go, and Rust programs are built by the
//! justfile with their own toolchains.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const utf = b.dependency("utf", .{ .target = target, .optimize = optimize }).module("utf");

    // `just bench-compare`'s `optimize`, `cpu`, and `dispatch`, for the utf arm.
    const arm_optimize = b.option(
        std.builtin.OptimizeMode,
        "utf-optimize",
        "The utf arm's optimize mode (default ReleaseFast)",
    ) orelse optimize;
    const arm_cpu = b.option(
        []const u8,
        "utf-cpu",
        "The utf arm's CPU: native (default), baseline, x86_64_v2, x86_64_v3, or another model",
    ) orelse "native";
    const query = std.Target.Query.parse(.{ .cpu_features = arm_cpu }) catch |err|
        std.debug.panic("-Dutf-cpu={s}: {t}", .{ arm_cpu, err });
    const arm_target = b.resolveTargetQuery(query);
    // Unset, the package's default: runtime dispatch for a generic x86-64
    // CPU (baseline or an x86-64 level), none for a native or named one.
    const arm_dispatch = b.option(
        bool,
        "utf-dispatch",
        "Whether the utf arm picks its x86-64 kernels at runtime (default: the package's)",
    );

    // The two Zig arms are one program: `impl` picks Zig's std or this package.
    for ([_][]const u8{ "std", "utf" }) |impl| {
        const is_utf = std.mem.eql(u8, impl, "utf");
        // std is built for `-Dcpu`, as `just bench-compare` builds the Rust
        // and Go arms for its `cpu`.
        const exe_target = if (is_utf) arm_target else target;
        const exe_optimize = if (is_utf) arm_optimize else optimize;
        const dep = if (is_utf and arm_dispatch != null)
            b.dependency("utf", .{ .target = exe_target, .optimize = exe_optimize, .dispatch = arm_dispatch.? })
        else
            b.dependency("utf", .{ .target = exe_target, .optimize = exe_optimize });
        const arm_utf = dep.module("utf");
        const testingx = b.dependency("testingx", .{ .target = exe_target }).module("testingx");
        const options = b.addOptions();
        options.addOption([]const u8, "impl", impl);
        const exe = b.addExecutable(.{
            .name = b.fmt("bench-{s}", .{impl}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("zig/arm.zig"),
                .target = exe_target,
                .optimize = exe_optimize,
                .imports = &.{
                    .{ .name = "utf", .module = arm_utf },
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
