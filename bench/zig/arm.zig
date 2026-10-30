//! The two Zig arms of `just bench-compare` (bench/README.md), one program
//! built twice: `bench-std` times Zig's `std.unicode` and `std.base64`, and
//! `bench-utf` times this package.
//!
//! Usage, from the repository root, with the same contract as every arm:
//!
//!     bench-<impl> bench [OP...] [FLAG...]   rows in the Go benchmark format
//!     bench-<impl> check [OP...]             one checksum line per row
//!
//! OP is validate-utf8, validate-utf8-err, utf8-to-utf16le, utf16le-to-utf8,
//! base64-encode, or base64-decode; none means all. BENCHTIME_MS (default
//! 100) is how long each row's timed loop runs. testingx times the rows:
//! `b.loop()` sizes the loop as Go's `testing.B` does, and FLAG is any of
//! its flags, such as `--cycles` for cycles and instructions per op, or
//! `--benchtime=1s`, which beats BENCHTIME_MS. Its header lines start with
//! a key and a colon; `just bench-compare` keeps only the rows.
//!
//! `bench-utf` looks for each function under the names docs/slop/plan.md
//! gives them and skips the operations whose functions are not there yet,
//! with a `# SKIP` line benchstat ignores.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;

const testingx = @import("testingx");
const utf = @import("utf");
const impl = @import("build_options").impl;

const corpus = "bench/corpus-gen";

/// What one call returns, for the checksum: validity, or the bytes written.
const Out = union(enum) { valid: bool, len: usize };

const Fn = fn ([]const u8, []u8) Out;

const Op = struct {
    /// The command-line name.
    arg: []const u8,
    /// The benchmark name, before the slash and the input's name.
    row: []const u8,
    /// The corpus directory the inputs come from.
    dir: []const u8,
    /// The output buffer's size for an input of `n` bytes.
    out_len: fn (usize) usize,
    /// The function to time, or null when this arm lacks it.
    run: ?Fn,
    /// Why `run` is null.
    missing: []const u8 = "",
};

fn none(_: usize) usize {
    return 0;
}
fn twice(n: usize) usize {
    return 2 * n + 2;
}
fn thrice(n: usize) usize {
    return 3 * n + 3;
}
fn encoded(n: usize) usize {
    return (n + 2) / 3 * 4;
}
fn decoded(n: usize) usize {
    return n / 4 * 3 + 3;
}

const ops = [_]Op{
    .{
        .arg = "validate-utf8",
        .row = "ValidateUtf8",
        .dir = "utf8",
        .out_len = none,
        .run = Impl.validate_utf8,
        .missing = Impl.missing_validate,
    },
    .{
        .arg = "validate-utf8-err",
        .row = "ValidateUtf8Err",
        .dir = "utf8-err",
        .out_len = none,
        .run = Impl.validate_utf8_err,
        .missing = Impl.missing_validate_err,
    },
    .{
        .arg = "utf8-to-utf16le",
        .row = "Utf8ToUtf16le",
        .dir = "utf8",
        .out_len = twice,
        .run = Impl.utf8_to_utf16le,
        .missing = Impl.missing_utf8_to_utf16le,
    },
    .{
        .arg = "utf16le-to-utf8",
        .row = "Utf16leToUtf8",
        .dir = "utf16le",
        .out_len = thrice,
        .run = Impl.utf16le_to_utf8,
        .missing = Impl.missing_utf16le_to_utf8,
    },
    .{
        .arg = "base64-encode",
        .row = "Base64Encode",
        .dir = "binary",
        .out_len = encoded,
        .run = Impl.base64_encode,
        .missing = Impl.missing_base64_encode,
    },
    .{
        .arg = "base64-decode",
        .row = "Base64Decode",
        .dir = "base64",
        .out_len = decoded,
        .run = Impl.base64_decode,
        .missing = Impl.missing_base64_decode,
    },
};
const Impl = if (mem.eql(u8, impl, "std")) Std else Utf;

fn units(bytes: []const u8) []const u16 {
    return @alignCast(mem.bytesAsSlice(u16, bytes));
}
fn unitsMut(bytes: []u8) []u16 {
    return @alignCast(mem.bytesAsSlice(u16, bytes));
}

