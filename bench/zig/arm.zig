//! The two Zig arms of `just bench-compare` (bench/README.md), one program
//! built twice: `bench-std` times Zig's `std.unicode` and `std.base64`, and
//! `bench-utf` times this package.
//!
//! Usage, from the repository root, with the same contract as every arm:
//!
//!     bench-<impl> bench [OP...] [FLAG...]   rows in the Go benchmark format
//!     bench-<impl> check [OP...]             one checksum line per row
//!     bench-<impl> serve                     one row per request line on stdin
//!
//! OP is a name from bench/ops.tsv, which also gives each operation's row
//! name, corpus directory, and output size; none means all. BENCHTIME_MS
//! (default 100) is how long each row's timed loop runs. testingx times the
//! rows: `b.loop()` sizes the loop as Go's `testing.B` does, and FLAG is any
//! of its flags, such as `--cycles` for cycles and instructions per op, or
//! `--benchtime=1s`, which beats BENCHTIME_MS. Its header lines start with
//! a key and a colon; `just bench-compare` keeps only the rows. A `serve`
//! request is `OP INPUT N`: time the row N iterations, after one untimed
//! call, or for BENCHTIME_MS when N is 0. Every input starts
//! BENCH_IN_OFFSET bytes (default 0) past a page boundary and its output
//! BENCH_OUT_OFFSET bytes (default 2048) past another, as in every arm.
//!
//! `bench-utf` looks for each function under the name docs/slop/plan.md
//! gives it and skips an operation whose function is not there yet, with a
//! `# SKIP` line benchstat ignores; `bench-std` skips the operations Zig's
//! std has no function for.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;

const testingx = @import("testingx");
const utf = @import("utf");
const impl = @import("build_options").impl;

const corpus = "bench/corpus-gen";

/// What one call returns, for the checksum: validity, the bytes written,
/// or a count. A struct whose fields are computed, not a union whose
/// variant is chosen: choosing between two built results made LLVM store
/// the fields narrow and copy them out wide, which stalls store-to-load
/// forwarding, about 4 ns a checked call on 16 bytes
/// (docs/slop/results/convert-20261031.md).
const Out = struct {
    /// Validity as 0 or 1, the bytes written, or the count.
    n: usize,
    kind: Kind,

    const Kind = enum(u8) { valid, len, count };

    fn valid(v: bool) Out {
        return .{ .n = @intFromBool(v), .kind = .valid };
    }

    /// `n` as a `kind` when `ok`, and invalid input otherwise.
    fn checked(comptime kind: Kind, ok: bool, n: usize) Out {
        return .{ .n = if (ok) n else 0, .kind = if (ok) kind else .valid };
    }
};

/// Whether an error union holds a value.
fn succeeded(r: anytype) bool {
    return if (r) |_| true else |_| false;
}

const Fn = fn ([]align(4) const u8, []align(4) u8) Out;

/// This arm's function for an operation in bench/ops.tsv, or null and why.
const Entry = struct {
    arg: []const u8,
    run: ?Fn,
    missing: []const u8 = "",
};

const entries: []const Entry = if (mem.eql(u8, impl, "std")) Std.entries else Utf.entries;

/// The input as code units of the slice type `T`.
fn cast(comptime T: type, bytes: anytype) T {
    return mem.bytesAsSlice(@typeInfo(T).pointer.child, bytes);
}

