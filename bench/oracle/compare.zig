//! `just oracle [N] [SEED]`: runs random and adversarial inputs through
//! simdutf, by way of `utf-oracle`, and through every public function of
//! this package, and reports every input where the two disagree on the
//! error kind, its position, or the output (bench/README.md), with the
//! first such input of each function shrunk to a minimal one that still
//! disagrees.
//!
//!     oracle-compare [N] [SEED]
//!
//! N (default 1000000) is the number of random UTF-8 inputs; every other
//! kind of input (ASCII, UTF-16LE, UTF-16BE, UTF-32, Latin-1, base64, and
//! binary for the encoder) gets a quarter of that. SEED (default 1) fixes
//! them. ORACLE names the oracle (default zig-out/bin/utf-oracle). Run from
//! the repository root.
//!
//! The UTF-8 phase also runs a deterministic sweep: every two-byte sequence
//! after a non-ASCII lead and a grid of three- and four-byte sequences, each
//! at the start of the input and straddling a 64-byte block.
//!
//! Each check compares one of this package's functions with one simdutf
//! function, and is skipped while the function does not exist. `check`
//! picks how from the function's signature: a validator with errors, a
//! checked conversion, or a base64 decoder on the error kind, its position,
//! and the output; a `bool` validator on validity; and a valid form or a
//! length function only on inputs simdutf accepts, on the count and the
//! output, since both assume valid input. A length is compared with the
//! count of the conversion it sizes. The checked UTF-16 byte swaps are held
//! against simdutf's validation, and their output against the input with
//! its bytes swapped. simdutf has no checked conversion from Latin-1, which
//! cannot fail; the oracle sends its plain one.
//!
//! `scalar.validateUtf8` and the `std.*` checks are there to show the
//! oracle is wired right: Zig's std against simdutf on validity and output,
//! and for base64 only where std accepts, since std's decoder is stricter
//! than simdutf's forgiving one.

const std = @import("std");
const compat = @import("compat.zig");
const mem = std.mem;
const Io = std.Io;
const Random = std.Random;
const Allocator = mem.Allocator;

const utf = @import("utf");
const Oracle = @import("Oracle");

const batch_size = 20_000;
/// The mismatches printed per check; the rest are counted.
const max_printed = 8;
/// The most oracle runs spent shrinking one mismatch.
const max_shrink_runs = 400;

/// How a check holds our answer against simdutf's.
const Mode = enum {
    /// The error kind and position, or the count, and the output on
    /// success.
    checked,
    /// Validity, and the output when both accept: functions that report
    /// no position.
    validity,
    /// Only on inputs simdutf accepts: the count and the output. For the
    /// valid forms and the length functions, which assume valid input.
    simdutf_accepts,
    /// Only on inputs ours accepts: simdutf must accept too, with the same
    /// output. For std's base64 decoder, which is stricter than simdutf's.
    ours_accepts,
};

/// What one of our functions returned for one input.
const Got = struct {
    /// The error kind and position, or the count on success; null for a
    /// function that says only whether the input is valid.
    result: ?utf.Result = null,
    valid: bool,
    /// The output, compared when both sides succeed.
    out: ?[]const u8 = null,
};

const RunFn = *const fn (in: []align(16) const u8, out: []align(16) u8) Got;

const Def = struct {
    name: []const u8,
    op: Oracle.Op,
    option: u8 = 0,
    mode: Mode = .checked,
    /// The output to expect is the input with each UTF-16 code unit's bytes
    /// swapped, not the oracle's: simdutf's checked byte swap is validation,
    /// which the oracle runs, then `change_endianness_utf16`.
    swapped: bool = false,
    /// Null when the function does not exist yet.
    run: ?RunFn,
};

fn has(comptime ns: []const u8, comptime name: []const u8) bool {
    if (!@hasDecl(utf, ns)) return false;
    return @hasDecl(@field(utf, ns), name);
}

/// The input as code units of the slice type `T`.
fn cast(comptime T: type, bytes: anytype) T {
    return mem.bytesAsSlice(@typeInfo(T).pointer.child, bytes);
}

const EnumLiteral = @TypeOf(.enum_literal);

/// The base64 options a check sets; the others keep their defaults.
const Base64 = struct {
    alphabet: ?EnumLiteral = null,
    padding: ?bool = null,
    last_chunk: ?EnumLiteral = null,
};

const Extra = struct {
    base64: Base64 = .{},
    swapped: bool = false,
};

/// The options type `T` with the fields `o` sets.
fn optionsValue(comptime T: type, comptime o: Base64) T {
    var v: T = .{};
    if (o.alphabet) |a| v.alphabet = a;
    if (o.padding) |p| v.padding = p;
    if (o.last_chunk) |l| v.last_chunk = l;
    return v;
}

/// simdutf's option byte for our options `T` with the fields `o` sets:
/// decode options have a last chunk, encode options padding.
fn base64Option(comptime T: type, comptime o: Base64) u8 {
    const v = optionsValue(T, o);
    const url = v.alphabet == .url;
    if (@hasField(T, "last_chunk")) {
        return Oracle.base64Option(if (url) .url else .default, @field(Oracle.LastChunk, @tagName(v.last_chunk)));
    }
    const format: Oracle.Base64Format = if (url)
        (if (v.padding) .url_with_padding else .url)
    else
        (if (v.padding) .default else .default_no_padding);
    return compat.enumToInt(format);
}

fn base64Label(comptime o: Base64) []const u8 {
    var s: []const u8 = "";
    if (o.alphabet) |a| s = s ++ " " ++ @tagName(a);
    if (o.padding) |p| s = s ++ if (p) " padded" else " unpadded";
    if (o.last_chunk) |l| s = s ++ " " ++ @tagName(l);
    return s;
}