/// Zig's standard library. `utf8ValidateSlice` has no error position, so
/// both validation operations time it.
const Std = struct {
    const missing_validate = "";
    const missing_validate_err = "";
    const missing_utf8_to_utf16le = "";
    const missing_utf16le_to_utf8 = "";
    const missing_base64_encode = "";
    const missing_base64_decode = "";

    const validate_utf8: ?Fn = validateUtf8;
    const validate_utf8_err: ?Fn = validateUtf8;
    const utf8_to_utf16le: ?Fn = utf8ToUtf16le;
    const utf16le_to_utf8: ?Fn = utf16leToUtf8;
    const base64_encode: ?Fn = base64Encode;
    const base64_decode: ?Fn = base64Decode;

    fn validateUtf8(in: []const u8, _: []u8) Out {
        return .{ .valid = std.unicode.utf8ValidateSlice(in) };
    }
    fn utf8ToUtf16le(in: []const u8, out: []u8) Out {
        const n = std.unicode.utf8ToUtf16Le(unitsMut(out), in) catch return .{ .valid = false };
        return .{ .len = 2 * n };
    }
    fn utf16leToUtf8(in: []const u8, out: []u8) Out {
        const n = std.unicode.utf16LeToUtf8(out, units(in)) catch return .{ .valid = false };
        return .{ .len = n };
    }
    fn base64Encode(in: []const u8, out: []u8) Out {
        return .{ .len = std.base64.standard.Encoder.encode(out, in).len };
    }
    fn base64Decode(in: []const u8, out: []u8) Out {
        const decoder = std.base64.standard.Decoder;
        const n = decoder.calcSizeForSlice(in) catch return .{ .valid = false };
        decoder.decode(out[0..n], in) catch return .{ .valid = false };
        return .{ .len = n };
    }
};

/// This package, under the names docs/slop/plan.md gives its API. A
/// function that is not there yet is null, and its operation is skipped.
const Utf = struct {
    fn has(comptime ns: []const u8, comptime name: []const u8) bool {
        if (!@hasDecl(utf, ns)) return false;
        return @hasDecl(@field(utf, ns), name);
    }

    fn why(comptime ns: []const u8, comptime name: []const u8) []const u8 {
        return if (has(ns, name)) "" else "utf." ++ ns ++ "." ++ name ++ " does not exist yet";
    }

    /// The options type of a base64 function, its third parameter.
    fn OptionsOf(comptime f: anytype) type {
        return @typeInfo(@TypeOf(f)).@"fn".params[2].type.?;
    }

    /// A default options value, when the options type has one.
    fn defaultOptions(comptime f: anytype) ?OptionsOf(f) {
        inline for (@typeInfo(OptionsOf(f)).@"struct".fields) |field| {
            if (field.default_value_ptr == null) return null;
        }
        return .{};
    }

    fn withOptions(comptime name: []const u8) bool {
        return has("base64", name) and defaultOptions(@field(utf.base64, name)) != null;
    }

    fn whyOptions(comptime name: []const u8) []const u8 {
        if (!has("base64", name)) return why("base64", name);
        if (!withOptions(name)) return "utf.base64." ++ name ++ "'s options have no default";
        return "";
    }

    const missing_validate = why("validate", "utf8");
    const missing_validate_err = why("validate", "utf8WithErrors");
    const missing_utf8_to_utf16le = why("convert", "utf8ToUtf16le");
    const missing_utf16le_to_utf8 = why("convert", "utf16leToUtf8");
    const missing_base64_encode = whyOptions("encode");
    const missing_base64_decode = whyOptions("decode");

    const validate_utf8: ?Fn = if (has("validate", "utf8")) struct {
        fn f(in: []const u8, _: []u8) Out {
            return .{ .valid = utf.validate.utf8(in) };
        }
    }.f else null;

    const validate_utf8_err: ?Fn = if (has("validate", "utf8WithErrors")) struct {
        fn f(in: []const u8, _: []u8) Out {
            return .{ .valid = utf.validate.utf8WithErrors(in).err == .none };
        }
    }.f else null;

    const utf8_to_utf16le: ?Fn = if (has("convert", "utf8ToUtf16le")) struct {
        fn f(in: []const u8, out: []u8) Out {
            const r = utf.convert.utf8ToUtf16le(in, unitsMut(out));
            if (r.err != .none) return .{ .valid = false };
            return .{ .len = 2 * r.count };
        }
    }.f else null;

    const utf16le_to_utf8: ?Fn = if (has("convert", "utf16leToUtf8")) struct {
        fn f(in: []const u8, out: []u8) Out {
            const r = utf.convert.utf16leToUtf8(units(in), out);
            if (r.err != .none) return .{ .valid = false };
            return .{ .len = r.count };
        }
    }.f else null;

    const base64_encode: ?Fn = if (withOptions("encode")) struct {
        fn f(in: []const u8, out: []u8) Out {
            return .{ .len = utf.base64.encode(out, in, comptime defaultOptions(utf.base64.encode).?) };
        }
    }.f else null;

    const base64_decode: ?Fn = if (withOptions("decode")) struct {
        fn f(in: []const u8, out: []u8) Out {
            const r = utf.base64.decode(out, in, comptime defaultOptions(utf.base64.decode).?);
            if (r.err != .none) return .{ .valid = false };
            return .{ .len = r.count };
        }
    }.f else null;
};