/// Zig's standard library, where it has a function for the operation.
/// `utf8ValidateSlice` has no error position, so both UTF-8 validation
/// operations time it. The std decoders reject a missing pad and nonzero
/// bits past the last byte, so `standard.Decoder` does the strict
/// decode's work in `base64-decode` too. The length functions validate as
/// they count, except `calcWtf8Len`.
const Std = struct {
    const entries: []const Entry = &.{
        .{ .arg = "validate-utf8", .run = validateUtf8 },
        .{ .arg = "validate-utf8-err", .run = validateUtf8 },
        .{ .arg = "utf8-to-utf16le", .run = utf8ToUtf16le },
        .{ .arg = "utf16le-to-utf8", .run = utf16leToUtf8 },
        .{ .arg = "utf16-from-utf8", .run = utf16FromUtf8 },
        .{ .arg = "utf8-from-utf16le", .run = utf8FromUtf16le },
        .{ .arg = "count-utf8", .run = countUtf8 },
        .{ .arg = "count-utf16le", .run = countUtf16le },
        .{ .arg = "base64-encode", .run = encoder(std.base64.standard) },
        .{ .arg = "base64-encode-url", .run = encoder(std.base64.url_safe_no_pad) },
        .{ .arg = "base64-decode", .run = decoder(std.base64.standard) },
        .{ .arg = "base64-decode-url", .run = decoder(std.base64.url_safe_no_pad) },
        .{ .arg = "base64-decode-strict", .run = decoder(std.base64.standard) },
        .{ .arg = "base64-decode-mime", .run = base64DecodeMime },
    };

    fn validateUtf8(in: []align(4) const u8, _: []align(4) u8) Out {
        return .valid(std.unicode.utf8ValidateSlice(in));
    }
    fn utf8ToUtf16le(in: []align(4) const u8, out: []align(4) u8) Out {
        const r = std.unicode.utf8ToUtf16Le(cast([]u16, out), in);
        return .checked(.len, succeeded(r), 2 * (r catch 0));
    }
    fn utf16leToUtf8(in: []align(4) const u8, out: []align(4) u8) Out {
        const r = std.unicode.utf16LeToUtf8(out, cast([]const u16, in));
        return .checked(.len, succeeded(r), r catch 0);
    }
    fn utf16FromUtf8(in: []align(4) const u8, _: []align(4) u8) Out {
        const r = std.unicode.calcUtf16LeLen(in);
        return .checked(.count, succeeded(r), r catch 0);
    }
    fn utf8FromUtf16le(in: []align(4) const u8, _: []align(4) u8) Out {
        return .checked(.count, true, std.unicode.calcWtf8Len(cast([]const u16, in)));
    }
    fn countUtf8(in: []align(4) const u8, _: []align(4) u8) Out {
        const r = std.unicode.utf8CountCodepoints(in);
        return .checked(.count, succeeded(r), r catch 0);
    }
    fn countUtf16le(in: []align(4) const u8, _: []align(4) u8) Out {
        const r = std.unicode.utf16CountCodepoints(cast([]const u16, in));
        return .checked(.count, succeeded(r), r catch 0);
    }
    fn encoder(comptime codecs: std.base64.Codecs) Fn {
        return struct {
            fn f(in: []align(4) const u8, out: []align(4) u8) Out {
                return .checked(.len, true, codecs.Encoder.encode(out, in).len);
            }
        }.f;
    }
    fn decoder(comptime codecs: std.base64.Codecs) Fn {
        return struct {
            fn f(in: []align(4) const u8, out: []align(4) u8) Out {
                const size = codecs.Decoder.calcSizeForSlice(in);
                const n = size catch 0;
                return .checked(.len, succeeded(size) and succeeded(codecs.Decoder.decode(out[0..n], in)), n);
            }
        }.f;
    }
    /// Skips the ASCII whitespace WHATWG's forgiving-base64 does, as
    /// simdutf's decoder does.
    const mime = std.base64.standard.decoderWithIgnore(" \t\n\x0c\r");
    fn base64DecodeMime(in: []align(4) const u8, out: []align(4) u8) Out {
        const r = mime.decode(out, in);
        return .checked(.len, succeeded(r), r catch 0);
    }
};