/// `utf.<ns>.<name>` against simdutf's `op`, compared by its signature:
/// `(src) bool` on validity; `(src) Result`, `(src, dst) Result`, and
/// `(dst, src, options)` on kind, position, and output; `(src) usize`, a
/// length, and `(src, dst) usize`, a valid form, only where simdutf
/// accepts.
fn check(comptime ns: []const u8, comptime name: []const u8, op: Oracle.Op, comptime extra: Extra) Def {
    const label = ns ++ "." ++ name ++ comptime base64Label(extra.base64);
    if (!has(ns, name)) return .{ .name = label, .op = op, .run = null };
    const f = @field(@field(utf, ns), name);
    const params = @typeInfo(@TypeOf(f)).@"fn".params;
    const run = struct {
        fn run(in: []align(16) const u8, out: []align(16) u8) Got {
            if (params.len == 3) {
                return written(u8, f(out, in, comptime optionsValue(params[2].type.?, extra.base64)), out);
            }
            const src = cast(params[0].type.?, in);
            if (params.len == 2) {
                const dst = cast(params[1].type.?, out);
                return written(@typeInfo(@TypeOf(dst)).pointer.child, f(src, dst), out);
            }
            const r = f(src);
            return switch (@TypeOf(r)) {
                bool => .{ .valid = r },
                utf.Result => .{ .result = r, .valid = r.err == .none },
                usize => .{ .result = .ok(r), .valid = true },
                else => @compileError("unexpected return type"),
            };
        }

        fn written(comptime Unit: type, r: anytype, out: []u8) Got {
            const res: utf.Result = if (@TypeOf(r) == usize) .ok(r) else r;
            const ok = res.err == .none;
            return .{ .result = res, .valid = ok, .out = if (ok) out[0 .. res.count * @sizeOf(Unit)] else null };
        }
    }.run;
    return .{
        .name = label,
        .op = op,
        .option = if (params.len == 3) base64Option(params[2].type.?, extra.base64) else 0,
        .mode = switch (@typeInfo(@TypeOf(f)).@"fn".return_type.?) {
            bool => .validity,
            usize => if (params.len < 3) .simdutf_accepts else .checked,
            else => .checked,
        },
        .swapped = extra.swapped,
        .run = run,
    };
}

const utf8_defs = [_]Def{
    .{
        .name = "scalar.validateUtf8",
        .op = .validate_utf8,
        .run = struct {
            fn f(in: []align(16) const u8, _: []align(16) u8) Got {
                const r = utf.scalar.validateUtf8(in);
                return .{ .result = r, .valid = r.err == .none };
            }
        }.f,
    },
    check("validate", "utf8WithErrors", .validate_utf8, .{}),
    check("validate", "utf8", .validate_utf8, .{}),
    check("convert", "utf8ToUtf16le", .utf8_to_utf16le, .{}),
    check("convert", "utf8ToUtf16be", .utf8_to_utf16be, .{}),
    check("convert", "utf8ToUtf32", .utf8_to_utf32, .{}),
    check("convert", "utf8ToLatin1", .utf8_to_latin1, .{}),
    check("convert", "validUtf8ToUtf16le", .utf8_to_utf16le, .{}),
    check("convert", "validUtf8ToUtf16be", .utf8_to_utf16be, .{}),
    check("convert", "validUtf8ToUtf32", .utf8_to_utf32, .{}),
    check("convert", "validUtf8ToLatin1", .utf8_to_latin1, .{}),
    check("length", "utf16FromUtf8", .utf8_to_utf16le, .{}),
    check("length", "utf32FromUtf8", .utf8_to_utf32, .{}),
    check("length", "countUtf8", .utf8_to_utf32, .{}),
    check("length", "latin1FromUtf8", .utf8_to_latin1, .{}),
    .{
        .name = "std.unicode.utf8ToUtf16Le",
        .op = .utf8_to_utf16le,
        .mode = .validity,
        .run = struct {
            fn f(in: []align(16) const u8, out: []align(16) u8) Got {
                const n = std.unicode.utf8ToUtf16Le(cast([]u16, out), in) catch return .{ .valid = false };
                return .{ .valid = true, .out = out[0 .. 2 * n] };
            }
        }.f,
    },
};

const ascii_defs = [_]Def{
    check("validate", "asciiWithErrors", .validate_ascii, .{}),
    check("validate", "ascii", .validate_ascii, .{}),
};

/// The UTF-16 checks for byte order `e`, "le" or "be".
fn utf16Defs(comptime e: []const u8) [14]Def {
    const E = if (e[0] == 'l') "le" else "be";
    const other = if (e[0] == 'l') "be" else "le";
    const op = struct {
        fn op(comptime name: []const u8) Oracle.Op {
            return @field(Oracle.Op, name);
        }
    }.op;
    return .{
        check("validate", "utf16" ++ E ++ "WithErrors", op("validate_utf16" ++ E), .{}),
        check("validate", "utf16" ++ E, op("validate_utf16" ++ E), .{}),
        check("convert", "utf16" ++ E ++ "ToUtf8", op("utf16" ++ E ++ "_to_utf8"), .{}),
        check("convert", "utf16" ++ E ++ "ToUtf32", op("utf16" ++ E ++ "_to_utf32"), .{}),
        check("convert", "utf16" ++ E ++ "ToLatin1", op("utf16" ++ E ++ "_to_latin1"), .{}),
        check("convert", "utf16" ++ E ++ "ToUtf16" ++ other, op("validate_utf16" ++ E), .{ .swapped = true }),
        check("convert", "validUtf16" ++ E ++ "ToUtf8", op("utf16" ++ E ++ "_to_utf8"), .{}),
        check("convert", "validUtf16" ++ E ++ "ToUtf32", op("utf16" ++ E ++ "_to_utf32"), .{}),
        check("convert", "validUtf16" ++ E ++ "ToLatin1", op("utf16" ++ E ++ "_to_latin1"), .{}),
        check("convert", "validUtf16" ++ E ++ "ToUtf16" ++ other, op("validate_utf16" ++ E), .{ .swapped = true }),
        check("length", "utf8FromUtf16" ++ E, op("utf16" ++ E ++ "_to_utf8"), .{}),
        check("length", "utf32FromUtf16" ++ E, op("utf16" ++ E ++ "_to_utf32"), .{}),
        check("length", "countUtf16" ++ E, op("utf16" ++ E ++ "_to_utf32"), .{}),
        check("length", "latin1FromUtf16", op("utf16" ++ E ++ "_to_latin1"), .{}),
    };
}