const Input = struct {
    name: []const u8,
    data: []align(16) const u8,
    /// The output buffer, sized for this input and allocated before timing.
    out: []align(16) u8,
};

/// Every file in `bench/corpus-gen/<op.dir>`, smallest first, then by name.
fn load(comptime op: Op, io: Io, gpa: mem.Allocator) ![]Input {
    const path = corpus ++ "/" ++ op.dir;
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        std.debug.print("bench-{s}: open {s}: {t} (run `just bench-corpus`)\n", .{ impl, path, err });
        return err;
    };
    defer dir.close(io);
    var list: std.ArrayList(Input) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const data = try dir.readFileAllocOptions(io, entry.name, gpa, .unlimited, .@"16", null);
        const out = try gpa.alignedAlloc(u8, .@"16", op.out_len(data.len));
        try list.append(gpa, .{ .name = try gpa.dupe(u8, entry.name), .data = data, .out = out });
    }
    mem.sort(Input, list.items, {}, struct {
        fn lessThan(_: void, a: Input, b: Input) bool {
            if (a.data.len != b.data.len) return a.data.len < b.data.len;
            return mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return list.items;
}

fn fnv1a(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| h = (h ^ b) *% 0x100000001b3;
    return h;
}

/// Each operation's inputs, loaded before testingx runs anything.
var inputs: [ops.len][]const Input = @splat(&.{});
/// The input the running row times. `b.run` runs its function before it
/// returns, so setting this first stands in for a closure.
var current: Input = undefined;

/// The benchmark for one operation: a row per input, as a sub-benchmark.
fn opBenchmark(comptime i: usize) testingx.Function {
    const f = ops[i].run.?;
    return struct {
        fn run(b: *testingx.B) !void {
            for (inputs[i]) |in| {
                current = in;
                _ = try b.run(in.name, row);
            }
        }

        fn row(b: *testingx.B) !void {
            const in = current.data;
            const out = current.out;
            while (try b.loop()) {
                // The input escapes every iteration, so no call is hoisted.
                mem.doNotOptimizeAway(in.ptr);
                mem.doNotOptimizeAway(f(in, out));
            }
            b.setBytes(@intCast(in.len));
        }
    }.run;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 2 or !(mem.eql(u8, args[1], "bench") or mem.eql(u8, args[1], "check"))) {
        std.debug.print("usage: bench-{s} bench|check [OP...] [testingx flags]\n", .{impl});
        return 2;
    }
    const check = mem.eql(u8, args[1], "check");
    // Operations, then testingx's flags, which start with a dash.
    var wanted: std.ArrayList([]const u8) = .empty;
    var flags: std.ArrayList([]const u8) = .empty;
    try flags.append(gpa, args[0]);
    for (args[2..]) |arg| {
        if (mem.startsWith(u8, arg, "-")) {
            try flags.append(gpa, arg);
            continue;
        }
        var known = false;
        inline for (ops) |op| known = known or mem.eql(u8, op.arg, arg);
        if (!known) {
            std.debug.print("bench-{s}: unknown operation {s}\n", .{ impl, arg });
            return 2;
        }
        try wanted.append(gpa, arg);
    }

    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buf);
    const w = &stdout.interface;

    var defaults: testingx.Options = .{};
    if (init.environ_map.get("BENCHTIME_MS")) |v| {
        defaults.benchtime = .{ .duration_ns = try std.fmt.parseInt(u64, v, 10) * std.time.ns_per_ms };
    } else {
        defaults.benchtime = .{ .duration_ns = 100 * std.time.ns_per_ms };
    }
    var flag_args: testingx.bench.SliceArgs = .{ .args = flags.items };
    var suite: testingx.B = .init(gpa, io, try .parse(gpa, &flag_args, defaults));
    defer suite.deinit();

    inline for (ops, 0..) |op, i| {
        const selected = wanted.items.len == 0 or for (wanted.items) |arg| {
            if (mem.eql(u8, op.arg, arg)) break true;
        } else false;
        if (selected) {
            if (op.run) |f| {
                inputs[i] = try load(op, io, gpa);
                if (check) {
                    for (inputs[i]) |in| switch (f(in.data, in.out)) {
                        .valid => |v| try w.print("{s}/{s}\tvalid={}\n", .{ op.row, in.name, v }),
                        .len => |n| try w.print("{s}/{s}\tlen={d} fnv={x:0>16}\n", .{
                            op.row, in.name, n, fnv1a(in.out[0..n]),
                        }),
                    };
                } else {
                    try suite.add(op.row, opBenchmark(i));
                }
            } else {
                try w.print("# SKIP Benchmark{s}: {s}\n", .{ op.row, op.missing });
            }
        }
    }
    try w.flush();
    if (check) return 0;
    return if (try suite.finish()) 0 else 1;
}
