//! The BMP converters' benchmark and size programs: `bmpb`, which times
//! utf's `convert.bmpToUtf8` and `utf8ToBmp`, encoding's copies of them
//! (enc_codec.zig, encoding's src/codec.zig at c45639d), and utf's general
//! converters; and `size-*`, programs that call only one set of them.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimize mode (default ReleaseFast)") orelse .ReleaseFast;
    const dispatch = b.option(bool, "utf-dispatch", "utf's dispatch option (default: utf's)");
    const dep = if (dispatch) |d|
        b.dependency("utf", .{ .target = target, .optimize = optimize, .dispatch = d })
    else
        b.dependency("utf", .{ .target = target, .optimize = optimize });
    const utf = dep.module("utf");
    const strip = b.option(bool, "strip", "Strip the size programs (default true)") orelse true;
    const enc = b.createModule(.{ .root_source_file = b.path("enc_codec.zig"), .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{ .name = "bmpb", .root_module = b.createModule(.{
        .root_source_file = b.path("bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "utf", .module = utf }, .{ .name = "enc", .module = enc } },
    }) });
    if (target.result.cpu.arch == .x86_64) b.installArtifact(exe);
    for ([_][]const u8{ "none", "utf-both", "utf-to8", "utf-from8", "enc-both", "enc-to8", "enc-from8" }) |v| {
        const opts = b.addOptions();
        opts.addOption([]const u8, "variant", v);
        const s = b.addExecutable(.{ .name = b.fmt("size-{s}", .{v}), .root_module = b.createModule(.{
            .root_source_file = b.path("size.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "utf", .module = utf },
                .{ .name = "enc", .module = enc },
                .{ .name = "options", .module = opts.createModule() },
            },
        }) });
        b.installArtifact(s);
    }
}