const utf16le_defs = utf16Defs("le") ++ [_]Def{
    .{
        .name = "std.unicode.utf16LeToUtf8",
        .op = .utf16le_to_utf8,
        .mode = .validity,
        .run = struct {
            fn f(in: []align(16) const u8, out: []align(16) u8) Got {
                const n = std.unicode.utf16LeToUtf8(out, cast([]const u16, in)) catch return .{ .valid = false };
                return .{ .valid = true, .out = out[0..n] };
            }
        }.f,
    },
};

const utf16be_defs = utf16Defs("be");

const utf32_defs = [_]Def{
    check("validate", "utf32WithErrors", .validate_utf32, .{}),
    check("validate", "utf32", .validate_utf32, .{}),
    check("convert", "utf32ToUtf8", .utf32_to_utf8, .{}),
    check("convert", "utf32ToUtf16le", .utf32_to_utf16le, .{}),
    check("convert", "utf32ToUtf16be", .utf32_to_utf16be, .{}),
    check("convert", "utf32ToLatin1", .utf32_to_latin1, .{}),
    check("convert", "validUtf32ToUtf8", .utf32_to_utf8, .{}),
    check("convert", "validUtf32ToUtf16le", .utf32_to_utf16le, .{}),
    check("convert", "validUtf32ToUtf16be", .utf32_to_utf16be, .{}),
    check("convert", "validUtf32ToLatin1", .utf32_to_latin1, .{}),
    check("length", "utf8FromUtf32", .utf32_to_utf8, .{}),
    check("length", "utf16FromUtf32", .utf32_to_utf16le, .{}),
    check("length", "latin1FromUtf32", .utf32_to_latin1, .{}),
};

const latin1_defs = [_]Def{
    check("convert", "latin1ToUtf8", .latin1_to_utf8, .{}),
    check("convert", "latin1ToUtf16le", .latin1_to_utf16le, .{}),
    check("convert", "latin1ToUtf16be", .latin1_to_utf16be, .{}),
    check("convert", "latin1ToUtf32", .latin1_to_utf32, .{}),
    check("convert", "validLatin1ToUtf8", .latin1_to_utf8, .{}),
    check("convert", "validLatin1ToUtf16le", .latin1_to_utf16le, .{}),
    check("convert", "validLatin1ToUtf16be", .latin1_to_utf16be, .{}),
    check("convert", "validLatin1ToUtf32", .latin1_to_utf32, .{}),
    check("length", "utf8FromLatin1", .latin1_to_utf8, .{}),
    check("length", "utf16FromLatin1", .latin1_to_utf16le, .{}),
    check("length", "utf32FromLatin1", .latin1_to_utf32, .{}),
};

const base64_defs = [_]Def{
    // The package's default options are simdutf's defaults: the standard
    // alphabet, loose last chunk, ASCII whitespace skipped.
    check("base64", "decode", .base64_decode, .{}),
    check("base64", "decode", .base64_decode, .{ .base64 = .{ .last_chunk = .strict } }),
    check("base64", "decode", .base64_decode, .{ .base64 = .{ .last_chunk = .stop_before_partial } }),
    check("base64", "decode", .base64_decode, .{ .base64 = .{ .alphabet = .url } }),
    check("base64", "decode", .base64_decode, .{ .base64 = .{ .alphabet = .url, .last_chunk = .strict } }),
    check("base64", "decode", .base64_decode, .{ .base64 = .{ .alphabet = .url, .last_chunk = .stop_before_partial } }),
    .{
        .name = "std.base64.standard.Decoder",
        .op = .base64_decode,
        .option = Oracle.base64Option(.default, .strict),
        .mode = .ours_accepts,
        .run = struct {
            fn f(in: []align(16) const u8, out: []align(16) u8) Got {
                const decoder = std.base64.standard.Decoder;
                const n = decoder.calcSizeForSlice(in) catch return .{ .valid = false };
                decoder.decode(out[0..n], in) catch return .{ .valid = false };
                return .{ .valid = true, .out = out[0..n] };
            }
        }.f,
    },
};

const binary_defs = [_]Def{
    check("base64", "encode", .base64_encode, .{}),
    check("base64", "encode", .base64_encode, .{ .base64 = .{ .padding = false } }),
    check("base64", "encode", .base64_encode, .{ .base64 = .{ .alphabet = .url } }),
    check("base64", "encode", .base64_encode, .{ .base64 = .{ .alphabet = .url, .padding = false } }),
};

const Stats = struct {
    compared: u64 = 0,
    /// Inputs the check's mode leaves out: those simdutf rejects for a
    /// valid form or a length, those ours rejects for std's base64.
    skipped: u64 = 0,
    mismatches: u64 = 0,
    /// simdutf's verdicts, by error kind: what the inputs exercised.
    kinds: [13]u64 = @splat(0),
};

const Verdict = enum { agree, disagree, skipped };

