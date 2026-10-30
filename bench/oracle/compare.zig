//! `just oracle [N] [SEED]`: runs random and adversarial inputs through
//! simdutf, by way of `utf-oracle`, and through this package, and reports
//! every input where the two disagree on the error kind, its position, or
//! the output (bench/README.md).
//!
//!     oracle-compare [N] [SEED]
//!
//! N (default 1000000) is the number of random UTF-8 inputs; the UTF-16 and
//! base64 phases get a quarter of that each. SEED (default 1) fixes them.
//! ORACLE names the oracle (default zig-out/bin/utf-oracle). Run from the
//! repository root.
//!
//! The UTF-8 phase also runs a deterministic sweep: every two-byte sequence
//! after a non-ASCII lead and a grid of three- and four-byte sequences, each
//! at the start of the input and straddling a 64-byte block.
//!
//! Each check compares one of this package's functions with one simdutf
//! function. `scalar.validateUtf8` is always there; the plan's SIMD
//! functions are checked once they exist and skipped until then. The
//! `std.*` checks hold Zig's std against simdutf to show the oracle's
//! conversions and base64 are wired right: validity and output where std
//! has no positions, and only where std accepts for base64, since std's
//! decoder is stricter than simdutf's forgiving one.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const Random = std.Random;
const Allocator = mem.Allocator;

const utf = @import("utf");
const Oracle = @import("Oracle");

const batch_size = 20_000;
/// The mismatches printed per check; the rest are counted.
const max_printed = 8;

/// What one of our functions returned for one input.
const Got = struct {
    /// The full result, compared with simdutf's error kind and position.
    result: ?utf.Result = null,
    /// Validity alone, compared when `result` is null.
    valid: bool,
    /// The output, compared when both sides succeed.
    out: ?[]const u8 = null,
    /// Compare only when this side accepts: simdutf must accept too.
    one_way: bool = false,
};

const RunFn = *const fn (in: []align(16) const u8, out: []align(16) u8) Got;

const Def = struct {
    name: []const u8,
    op: Oracle.Op,
    option: u8 = 0,
    /// Null when the function does not exist yet.
    run: ?RunFn,
};

const Kind = enum { utf8, utf16le, base64 };

fn has(comptime ns: []const u8, comptime name: []const u8) bool {
    if (!@hasDecl(utf, ns)) return false;
    return @hasDecl(@field(utf, ns), name);
}

fn units(bytes: []align(16) const u8) []const u16 {
    return mem.bytesAsSlice(u16, bytes);
}
fn unitsMut(bytes: []align(16) u8) []u16 {
    return mem.bytesAsSlice(u16, bytes);
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
    .{
        .name = "validate.utf8WithErrors",
        .op = .validate_utf8,
        .run = if (has("validate", "utf8WithErrors")) struct {
            fn f(in: []align(16) const u8, _: []align(16) u8) Got {
                const r = utf.validate.utf8WithErrors(in);
                return .{ .result = r, .valid = r.err == .none };
            }
        }.f else null,
    },
    .{
        .name = "validate.utf8",
        .op = .validate_utf8,
        .run = if (has("validate", "utf8")) struct {
            fn f(in: []align(16) const u8, _: []align(16) u8) Got {
                return .{ .valid = utf.validate.utf8(in) };
            }
        }.f else null,
    },
    .{
        .name = "convert.utf8ToUtf16le",
        .op = .utf8_to_utf16le,
        .run = if (has("convert", "utf8ToUtf16le")) struct {
            fn f(in: []align(16) const u8, out: []align(16) u8) Got {
                const r = utf.convert.utf8ToUtf16le(in, unitsMut(out));
                return .{ .result = r, .valid = r.err == .none, .out = out[0 .. 2 * r.count] };
            }
        }.f else null,
    },
    .{
        .name = "std.unicode.utf8ToUtf16Le",
        .op = .utf8_to_utf16le,
        .run = struct {
            fn f(in: []align(16) const u8, out: []align(16) u8) Got {
                const n = std.unicode.utf8ToUtf16Le(unitsMut(out), in) catch return .{ .valid = false };
                return .{ .valid = true, .out = out[0 .. 2 * n] };
            }
        }.f,
    },
};