/// This package, under the names docs/slop/plan.md gives its API. A
/// function that is not there yet is null, and its operation is skipped.
/// One under another signature, or options without a field an operation
/// sets, is a compile error here.
const Utf = struct {
    const EnumLiteral = @TypeOf(.enum_literal);

    /// A base64 function's options, those an operation sets.
    const Options = struct {
        alphabet: ?EnumLiteral = null,
        padding: ?bool = null,
        last_chunk: ?EnumLiteral = null,
    };

    const Api = struct {
        arg: []const u8,
        ns: []const u8,
        name: []const u8,
        options: Options = .{},
    };

    const api = [_]Api{
        .{ .arg = "validate-ascii", .ns = "validate", .name = "ascii" },
        .{ .arg = "validate-ascii-err", .ns = "validate", .name = "asciiWithErrors" },
        .{ .arg = "validate-utf8", .ns = "validate", .name = "utf8" },
        .{ .arg = "validate-utf8-err", .ns = "validate", .name = "utf8WithErrors" },
        .{ .arg = "validate-utf16le", .ns = "validate", .name = "utf16le" },
        .{ .arg = "validate-utf16le-err", .ns = "validate", .name = "utf16leWithErrors" },
        .{ .arg = "validate-utf16be", .ns = "validate", .name = "utf16be" },
        .{ .arg = "validate-utf16be-err", .ns = "validate", .name = "utf16beWithErrors" },
        .{ .arg = "validate-utf32", .ns = "validate", .name = "utf32" },
        .{ .arg = "validate-utf32-err", .ns = "validate", .name = "utf32WithErrors" },
    } ++ conversions() ++ [_]Api{
        .{ .arg = "utf16-from-utf8", .ns = "length", .name = "utf16FromUtf8" },
        .{ .arg = "utf16-from-utf32", .ns = "length", .name = "utf16FromUtf32" },
        .{ .arg = "utf8-from-utf16le", .ns = "length", .name = "utf8FromUtf16le" },
        .{ .arg = "utf8-from-utf16be", .ns = "length", .name = "utf8FromUtf16be" },
        .{ .arg = "utf8-from-utf32", .ns = "length", .name = "utf8FromUtf32" },
        .{ .arg = "utf8-from-latin1", .ns = "length", .name = "utf8FromLatin1" },
        .{ .arg = "count-utf8", .ns = "length", .name = "countUtf8" },
        .{ .arg = "count-utf16le", .ns = "length", .name = "countUtf16le" },
        .{ .arg = "count-utf16be", .ns = "length", .name = "countUtf16be" },
        .{ .arg = "base64-encode", .ns = "base64", .name = "encode" },
        .{
            .arg = "base64-encode-url",
            .ns = "base64",
            .name = "encode",
            .options = .{ .alphabet = .url, .padding = false },
        },
        .{ .arg = "base64-decode", .ns = "base64", .name = "decode" },
        .{
            .arg = "base64-decode-url",
            .ns = "base64",
            .name = "decode",
            .options = .{ .alphabet = .url },
        },
        .{
            .arg = "base64-decode-strict",
            .ns = "base64",
            .name = "decode",
            .options = .{ .last_chunk = .strict },
        },
        .{
            .arg = "base64-decode-partial",
            .ns = "base64",
            .name = "decode",
            .options = .{ .last_chunk = .stop_before_partial },
        },
        .{ .arg = "base64-decode-mime", .ns = "base64", .name = "decode" },
    };

    /// Every conversion, checked and valid: `utf8-to-utf16le` is
    /// `convert.utf8ToUtf16le`, `valid-utf8-to-utf16le` is
    /// `convert.validUtf8ToUtf16le`.
    fn conversions() [40]Api {
        // Each form's name in an operation, and in a function name.
        const forms = [_][2][]const u8{
            .{ "utf8", "Utf8" },   .{ "utf16le", "Utf16le" }, .{ "utf16be", "Utf16be" },
            .{ "utf32", "Utf32" }, .{ "latin1", "Latin1" },
        };
        var list: [40]Api = undefined;
        var n: usize = 0;
        for (forms) |src| {
            for (forms) |dst| {
                if (mem.eql(u8, src[0], dst[0])) continue;
                const arg = src[0] ++ "-to-" ++ dst[0];
                list[n] = .{ .arg = arg, .ns = "convert", .name = src[0] ++ "To" ++ dst[1] };
                list[n + 1] = .{ .arg = "valid-" ++ arg, .ns = "convert", .name = "valid" ++ src[1] ++ "To" ++ dst[1] };
                n += 2;
            }
        }
        return list;
    }

    const entries: []const Entry = &table;
    const table = blk: {
        var list: [api.len]Entry = undefined;
        for (&list, api) |*e, a| {
            const exists = @hasDecl(utf, a.ns) and @hasDecl(@field(utf, a.ns), a.name);
            e.* = if (exists)
                .{ .arg = a.arg, .run = wrap(@field(@field(utf, a.ns), a.name), a.options) }
            else
                .{ .arg = a.arg, .run = null, .missing = "utf." ++ a.ns ++ "." ++ a.name ++ " does not exist yet" };
        }
        break :blk list;
    };

    /// The options type `T` with the fields `options` sets, and the rest at
    /// their defaults.
    fn optionsValue(comptime T: type, comptime options: Options) T {
        var o: T = .{};
        if (options.alphabet) |v| o.alphabet = v;
        if (options.padding) |v| o.padding = v;
        if (options.last_chunk) |v| o.last_chunk = v;
        return o;
    }

    /// `f` as a `Fn`, by its signature: `(src) bool`, `(src) Result`, or
    /// `(src) usize` validates or counts; `(src, dst) Result` or
    /// `(src, dst) usize` converts; `(dst, src, options)` is base64.
    fn wrap(comptime f: anytype, comptime options: Options) Fn {
        const params = @typeInfo(@TypeOf(f)).@"fn".param_types;
        return struct {
            fn run(in: []align(4) const u8, out: []align(4) u8) Out {
                if (params.len == 3) {
                    return written(u8, f(out, in, comptime optionsValue(params[2].?, options)));
                }
                const src = cast(params[0].?, in);
                if (params.len == 2) {
                    const Dst = params[1].?;
                    return written(@typeInfo(Dst).pointer.child, f(src, cast(Dst, out)));
                }
                const r = f(src);
                return switch (@TypeOf(r)) {
                    bool => .valid(r),
                    utf.Result => .valid(r.err == .none),
                    usize => .checked(.count, true, r),
                    else => @compileError("unexpected return type"),
                };
            }

            fn written(comptime Unit: type, r: anytype) Out {
                return switch (@TypeOf(r)) {
                    usize => .checked(.len, true, r * @sizeOf(Unit)),
                    utf.Result => .checked(.len, r.err == .none, r.count * @sizeOf(Unit)),
                    else => @compileError("unexpected return type"),
                };
            }
        }.run;
    }
};