/// Holds what `def`'s function returned for `in` against simdutf's answer.
/// `scratch` holds the expected output of a byte swap.
fn judge(def: Def, in: []const u8, resp: Oracle.Response, got: Got, scratch: []u8) Verdict {
    switch (def.mode) {
        .simdutf_accepts => if (resp.err != .none) return .skipped,
        .ours_accepts => if (!got.valid) return .skipped,
        .checked, .validity => {},
    }
    var ok = switch (def.mode) {
        .checked, .simdutf_accepts => Oracle.same(resp, got.result.?),
        .validity => got.valid == (resp.err == .none),
        .ours_accepts => resp.err == .none,
    };
    if (ok and resp.err == .none and got.valid) {
        if (got.out) |out| {
            const want = if (def.swapped) swapUnits(in, scratch) else resp.output;
            ok = mem.eql(u8, out, want);
        }
    }
    return if (ok) .agree else .disagree;
}

/// `in` with the two bytes of each UTF-16 code unit swapped, in `buf`.
fn swapUnits(in: []const u8, buf: []u8) []const u8 {
    for (0..in.len / 2) |i| {
        buf[2 * i] = in[2 * i + 1];
        buf[2 * i + 1] = in[2 * i];
    }
    return buf[0..in.len];
}

/// Collects inputs of one kind and runs them through the oracle and every
/// available check a batch at a time.
const Runner = struct {
    oracle: Oracle,
    gpa: Allocator,
    w: *Io.Writer,
    defs: []const Def,
    stats: []Stats,
    unit: usize,
    arena: std.heap.ArenaAllocator,
    inputs: std.ArrayList([]align(16) u8) = .empty,

    fn init(oracle: Oracle, w: *Io.Writer, defs: []const Def, unit: usize) !Runner {
        const stats = try oracle.gpa.alloc(Stats, defs.len);
        @memset(stats, .{});
        return .{
            .oracle = oracle,
            .gpa = oracle.gpa,
            .w = w,
            .defs = defs,
            .stats = stats,
            .unit = unit,
            .arena = .init(oracle.gpa),
        };
    }

    fn deinit(r: *Runner) void {
        r.inputs.deinit(r.gpa);
        r.arena.deinit();
        r.gpa.free(r.stats);
        r.* = undefined;
    }

    fn add(r: *Runner, bytes: []const u8) !void {
        const copy = try r.arena.allocator().alignedAlloc(u8, .@"16", bytes.len);
        @memcpy(copy, bytes);
        try r.inputs.append(r.gpa, copy);
        if (r.inputs.items.len == batch_size) try r.flush();
    }

    /// Runs `def`'s function on `in` and judges it against `resp`.
    fn try1(r: *Runner, def: Def, in: []align(16) const u8, resp: Oracle.Response) !struct { Verdict, Got } {
        const a = r.arena.allocator();
        const out = try a.alignedAlloc(u8, .@"16", 4 * in.len + 64);
        const got = def.run.?(in, out);
        return .{ judge(def, in, resp, got, try a.alloc(u8, in.len)), got };
    }

    fn flush(r: *Runner) !void {
        const n = r.inputs.items.len;
        if (n == 0) return;
        defer {
            r.inputs.clearRetainingCapacity();
            _ = r.arena.reset(.retain_capacity);
        }
        const a = r.arena.allocator();
        // One request per input for each distinct simdutf function and
        // option: several of our functions share one.
        const Call = struct { op: Oracle.Op, option: u8 };
        var calls: std.ArrayList(Call) = .empty;
        const slot = try a.alloc(usize, r.defs.len);
        for (r.defs, slot) |def, *s| {
            if (def.run == null) continue;
            s.* = for (calls.items, 0..) |c, i| {
                if (c.op == def.op and c.option == def.option) break i;
            } else blk: {
                try calls.append(a, .{ .op = def.op, .option = def.option });
                break :blk calls.items.len - 1;
            };
        }
        var requests: std.ArrayList(Oracle.Request) = .empty;
        for (calls.items) |c| {
            for (r.inputs.items) |in| try requests.append(a, .{ .op = c.op, .option = c.option, .input = in });
        }
        const responses = try r.oracle.run(requests.items);
        defer r.oracle.free(responses);
        for (r.defs, r.stats, slot) |def, *st, s| {
            if (def.run == null) continue;
            for (r.inputs.items, responses[s * n ..][0..n]) |in, resp| {
                const verdict, const got = try r.try1(def, in, resp);
                switch (verdict) {
                    .skipped => st.skipped += 1,
                    .agree, .disagree => {
                        st.compared += 1;
                        const e = compat.enumToInt(resp.err);
                        st.kinds[if (e < st.kinds.len) e else compat.enumToInt(Oracle.Error.other)] += 1;
                    },
                }
                if (verdict != .disagree) continue;
                st.mismatches += 1;
                if (st.mismatches > max_printed) continue;
                try r.print(def, in, resp, got);
                if (st.mismatches == 1) try r.shrink(def, in);
            }
        }
    }

    fn print(r: *Runner, def: Def, in: []const u8, resp: Oracle.Response, got: Got) !void {
        const w = r.w;
        try w.print("MISMATCH {s}: input of {d} bytes\n  simdutf: {t} at {d}", .{
            def.name, in.len, resp.err, resp.count,
        });
        if (got.result) |res| {
            try w.print("\n  ours:    {t} at {d}\n", .{ res.err, res.count });
        } else {
            try w.print("\n  ours:    {s}\n", .{if (got.valid) "valid" else "invalid"});
        }
        if (resp.err == .none and got.valid) {
            if (got.out) |out| {
                const want = if (def.swapped) swapUnits(in, try r.arena.allocator().alloc(u8, in.len)) else resp.output;
                if (mem.findDiff(u8, out, want)) |at| try w.print(
                    "  output: {d} bytes, {s} {d}, first differing at byte {d}\n",
                    .{ out.len, if (def.swapped) "the input swapped" else "simdutf's", want.len, at },
                );
            }
        }
        // The bytes around the first reported position.
        const pos = @min(in.len, r.unit * @min(resp.count, if (got.result) |res| res.count else resp.count));
        const from = pos -| 24;
        const to = @min(in.len, pos + 24);
        try w.print("  bytes [{d}..{d}):", .{ from, to });
        for (in[from..to]) |b| try w.print(" {x:0>2}", .{b});
        try w.writeAll("\n");
        try w.flush();
    }

    /// Shrinks `input` to a shorter one `def` still disagrees with simdutf
    /// on, by removing runs of code units, halving the run down to one
    /// unit, and prints it with both answers.
    fn shrink(r: *Runner, def: Def, input: []align(16) const u8) !void {
        var local: std.heap.ArenaAllocator = .init(r.gpa);
        defer local.deinit();
        var cur = input;
        var chunk = @max(1, cur.len / r.unit / 2);
        var runs: usize = 0;
        while (cur.len > 0 and runs < max_shrink_runs) : (runs += 1) {
            _ = local.reset(.retain_capacity);
            const a = local.allocator();
            const units = cur.len / r.unit;
            chunk = @min(chunk, units);
            var candidates: std.ArrayList([]align(16) u8) = .empty;
            var requests: std.ArrayList(Oracle.Request) = .empty;
            var at: usize = 0;
            while (at < units) : (at += chunk) {
                const end = @min(units, at + chunk);
                const c = try a.alignedAlloc(u8, .@"16", cur.len - (end - at) * r.unit);
                @memcpy(c[0 .. at * r.unit], cur[0 .. at * r.unit]);
                @memcpy(c[at * r.unit ..], cur[end * r.unit ..]);
                try candidates.append(a, c);
                try requests.append(a, .{ .op = def.op, .option = def.option, .input = c });
            }
            const responses = try r.oracle.run(requests.items);
            defer r.oracle.free(responses);
            const found = for (candidates.items, responses) |c, resp| {
                const out = try a.alignedAlloc(u8, .@"16", 4 * c.len + 64);
                if (judge(def, c, resp, def.run.?(c, out), try a.alloc(u8, c.len)) == .disagree) break c;
            } else null;
            if (found) |c| {
                const keep = try r.arena.allocator().alignedAlloc(u8, .@"16", c.len);
                @memcpy(keep, c);
                cur = keep;
            } else if (chunk == 1) {
                break;
            } else {
                chunk /= 2;
            }
        }
        const responses = try r.oracle.run(&.{.{ .op = def.op, .option = def.option, .input = cur }});
        defer r.oracle.free(responses);
        const verdict, const got = try r.try1(def, cur, responses[0]);
        if (verdict != .disagree) return; // only when the input was already minimal and empty
        try r.w.print("  shrunk to {d} bytes, after {d} oracle runs:", .{ cur.len, runs });
        for (cur[0..@min(cur.len, 256)]) |b| try r.w.print(" {x:0>2}", .{b});
        try r.w.writeAll(if (cur.len > 256) " ...\n" else "\n");
        try r.print(def, cur, responses[0], got);
    }

    fn report(r: *Runner, kind: []const u8) !void {
        try r.flush();
        const w = r.w;
        for (r.defs, r.stats) |def, st| {
            if (def.run == null) {
                try w.print("{s:<8} {s:<40} skipped: not there yet\n", .{ kind, def.name });
                continue;
            }
            try w.print("{s:<8} {s:<40} {d:>9} compared, {d} mismatches", .{
                kind, def.name, st.compared, st.mismatches,
            });
            if (st.skipped != 0) try w.print(", {d} not compared: {s} rejected them", .{
                st.skipped, if (def.mode == .ours_accepts) "ours" else "simdutf",
            });
            try w.writeAll("\n         simdutf said:");
            for (st.kinds, 0..) |count, i| {
                if (count != 0) try w.print(" {t}={d}", .{ compat.enumFromInt(Oracle.Error, @intCast(i)), count });
            }
            try w.writeAll("\n");
        }
        try w.flush();
    }

    fn mismatches(r: *const Runner) u64 {
        var total: u64 = 0;
        for (r.stats) |st| total += st.mismatches;
        return total;
    }
};