const utf16le_defs = [_]Def{
    .{
        .name = "validate.utf16leWithErrors",
        .op = .validate_utf16le,
        .run = if (has("validate", "utf16leWithErrors")) struct {
            fn f(in: []align(16) const u8, _: []align(16) u8) Got {
                const r = utf.validate.utf16leWithErrors(units(in));
                return .{ .result = r, .valid = r.err == .none };
            }
        }.f else null,
    },
    .{
        .name = "convert.utf16leToUtf8",
        .op = .utf16le_to_utf8,
        .run = if (has("convert", "utf16leToUtf8")) struct {
            fn f(in: []align(16) const u8, out: []align(16) u8) Got {
                const r = utf.convert.utf16leToUtf8(units(in), out);
                return .{ .result = r, .valid = r.err == .none, .out = out[0..r.count] };
            }
        }.f else null,
    },
    .{
        .name = "std.unicode.utf16LeToUtf8",
        .op = .utf16le_to_utf8,
        .run = struct {
            fn f(in: []align(16) const u8, out: []align(16) u8) Got {
                const n = std.unicode.utf16LeToUtf8(out, units(in)) catch return .{ .valid = false };
                return .{ .valid = true, .out = out[0..n] };
            }
        }.f,
    },
};

const base64_defs = [_]Def{
    // The package's default options against simdutf's defaults: the
    // standard alphabet, loose last chunk, spaces ignored.
    .{
        .name = "base64.decode",
        .op = .base64_decode,
        .option = Oracle.base64Option(.default, .loose),
        .run = if (has("base64", "decode") and defaultOptions(utf.base64.decode) != null) struct {
            fn f(in: []align(16) const u8, out: []align(16) u8) Got {
                const r = utf.base64.decode(out, in, comptime defaultOptions(utf.base64.decode).?);
                return .{ .result = r, .valid = r.err == .none, .out = out[0..r.count] };
            }
        }.f else null,
    },
    .{
        .name = "std.base64.standard.Decoder",
        .op = .base64_decode,
        .option = Oracle.base64Option(.default, .strict),
        .run = struct {
            fn f(in: []align(16) const u8, out: []align(16) u8) Got {
                const decoder = std.base64.standard.Decoder;
                const n = decoder.calcSizeForSlice(in) catch return .{ .valid = false, .one_way = true };
                decoder.decode(out[0..n], in) catch return .{ .valid = false, .one_way = true };
                return .{ .valid = true, .out = out[0..n], .one_way = true };
            }
        }.f,
    },
};