/// An operation from bench/ops.tsv.
const Op = struct {
    arg: []const u8,
    row: []const u8,
    dir: []const u8,
    /// Output bytes per input byte, num / den.
    num: usize,
    den: usize,

    fn outLen(op: Op, n: usize) usize {
        return if (op.num == 0) 0 else n * op.num / op.den + 64;
    }
};

fn readOps(io: Io, gpa: mem.Allocator) ![]Op {
    const text = Io.Dir.cwd().readFileAlloc(io, "bench/ops.tsv", gpa, .unlimited) catch |err| {
        std.debug.print("bench-{s}: open bench/ops.tsv: {t} (run from the repository root)\n", .{ impl, err });
        return err;
    };
    var list: std.ArrayList(Op) = .empty;
    var lines = mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = mem.splitScalar(u8, line, '\t');
        var op: Op = .{ .arg = fields.next().?, .row = fields.next().?, .dir = fields.next().?, .num = 0, .den = 1 };
        var out = mem.splitScalar(u8, fields.next().?, '/');
        op.num = try std.fmt.parseInt(usize, out.next().?, 10);
        if (out.next()) |den| op.den = try std.fmt.parseInt(usize, den, 10);
        try list.append(gpa, op);
    }
    inline for (entries) |e| {
        for (list.items) |op| {
            if (mem.eql(u8, op.arg, e.arg)) break;
        } else {
            std.debug.print("bench-{s}: operation {s} is not in bench/ops.tsv\n", .{ impl, e.arg });
            return error.UnknownOperation;
        }
    }
    return list.items;
}