// Generators. Every input is built in `buf`, then copied into the batch.

const interesting = [_]u8{
    0x00, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC1, 0xC2, 0xDF, 0xE0, 0xE1, 0xEC,
    0xED, 0xEE, 0xEF, 0xF0, 0xF1, 0xF3, 0xF4, 0xF5, 0xF7, 0xF8, 0xFB, 0xFC, 0xFE, 0xFF,
};

/// Ill-formed sequences, one of each kind and its edges.
const bad_sequences = [_][]const u8{
    "\x80", "\xbf", "\x80\x80", // lone continuations
    "\xc0\x80", "\xc1\xbf", "\xe0\x80\x80", "\xe0\x9f\xbf", "\xf0\x80\x80\x80", "\xf0\x8f\xbf\xbf", // overlong
    "\xed\xa0\x80", "\xed\xbf\xbf", "\xed\xaf\xbf\xed\xb0\x80", // surrogates
    "\xf4\x90\x80\x80", "\xf5\x80\x80\x80", "\xf7\xbf\xbf\xbf", // too large
    "\xf8\x88\x80\x80\x80", "\xfc\x84\x80\x80\x80\x80", "\xfe", "\xff", // header bits
    "\xc2", "\xe2\x82", "\xf0\x9f\x98", "\xe2\x28\xa1", "\xf0\x9f\x28\x80", // too short
};