const Stats = struct {
    compared: u64 = 0,
    /// One-way checks where our side rejected, so nothing was compared.
    skipped: u64 = 0,
    mismatches: u64 = 0,
    /// simdutf's verdicts, by error kind: what the inputs exercised.
    kinds: [12]u64 = @splat(0),
};

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

    fn add(r: *Runner, bytes: []const u8) !void {
        const copy = try r.arena.allocator().alignedAlloc(u8, .@"16", bytes.len);
        @memcpy(copy, bytes);
        try r.inputs.append(r.gpa, copy);
        if (r.inputs.items.len == batch_size) try r.flush();
    }

    fn flush(r: *Runner) !void {
        const n = r.inputs.items.len;
        if (n == 0) return;
        defer {
            r.inputs.clearRetainingCapacity();
            _ = r.arena.reset(.retain_capacity);
        }
        var requests: std.ArrayList(Oracle.Request) = .empty;
        defer requests.deinit(r.gpa);
        // One request per input for each def; defs on the same op and
        // option share the answers but stay simple to read this way.
        for (r.defs) |def| {
            if (def.run == null) continue;
            for (r.inputs.items) |in| try requests.append(r.gpa, .{ .op = def.op, .option = def.option, .input = in });
        }
        const responses = try r.oracle.run(requests.items);
        defer r.oracle.free(responses);
        var base: usize = 0;
        for (r.defs, r.stats) |def, *st| {
            const run = def.run orelse continue;
            for (r.inputs.items, responses[base..][0..n]) |in, resp| {
                const out = try r.arena.allocator().alignedAlloc(u8, .@"16", 4 * in.len + 64);
                try r.compare(def, st, in, resp, run(in, out));
            }
            base += n;
        }
    }

    fn compare(r: *Runner, def: Def, st: *Stats, in: []const u8, resp: Oracle.Response, got: Got) !void {
        if (got.one_way and !got.valid) {
            st.skipped += 1;
            return;
        }
        st.compared += 1;
        st.kinds[@min(@intFromEnum(resp.err), 11)] += 1;
        var ok = if (got.result) |res|
            Oracle.same(resp, res)
        else if (got.one_way)
            resp.err == .none
        else
            got.valid == (resp.err == .none);
        if (ok and resp.err == .none and got.valid) {
            if (got.out) |out| ok = mem.eql(u8, out, resp.output);
        }
        if (ok) return;
        st.mismatches += 1;
        if (st.mismatches > max_printed) return;
        const w = r.w;
        try w.print("MISMATCH {s}: input of {d} bytes\n  simdutf: {t} at {d}", .{
            def.name, in.len, resp.err, resp.count,
        });
        if (got.result) |res| {
            try w.print("\n  ours:    {t} at {d}\n", .{ res.err, res.count });
        } else {
            try w.print("\n  ours:    {s}\n", .{if (got.valid) "valid" else "invalid"});
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

    fn report(r: *Runner, kind: Kind) !void {
        try r.flush();
        const w = r.w;
        for (r.defs, r.stats) |def, st| {
            if (def.run == null) {
                try w.print("{t:<8} {s:<28} skipped: not there yet\n", .{ kind, def.name });
                continue;
            }
            try w.print("{t:<8} {s:<28} {d:>9} compared, {d} mismatches", .{
                kind, def.name, st.compared, st.mismatches,
            });
            if (st.skipped != 0) try w.print(", {d} rejected by ours, not compared", .{st.skipped});
            try w.writeAll("\n         simdutf said:");
            for (st.kinds, 0..) |count, i| {
                if (count != 0) try w.print(" {t}={d}", .{ @as(Oracle.Error, @enumFromInt(i)), count });
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
    0x7F,   0x80,   0x7FF,   0x800,   0xFFF,   0x1000,  0xD7FF,   0xE000,
    0xFFFD, 0xFFFF, 0x10000, 0x3FFFF, 0x40000, 0xFFFFF, 0x100000, 0x10FFFF,
};

fn appendCodePoint(gpa: Allocator, buf: *std.ArrayList(u8), cp: u21) !void {
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &tmp) catch unreachable;
    try buf.appendSlice(gpa, tmp[0..n]);
}

/// A valid code point from one of four length classes, or a boundary one.
fn codePoint(r: Random, class: u8) u21 {
    return switch (class) {
        0 => r.uintLessThan(u21, 0x80),
        1 => r.intRangeAtMost(u21, 0x80, 0x7FF),
        2 => blk: {
            const cp = r.intRangeAtMost(u21, 0x800, 0xFFFF - 0x800);
            break :blk if (cp >= 0xD800) cp + 0x800 else cp;
        },
        3 => r.intRangeAtMost(u21, 0x10000, 0x10FFFF),
        else => boundary_code_points[r.uintLessThan(usize, boundary_code_points.len)],
    };
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

/// A position in [0, len]: anywhere, next to a 16-, 32-, or 64-byte block
/// boundary, or in the last few bytes.
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

/// Valid UTF-8 of about `target` bytes, in runs of one length class so
/// that ASCII blocks and multibyte blocks both occur.
fn validUtf8(r: Random, gpa: Allocator, buf: *std.ArrayList(u8), target: usize) !void {
    while (buf.items.len < target) {
        const class = r.uintLessThan(u8, 5);
        const run = 1 + r.uintLessThan(usize, 40);
        for (0..run) |_| try appendCodePoint(gpa, buf, codePoint(r, class));
    }
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

fn randomUtf8(r: Random, gpa: Allocator, buf: *std.ArrayList(u8)) !void {
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

/// UTF-16LE: runs of ASCII, BMP, and supplementary characters, with lone
/// and reversed surrogates put next to block boundaries and the end.
fn randomUtf16le(r: Random, gpa: Allocator, buf: *std.ArrayList(u8)) !void {
    const target = length(r) / 2;
    var cus: std.ArrayList(u16) = .empty;
    defer cus.deinit(gpa);
    while (cus.items.len < target) {
        const class = r.uintLessThan(u8, 4);
        for (0..1 + r.uintLessThan(usize, 40)) |_| {
            switch (class) {
                0 => try cus.append(gpa, r.uintLessThan(u16, 0x80)),
                1 => {
                    const cu = r.intRangeAtMost(u16, 0x80, 0xFFFF - 0x800);
                    try cus.append(gpa, if (cu >= 0xD800) cu + 0x800 else cu);
                },
                else => {
                    const cp = r.intRangeAtMost(u21, 0x10000, 0x10FFFF) - 0x10000;
                    try cus.appendSlice(gpa, &.{ @intCast(0xD800 + (cp >> 10)), @intCast(0xDC00 + (cp & 0x3FF)) });
                },
            }
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
    for (cus.items) |cu| try buf.appendSlice(gpa, &mem.toBytes(mem.nativeToLittle(u16, cu)));
}

/// Base64 of random bytes, sometimes padded wrong, with spaces, stray
/// characters, or a cut-off or altered last chunk.
fn randomBase64(r: Random, gpa: Allocator, buf: *std.ArrayList(u8)) !void {
    var raw: [400]u8 = undefined;
    const n = r.uintAtMost(usize, raw.len);
    r.bytes(raw[0..n]);
    const encoder = std.base64.standard.Encoder;
    try buf.resize(gpa, encoder.calcSize(n));
    _ = encoder.encode(buf.items, raw[0..n]);
    const extra = [_]u8{ ' ', '\t', '\n', '\r', 0x0C, '=', '-', '_', '*', 0x80, 0 };
    for (0..r.uintLessThan(usize, 4)) |_| {
        const p = position(r, buf.items.len);
        switch (r.uintLessThan(u8, 5)) {
            0, 1 => try buf.insert(gpa, p, extra[r.uintLessThan(usize, extra.len)]),
            2 => if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '=') {
                buf.shrinkRetainingCapacity(buf.items.len - 1);
            },
            3 => if (p < buf.items.len) {
                buf.items[p] = std.base64.standard_alphabet_chars[r.uintLessThan(usize, 64)];
            },
            else => buf.shrinkRetainingCapacity(p),
        }
    }
}

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
    var total: u64 = 0;

    var utf8 = try Runner.init(oracle, w, &utf8_defs, 1);
    const swept = try sweepUtf8(&utf8, gpa, &buf);
    for (0..n) |_| {
        buf.clearRetainingCapacity();
        try randomUtf8(r, gpa, &buf);
        try utf8.add(buf.items);
    }
    try w.print("utf8: {d} swept and {d} random inputs\n", .{ swept, n });
    try utf8.report(.utf8);
    total += utf8.mismatches();

    var utf16 = try Runner.init(oracle, w, &utf16le_defs, 2);
    for (0..n / 4) |_| {
        buf.clearRetainingCapacity();
        try randomUtf16le(r, gpa, &buf);
        try utf16.add(buf.items);
    }
    try w.print("utf16le: {d} random inputs\n", .{n / 4});
    try utf16.report(.utf16le);
    total += utf16.mismatches();

    var b64 = try Runner.init(oracle, w, &base64_defs, 1);
    for (0..n / 4) |_| {
        buf.clearRetainingCapacity();
        try randomBase64(r, gpa, &buf);
        try b64.add(buf.items);
    }
    try w.print("base64: {d} random inputs\n", .{n / 4});
    try b64.report(.base64);
    total += b64.mismatches();

    try w.print("{d} mismatches in all\n", .{total});
    try w.flush();
    return if (total == 0) 0 else 1;
}