/// Where every arm puts its buffers: the input `in_offset` bytes past a page
/// boundary, from BENCH_IN_OFFSET, and its output `out_offset` past another,
/// from BENCH_OUT_OFFSET. The defaults align the input to a page and keep
/// the output 2 KiB from it modulo 4 KiB, so a store does not alias a
/// nearby load.
var in_offset: usize = 0;
var out_offset: usize = 2048;

fn offsetEnv(environ: *const std.process.Environ.Map, name: []const u8, default: usize) !usize {
    const v = environ.get(name) orelse return default;
    const off = try std.fmt.parseInt(usize, v, 10);
    if (off >= 4096 or off % 4 != 0) {
        std.debug.print("bench-{s}: {s} must be a multiple of 4 under 4096\n", .{ impl, name });
        return error.BadOffset;
    }
    return off;
}

/// `len` bytes `off` bytes past a page boundary, in a mapping of their own:
/// zeroed, and resident only once written.
const Placed = struct {
    mapping: []align(page) u8,
    bytes: []align(4) u8,

    const page = 4096;

    /// Raw calls: `alignedAlloc` and `free` fill the memory with
    /// `undefined` in a safe build, which made every output page resident
    /// in `check`.
    fn init(len: usize, off: usize) !Placed {
        const size = (off + len + page) / page * page;
        const ptr = std.heap.page_allocator.rawAlloc(size, .fromByteUnits(page), @returnAddress()) orelse
            return error.OutOfMemory;
        const mapping: []align(page) u8 = @alignCast(ptr[0..size]);
        return .{ .mapping = mapping, .bytes = @alignCast(mapping[off..][0..len]) };
    }

    fn deinit(p: Placed) void {
        std.heap.page_allocator.rawFree(p.mapping, .fromByteUnits(page), @returnAddress());
    }

    /// Writes every page of the mapping but the data's bytes: a masked load
    /// whose masked-off lanes reach a page nothing has touched takes a
    /// microcode assist on every call.
    fn writeRest(p: Placed) void {
        const off = @intFromPtr(p.bytes.ptr) - @intFromPtr(p.mapping.ptr);
        @memset(p.mapping[0..off], 0);
        @memset(p.mapping[off + p.bytes.len ..], 0);
    }
};

const Input = struct {
    name: []const u8,
    data: Placed,
    /// The output buffer's size.
    out_len: usize,

    /// A fresh output buffer, unwritten, so that in `check` only the pages
    /// written count in RSS. Each row allocates its own before it times
    /// anything and frees it after, as the other arms do.
    fn output(in: Input) !Placed {
        return .init(in.out_len, out_offset);
    }
};