const boundary_code_points = [_]u21{
    0x7F,     0x80,     0xFF,   0x100,  0x7FF,   0x800,   0xFFF,   0x1000,
    0xD7FF,   0xE000,   0xFFFD, 0xFFFF, 0x10000, 0x3FFFF, 0x40000, 0xFFFFF,
    0x100000, 0x10FFFF,
};

fn appendCodePoint(gpa: Allocator, buf: *std.ArrayList(u8), cp: u21) !void {
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &tmp) catch unreachable;
    try buf.appendSlice(gpa, tmp[0..n]);
}

/// A valid code point from one of four UTF-8 length classes, a boundary
/// one, or one from the upper half of Latin-1.
fn codePoint(r: Random, class: u8) u21 {
    return switch (class) {
        0 => r.uintLessThan(u21, 0x80),
        1 => r.intRangeAtMost(u21, 0x80, 0x7FF),
        2 => blk: {
            const cp = r.intRangeAtMost(u21, 0x800, 0xFFFF - 0x800);
            break :blk if (cp >= 0xD800) cp + 0x800 else cp;
        },
        3 => r.intRangeAtMost(u21, 0x10000, 0x10FFFF),
        4 => boundary_code_points[r.uintLessThan(usize, boundary_code_points.len)],
        else => r.intRangeAtMost(u21, 0x80, 0xFF),
    };
}

/// About `target` valid code points, in runs of one class so that ASCII
/// blocks and multibyte blocks both occur. A quarter of the inputs keep to
/// Latin-1, so that the conversions to Latin-1 succeed on them, and half of
/// those get one larger code point somewhere.
fn codePoints(r: Random, gpa: Allocator, list: *std.ArrayList(u21), target: usize) !void {
    const latin1 = r.uintLessThan(u8, 4) == 0;
    while (list.items.len < target) {
        const class = if (latin1) 5 * r.uintLessThan(u8, 2) else r.uintLessThan(u8, 5);
        for (0..1 + r.uintLessThan(usize, 40)) |_| try list.append(gpa, codePoint(r, class));
    }
    if (latin1 and r.boolean()) {
        const cp = @max(0x100, codePoint(r, 1 + r.uintLessThan(u8, 3)));
        try list.insert(gpa, position(r, list.items.len), cp);
    }
}

/// A length: mostly under a few blocks, sometimes kilobytes, rarely tens.
fn length(r: Random) usize {
    return switch (r.uintLessThan(u16, 1000)) {
        0...699 => r.uintLessThan(usize, 129),
        700...899 => r.intRangeAtMost(usize, 129, 1024),
        900...994 => r.intRangeAtMost(usize, 1025, 8192),
        else => r.intRangeAtMost(usize, 8193, 70000),
    };
}

/// A position in [0, len]: anywhere, next to a 16-, 32-, or 64-unit block
/// boundary, or in the last few units.
fn position(r: Random, len: usize) usize {
    if (len == 0) return 0;
    switch (r.uintLessThan(u8, 10)) {
        0...3 => return r.uintAtMost(usize, len),
        4...6 => {
            const block = @as(usize, 16) << r.uintLessThan(u3, 3);
            const at = block * r.uintAtMost(usize, len / block) + r.uintLessThan(usize, 9);
            return @min(len, at -| 4);
        },
        else => return len - @min(len, r.uintLessThan(usize, 9)),
    }
}

/// Valid UTF-8 of about `target` bytes.
fn validUtf8(r: Random, gpa: Allocator, buf: *std.ArrayList(u8), target: usize) !void {
    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(gpa);
    try codePoints(r, gpa, &cps, target / 2);
    for (cps.items) |cp| try appendCodePoint(gpa, buf, cp);
}

fn mutateUtf8(r: Random, gpa: Allocator, buf: *std.ArrayList(u8)) !void {
    const p = position(r, buf.items.len);
    switch (r.uintLessThan(u8, 6)) {
        0 => if (p < buf.items.len) {
            buf.items[p] = interesting[r.uintLessThan(usize, interesting.len)];
        },
        1 => try buf.insert(gpa, p, interesting[r.uintLessThan(usize, interesting.len)]),
        2, 3 => try buf.insertSlice(gpa, p, bad_sequences[r.uintLessThan(usize, bad_sequences.len)]),
        4 => if (p < buf.items.len) {
            _ = buf.orderedRemove(p);
        },
        else => buf.shrinkRetainingCapacity(p),
    }
}

fn randomUtf8(r: Random, gpa: Allocator, buf: *std.ArrayList(u8)) Allocator.Error!void {
    const len = length(r);
    switch (r.uintLessThan(u8, 10)) {
        // Valid text with one to three mutations.
        0...5 => {
            try validUtf8(r, gpa, buf, len);
            for (0..1 + r.uintLessThan(usize, 3)) |_| try mutateUtf8(r, gpa, buf);
        },
        6 => try validUtf8(r, gpa, buf, len),
        // Random bytes, and random bytes that are mostly ASCII.
        7 => {
            try buf.resize(gpa, len);
            r.bytes(buf.items);
        },
        8 => {
            try buf.resize(gpa, len);
            for (buf.items) |*b| b.* = if (r.uintLessThan(u8, 8) == 0) r.int(u8) else r.uintLessThan(u8, 0x80);
        },
        // ASCII, with one bad sequence near a block boundary or the end.
        else => {
            try buf.resize(gpa, len);
            for (buf.items) |*b| b.* = 'a' + r.uintLessThan(u8, 26);
            const p = position(r, len);
            try buf.insertSlice(gpa, p, bad_sequences[r.uintLessThan(usize, bad_sequences.len)]);
        },
    }
}

