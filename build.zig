const std = @import("std");
const simd = @import("src/simd.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dispatch_option = b.option(
        bool,
        "dispatch",
        "Pick the x86-64 SIMD kernels at runtime (default: for a generic x86-64 CPU, not a native or named one)",
    );

    // The one exported module. Everything below is a developer step, so a
    // consumer's fetch graph stops at this module.
    const mod = b.addModule("utf", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    addDispatch(b, mod, target, optimize, dispatch_option orelse dispatchByDefault(target));

    if (b.pkg_hash.len != 0) return;

    // Every step below needs testingx, which is lazy so a consumer never
    // fetches it. On the first configure pass it is not fetched yet, and the
    // build runner fetches it and reruns this script.
    const testingx = b.lazyDependency("testingx", .{ .target = target }) orelse return;
    const runner: std.Build.Step.Compile.TestRunner = .{
        .path = testingx.path("src/runner.zig"),
        .mode = .simple,
    };

    const mod_tests = b.addTest(.{ .root_module = mod, .test_runner = runner });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run the unit tests and the guide's examples");
    test_step.dependOn(&run_mod_tests.step);

    // The guide's examples are real programs against the public module,
    // tested with everything else so a guide page cannot show code that does
    // not build.
    const examples_mod = b.createModule(.{
        .root_source_file = b.path("docs/examples/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "utf", .module = mod }},
    });
    const example_tests = b.addTest(.{ .root_module = examples_mod, .test_runner = runner });
    const run_example_tests = b.addRunArtifact(example_tests);
    test_step.dependOn(&run_example_tests.step);

    // Compile-only gate for targets this host cannot run, such as
    // `zig build check -Dtarget=x86_64-windows-gnu`: the test binaries and
    // the kernel objects they link, built but not run.
    const check_step = b.step("check", "Compile the unit tests and the guide's examples without running them");
    check_step.dependOn(&mod_tests.step);
    check_step.dependOn(&example_tests.step);
}

const Role = enum { off, main, kernel, tables };

/// Whether a build for `target` picks its kernels at runtime by default: for
/// a generic x86-64 CPU, the baseline or an x86-64 level, as builds for
/// distribution name. A native or named CPU chooses at comptime.
fn dispatchByDefault(target: std.Build.ResolvedTarget) bool {
    const t = target.result;
    if (t.cpu.arch != .x86_64 or target.query.isNativeCpu()) return false;
    return t.cpu.model == std.Target.Cpu.Model.baseline(t.cpu.arch, t.os) or
        std.mem.startsWith(u8, t.cpu.model.name, "x86_64");
}

/// Gives `mod` its `dispatch_options` and, when it dispatches, one object per
/// tier above the target's own ISA, each this package compiled for that
/// tier's CPU (src/dispatch.zig).
fn addDispatch(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    enabled: bool,
) void {
    const x86_64 = target.result.cpu.arch == .x86_64;
    const tiers = if (enabled and x86_64) simd.dispatchAbove(simd.isaOf(target.result.cpu)) else &.{};
    // Unique to this build of the package, so two builds of it, such as two
    // optimize modes, can link into one program.
    const id = std.hash.Wyhash.hash(0, b.fmt("{s} {t}", .{ b.pkg_hash, optimize }));
    const prefix = b.fmt("utf_{x:0>8}", .{@as(u32, @truncate(id))});
    const options = b.addOptions();
    options.addOption(Role, "role", if (tiers.len > 0) .main else .off);
    options.addOption([]const u8, "prefix", prefix);
    // This repository's own tests pin each call to the `-Dcpu` level.
    options.addOption(bool, "pin", b.pkg_hash.len == 0);
    mod.addImport("dispatch_options", options.createModule());
    // ELF objects put their constant pools in sections of their own, through
    // their assembly (build/pools.zig).
    const pools = if (tiers.len > 0 and target.result.ofmt == .elf) b.addExecutable(.{
        .name = "utf-pools",
        .root_module = b.createModule(.{ .root_source_file = b.path("build/pools.zig"), .target = b.graph.host }),
    }) else null;
    if (tiers.len > 0) {
        // The tables the tiers share (`dispatch.shared`), defined in an
        // object of their own, a section each, so that a kernel's code is
        // the same as when it reads a table from elsewhere and the linker
        // drops a table no kernel reads.
        const tables_options = b.addOptions();
        tables_options.addOption(Role, "role", .tables);
        tables_options.addOption([]const u8, "prefix", prefix);
        tables_options.addOption(bool, "pin", false);
        const tables = b.addObject(.{
            .name = "utf-tables",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/dispatch.zig"),
                .target = target,
                .optimize = optimize,
                .pic = true,
                .imports = &.{.{ .name = "dispatch_options", .module = tables_options.createModule() }},
            }),
            .use_llvm = true,
        });
        tables.link_data_sections = true;
        mod.addObject(tables);
    }
    for (tiers) |t| {
        var query = target.query;
        query.cpu_model = .{ .explicit = t.model };
        query.cpu_features_add = std.Target.x86.featureSet(t.add);
        query.cpu_features_sub = .empty;
        const tier_target = b.resolveTargetQuery(query);
        const kernel_options = b.addOptions();
        kernel_options.addOption(Role, "role", .kernel);
        kernel_options.addOption([]const u8, "prefix", prefix);
        kernel_options.addOption(bool, "pin", false);
        const obj = b.addObject(.{
            .name = b.fmt("utf-{t}", .{t.isa}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/dispatch.zig"),
                .target = tier_target,
                .optimize = optimize,
                .pic = true,
                // Every call into an object is a call more than the kernel
                // inline; no frame setup on top of it.
                .omit_frame_pointer = if (comptime @hasField(std.builtin.OptimizeMode, "debug"))
                    (if (optimize == .debug) null else true)
                else
                    (if (optimize == .Debug) null else true),
                .imports = &.{.{ .name = "dispatch_options", .module = kernel_options.createModule() }},
            }),
            // The kernels' byte shuffles are LLVM intrinsics.
            .use_llvm = true,
        });
        // The object exports every wired function; in sections of their
        // own, the linker keeps only those the program's calls reach.
        obj.link_function_sections = true;
        obj.link_data_sections = true;
        const tool = pools orelse {
            mod.addObject(obj);
            continue;
        };
        // LLVM puts every function's pool entries that fit no mergeable
        // section, such as 64-byte AVX-512 vectors, in one `.rodata`, which
        // the linker keeps whole for any kernel's sake: 26 KB of AVX-512
        // constants in a program that calls one function. Split, each goes
        // with the function that uses it.
        const split = b.addRunArtifact(tool);
        split.addFileArg(obj.getEmittedAsm());
        const source = split.addOutputFileArg(b.fmt("utf-{t}.s", .{t.isa}));
        const assembled = b.addObject(.{
            .name = b.fmt("utf-{t}", .{t.isa}),
            .root_module = b.createModule(.{ .target = tier_target, .optimize = optimize }),
        });
        // Zig names no CPU to the assembler, which then pads loops with
        // 10-byte NOPs where the object had the tier's 15-byte ones: 4-5%
        // on 16-byte conversions in the AVX2 tier.
        assembled.root_module.addCSourceFile(.{
            .file = source,
            .flags = &.{b.fmt("-march={s}", .{t.model.llvm_name.?})},
        });
        mod.addObject(assembled);
    }
}