/// Every file in `bench/corpus-gen/<op.dir>`, smallest first, then by name.
fn load(op: Op, io: Io, gpa: mem.Allocator) ![]Input {
    const path = try gpa.print(corpus ++ "/{s}", .{op.dir});
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        std.debug.print("bench-{s}: open {s}: {t} (run `just bench-corpus`)\n", .{ impl, path, err });
        return err;
    };
    defer dir.close(io);
    var list: std.ArrayList(Input) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const stat = try dir.statFile(io, entry.name, .{});
        const data: Placed = try .init(@intCast(stat.size), in_offset);
        if ((try dir.readFile(io, entry.name, data.bytes)).len != data.bytes.len) return error.ShortRead;
        data.writeRest();
        const name = try gpa.dupe(u8, entry.name);
        try list.append(gpa, .{ .name = name, .data = data, .out_len = op.outLen(data.bytes.len) });
    }
    mem.sort(Input, list.items, {}, struct {
        fn lessThan(_: void, a: Input, b: Input) bool {
            if (a.data.bytes.len != b.data.bytes.len) return a.data.bytes.len < b.data.bytes.len;
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

/// Each entry's inputs, loaded before testingx runs anything.
var inputs: [entries.len][]const Input = @splat(&.{});
/// The input the running row times, and its output buffer. `b.run` runs
/// its function before it returns, so setting these first stands in for a
/// closure.
var current: []align(4) const u8 = undefined;
var current_out: []align(4) u8 = undefined;

/// The benchmark for one entry: a row per input, as a sub-benchmark.
fn opBenchmark(comptime i: usize) testingx.Function {
    return struct {
        fn run(b: *testingx.B) !void {
            for (inputs[i]) |in| {
                const out = try in.output();
                defer out.deinit();
                // Fault every page in before timing: a masked store that
                // overhangs into a page nothing has written takes a
                // microcode assist on every call.
                @memset(out.mapping, 0);
                current = in.data.bytes;
                current_out = out.bytes;
                _ = try b.run(in.name, rowBenchmark(i));
            }
        }
    }.run;
}

/// The timed loop of one entry, on `current` and `current_out`.
fn rowBenchmark(comptime i: usize) testingx.Function {
    const f = entries[i].run.?;
    return struct {
        fn row(b: *testingx.B) !void {
            const in = current;
            const out = current_out;
            while (try b.loop()) {
                // The input escapes every iteration, so no call is hoisted,
                // and the call stays out of line, as a C call to simdutf
                // is, so the loop does not keep the kernel's constants.
                mem.doNotOptimizeAway(in.ptr);
                // One word of the result, not the whole struct: reading it
                // back whole after the callee's narrow stores stalls
                // store-to-load forwarding, about 6 ns a call.
                mem.doNotOptimizeAway(@call(.never_inline, f, .{ in, out }).n);
            }
            b.setBytes(@intCast(in.len));
        }
    }.row;
}

/// Each entry's operation, timed loop, and function, or null where it has
/// none, for lookups at run time.
const entry_args = blk: {
    var list: [entries.len][]const u8 = undefined;
    for (&list, entries) |*a, e| a.* = e.arg;
    break :blk list;
};
const rows = blk: {
    var list: [entries.len]?testingx.Function = undefined;
    for (&list, entries, 0..) |*r, e, i| r.* = if (e.run != null) rowBenchmark(i) else null;
    break :blk list;
};
const calls = blk: {
    var list: [entries.len]?*const Fn = undefined;
    for (&list, entries) |*c, e| c.* = if (e.run) |f| &f else null;
    break :blk list;
};

/// `serve`: one row per request line, `OP INPUT N`, until stdin ends. The
/// requested operation's inputs and outputs stay loaded until another is
/// requested.
fn serve(io: Io, gpa: mem.Allocator, ops: []const Op, defaults: testingx.Options, w: *Io.Writer) !void {
    var buf: [4096]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(io, &buf);
    var loaded: ?usize = null;
    var ins: []Input = &.{};
    var outs: std.ArrayList(Placed) = .empty;
    while (try stdin.interface.takeDelimiter('\n')) |line| {
        var fields = mem.tokenizeScalar(u8, line, ' ');
        const arg = fields.next() orelse return error.BadRequest;
        const name = fields.next() orelse return error.BadRequest;
        const n = try std.fmt.parseInt(u64, fields.next() orelse return error.BadRequest, 10);
        const j = for (ops, 0..) |op, j| {
            if (mem.eql(u8, op.arg, arg)) break j;
        } else return error.UnknownOperation;
        const k = for (entry_args, 0..) |a, k| {
            if (mem.eql(u8, a, arg)) break k;
        } else return error.UnknownOperation;
        const row = rows[k] orelse return error.UnknownOperation;
        if (loaded != j) {
            for (ins, outs.items) |in, out| {
                in.data.deinit();
                out.deinit();
            }
            outs.clearRetainingCapacity();
            ins = try load(ops[j], io, gpa);
            for (ins) |in| {
                const out = try in.output();
                @memset(out.mapping, 0);
                try outs.append(gpa, out);
            }
            loaded = j;
        }
        const i = for (ins, 0..) |in, i| {
            if (mem.eql(u8, in.name, name)) break i;
        } else return error.UnknownInput;
        current = ins[i].data.bytes;
        current_out = outs.items[i].bytes;
        var options = defaults;
        if (n > 0) {
            _ = calls[k].?(current, current_out);
            options.benchtime = .{ .count = n };
        }
        var r = try testingx.benchmark(std.heap.smp_allocator, io, row, options);
        defer r.deinit(std.heap.smp_allocator);
        const ns: f64 = @floatFromInt(r.t_ns);
        try w.print("Benchmark{s}/{s}\t{d}\t{d:.2} ns/op\t{d:.2} MB/s\n", .{
            ops[j].row, name, r.n, ns / @as(f64, @floatFromInt(r.n)), r.mbPerSec(),
        });
        try w.flush();
    }
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 2 or !(mem.eql(u8, args[1], "bench") or mem.eql(u8, args[1], "check") or
        mem.eql(u8, args[1], "serve")))
    {
        std.debug.print("usage: bench-{s} bench|check [OP...] [testingx flags] | serve\n", .{impl});
        return 2;
    }
    const check = mem.eql(u8, args[1], "check");
    const ops = try readOps(io, gpa);
    in_offset = try offsetEnv(init.environ_map, "BENCH_IN_OFFSET", in_offset);
    out_offset = try offsetEnv(init.environ_map, "BENCH_OUT_OFFSET", out_offset);
    // Operations, then testingx's flags, which start with a dash.
    var wanted: std.ArrayList([]const u8) = .empty;
    var flags: std.ArrayList([]const u8) = .empty;
    try flags.append(gpa, args[0]);
    for (args[2..]) |arg| {
        if (mem.startsWith(u8, arg, "-")) {
            try flags.append(gpa, arg);
            continue;
        }
        for (ops) |op| {
            if (mem.eql(u8, op.arg, arg)) break;
        } else {
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
    if (mem.eql(u8, args[1], "serve")) {
        try serve(io, gpa, ops, defaults, w);
        return 0;
    }
    var flag_args: testingx.bench.SliceArgs = .init(flags.items);
    var suite: testingx.B = .init(gpa, io, try .parse(gpa, &flag_args, defaults));
    defer suite.deinit();

    for (ops) |op| {
        const selected = wanted.items.len == 0 or for (wanted.items) |arg| {
            if (mem.eql(u8, op.arg, arg)) break true;
        } else false;
        if (!selected) continue;
        const found = inline for (entries, 0..) |e, i| {
            if (mem.eql(u8, e.arg, op.arg)) {
                if (e.run) |f| {
                    inputs[i] = try load(op, io, gpa);
                    if (check) {
                        for (inputs[i]) |in| {
                            const out = try in.output();
                            defer out.deinit();
                            const r = f(in.data.bytes, out.bytes);
                            switch (r.kind) {
                                .valid => try w.print("{s}/{s}\tvalid={}\n", .{ op.row, in.name, r.n != 0 }),
                                .count => try w.print("{s}/{s}\tcount={d}\n", .{ op.row, in.name, r.n }),
                                .len => try w.print("{s}/{s}\tlen={d} fnv={x:0>16}\n", .{
                                    op.row, in.name, r.n, fnv1a(out.bytes[0..r.n]),
                                }),
                            }
                        }
                    } else {
                        try suite.add(op.row, opBenchmark(i));
                    }
                } else {
                    try w.print("# SKIP Benchmark{s}: {s}\n", .{ op.row, e.missing });
                }
                break true;
            }
        } else false;
        if (!found) try w.print("# SKIP Benchmark{s}: Zig's std has no equivalent\n", .{op.row});
    }
    try w.flush();
    if (check) return 0;
    return if (try suite.finish()) 0 else 1;
}