/// Every two-byte sequence after a non-ASCII lead, and three- and four-byte
/// sequences over a grid of continuation values, each alone and placed to
/// straddle the boundary between two 64-byte blocks.
fn sweepUtf8(runner: *Runner, gpa: Allocator, buf: *std.ArrayList(u8)) !u64 {
    const tails = [_]u8{ 0x00, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xFF };
    var count: u64 = 0;
    for ([_]usize{ 0, 62 }) |pad| {
        var lead: u16 = 0x80;
        while (lead <= 0xFF) : (lead += 1) {
            var b1: u16 = 0;
            while (b1 <= 0xFF) : (b1 += 1) {
                // Two bytes.
                buf.clearRetainingCapacity();
                try buf.appendNTimes(gpa, 'x', pad);
                try buf.appendSlice(gpa, &.{ @intCast(lead), @intCast(b1) });
                try buf.appendSlice(gpa, "tail");
                try runner.add(buf.items);
                count += 1;
                if (lead < 0xE0) continue;
                // Three and four bytes, with a grid of later bytes.
                for (tails) |b2| {
                    buf.clearRetainingCapacity();
                    try buf.appendNTimes(gpa, 'x', pad);
                    try buf.appendSlice(gpa, &.{ @intCast(lead), @intCast(b1), b2 });
                    try runner.add(buf.items);
                    count += 1;
                    if (lead < 0xF0 or lead > 0xF7) continue;
                    for (tails) |b3| {
                        buf.clearRetainingCapacity();
                        try buf.appendNTimes(gpa, 'x', pad);
                        try buf.appendSlice(gpa, &.{ @intCast(lead), @intCast(b1), b2, b3 });
                        try runner.add(buf.items);
                        count += 1;
                    }
                }
            }
        }
    }
    return count;
}

/// ASCII text, mostly with one or two bytes above 0x7F put next to block
/// boundaries and the end.
fn randomAscii(r: Random, gpa: Allocator, buf: *std.ArrayList(u8)) Allocator.Error!void {
    const len = length(r);
    try buf.resize(gpa, len);
    const printable = r.boolean();
    for (buf.items) |*b| b.* = if (printable) ' ' + r.uintLessThan(u8, 95) else r.uintLessThan(u8, 0x80);
    if (r.uintLessThan(u8, 4) == 0) return;
    for (0..1 + r.uintLessThan(usize, 2)) |_| {
        const p = position(r, buf.items.len);
        const b = 0x80 | r.int(u8);
        if (p < buf.items.len and r.boolean()) buf.items[p] = b else try buf.insert(gpa, p, b);
    }
}

/// UTF-16 in byte order `endian`: runs of ASCII, BMP, and supplementary
/// characters, with lone and reversed surrogates put next to block
/// boundaries and the end.
fn randomUtf16(r: Random, gpa: Allocator, buf: *std.ArrayList(u8), endian: std.builtin.Endian) Allocator.Error!void {
    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(gpa);
    try codePoints(r, gpa, &cps, length(r) / 3);
    var cus: std.ArrayList(u16) = .empty;
    defer cus.deinit(gpa);
    for (cps.items) |cp| {
        if (cp < 0x10000) {
            try cus.append(gpa, @intCast(cp));
        } else {
            const v = cp - 0x10000;
            try cus.appendSlice(gpa, &.{ @intCast(0xD800 + (v >> 10)), @intCast(0xDC00 + (v & 0x3FF)) });
        }
    }
    if (r.uintLessThan(u8, 4) != 0) {
        for (0..1 + r.uintLessThan(usize, 2)) |_| {
            const p = position(r, cus.items.len);
            const bad = [_]u16{ 0xD800, 0xDBFF, 0xDC00, 0xDFFF };
            switch (r.uintLessThan(u8, 3)) {
                0 => try cus.insert(gpa, p, bad[r.uintLessThan(usize, bad.len)]),
                1 => try cus.insertSlice(gpa, p, &.{ 0xDC00, 0xD800 }),
                else => cus.shrinkRetainingCapacity(p),
            }
        }
    }
    for (cus.items) |cu| {
        var bytes: [2]u8 = undefined;
        mem.writeInt(u16, &bytes, cu, endian);
        try buf.appendSlice(gpa, &bytes);
    }
}

fn randomUtf16le(r: Random, gpa: Allocator, buf: *std.ArrayList(u8)) Allocator.Error!void {
    return randomUtf16(r, gpa, buf, .little);
}

fn randomUtf16be(r: Random, gpa: Allocator, buf: *std.ArrayList(u8)) Allocator.Error!void {
    return randomUtf16(r, gpa, buf, .big);
}

/// UTF-32LE: valid code points with surrogates, values past U+10FFFF, and
/// the boundaries around them inserted or written over near block
/// boundaries and the end.
fn randomUtf32(r: Random, gpa: Allocator, buf: *std.ArrayList(u8)) Allocator.Error!void {
    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(gpa);
    try codePoints(r, gpa, &cps, length(r) / 4);
    var units: std.ArrayList(u32) = .empty;
    defer units.deinit(gpa);
    for (cps.items) |cp| try units.append(gpa, cp);
    if (r.uintLessThan(u8, 4) != 0) {
        for (0..1 + r.uintLessThan(usize, 2)) |_| {
            const p = position(r, units.items.len);
            const bad = [_]u32{
                0xD800, 0xDBFF,   0xDC00,     0xDFFF,     0x110000,   0x1FFFFF,
                0xFFFF, 0x10FFFF, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF,
            };
            const v = bad[r.uintLessThan(usize, bad.len)];
            switch (r.uintLessThan(u8, 3)) {
                0 => try units.insert(gpa, p, v),
                1 => if (p < units.items.len) {
                    units.items[p] = v;
                },
                else => units.shrinkRetainingCapacity(p),
            }
        }
    }
    for (units.items) |u| try buf.appendSlice(gpa, &mem.toBytes(mem.nativeToLittle(u32, u)));
}

/// Latin-1: ASCII, ASCII with some bytes above 0x7F, or random bytes.
fn randomLatin1(r: Random, gpa: Allocator, buf: *std.ArrayList(u8)) Allocator.Error!void {
    try buf.resize(gpa, length(r));
    switch (r.uintLessThan(u8, 3)) {
        0 => for (buf.items) |*b| {
            b.* = r.uintLessThan(u8, 0x80);
        },
        1 => for (buf.items) |*b| {
            b.* = if (r.uintLessThan(u8, 8) == 0) r.int(u8) else r.uintLessThan(u8, 0x80);
        },
        else => r.bytes(buf.items),
    }
}

/// Base64 of random bytes in either alphabet, padded or not, sometimes
/// with spaces, stray characters, characters of the other alphabet, or a
/// cut-off or altered last chunk.
fn randomBase64(r: Random, gpa: Allocator, buf: *std.ArrayList(u8)) Allocator.Error!void {
    var raw: [4096]u8 = undefined;
    const n = if (r.uintLessThan(u8, 10) == 0) r.uintAtMost(usize, raw.len) else r.uintAtMost(usize, 400);
    r.bytes(raw[0..n]);
    const url = r.boolean();
    const encoder = if (url) std.base64.url_safe.Encoder else std.base64.standard.Encoder;
    try buf.resize(gpa, encoder.calcSize(n));
    _ = encoder.encode(buf.items, raw[0..n]);
    if (r.uintLessThan(u8, 3) == 0) {
        while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '=') buf.items.len -= 1;
    }
    const extra = [_]u8{ ' ', '\t', '\n', '\r', 0x0C, '=', '-', '_', '+', '/', '*', 0x80, 0 };
    const alphabet = if (url) std.base64.url_safe_alphabet_chars else std.base64.standard_alphabet_chars;
    for (0..r.uintLessThan(usize, 4)) |_| {
        const p = position(r, buf.items.len);
        switch (r.uintLessThan(u8, 5)) {
            0, 1 => try buf.insert(gpa, p, extra[r.uintLessThan(usize, extra.len)]),
            2 => if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '=') {
                buf.shrinkRetainingCapacity(buf.items.len - 1);
            },
            3 => if (p < buf.items.len) {
                buf.items[p] = alphabet[r.uintLessThan(usize, 64)];
            },
            else => buf.shrinkRetainingCapacity(p),
        }
    }
}

/// Random bytes to encode: mostly short, sometimes kilobytes.
fn randomBinary(r: Random, gpa: Allocator, buf: *std.ArrayList(u8)) Allocator.Error!void {
    try buf.resize(gpa, if (r.uintLessThan(u8, 10) == 0) r.uintAtMost(usize, 8192) else r.uintAtMost(usize, 200));
    r.bytes(buf.items);
}

/// The inputs after the UTF-8 phase, a quarter of N each.
const phases = [_]struct {
    kind: []const u8,
    defs: []const Def,
    unit: usize,
    gen: *const fn (Random, Allocator, *std.ArrayList(u8)) Allocator.Error!void,
}{
    .{ .kind = "ascii", .defs = &ascii_defs, .unit = 1, .gen = randomAscii },
    .{ .kind = "utf16le", .defs = &utf16le_defs, .unit = 2, .gen = randomUtf16le },
    .{ .kind = "utf16be", .defs = &utf16be_defs, .unit = 2, .gen = randomUtf16be },
    .{ .kind = "utf32", .defs = &utf32_defs, .unit = 4, .gen = randomUtf32 },
    .{ .kind = "latin1", .defs = &latin1_defs, .unit = 1, .gen = randomLatin1 },
    .{ .kind = "base64", .defs = &base64_defs, .unit = 1, .gen = randomBase64 },
    .{ .kind = "binary", .defs = &binary_defs, .unit = 1, .gen = randomBinary },
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const n = if (args.len > 1) try std.fmt.parseInt(u64, args[1], 10) else 1_000_000;
    const seed = if (args.len > 2) try std.fmt.parseInt(u64, args[2], 10) else 1;
    const path = init.environ_map.get("ORACLE") orelse "zig-out/bin/utf-oracle";
    const oracle: Oracle = .{ .io = io, .gpa = gpa, .path = path };

    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &stdout.interface;
    var name_buf: [64]u8 = undefined;
    const kernel = try oracle.implementation(&name_buf);
    try w.print("simdutf kernel: {s}; {d} random UTF-8 inputs, seed {d}\n", .{ kernel, n, seed });
    try w.flush();

    var prng: Random.DefaultPrng = .init(seed);
    const r = prng.random();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var total: u64 = 0;

    {
        var utf8 = try Runner.init(oracle, w, &utf8_defs, 1);
        defer utf8.deinit();
        const swept = try sweepUtf8(&utf8, gpa, &buf);
        for (0..n) |_| {
            buf.clearRetainingCapacity();
            try randomUtf8(r, gpa, &buf);
            try utf8.add(buf.items);
        }
        try w.print("utf8: {d} swept and {d} random inputs\n", .{ swept, n });
        try utf8.report("utf8");
        total += utf8.mismatches();
    }

    for (phases) |phase| {
        var runner = try Runner.init(oracle, w, phase.defs, phase.unit);
        defer runner.deinit();
        for (0..n / 4) |_| {
            buf.clearRetainingCapacity();
            try phase.gen(r, gpa, &buf);
            try runner.add(buf.items);
        }
        try w.print("{s}: {d} random inputs\n", .{ phase.kind, n / 4 });
        try runner.report(phase.kind);
        total += runner.mismatches();
    }

    try w.print("{d} mismatches in all\n", .{total});
    try w.flush();
    return if (total == 0) 0 else 1;
}
