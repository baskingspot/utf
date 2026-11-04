//! `bmpb serve ARM`: one row per stdin line, `OP FILE N`, answered with
//! the row timed for N iterations (0: as many as take 20 ms) after one
//! untimed call, in the Go benchmark format. OP is `to8` (UTF-16 to UTF-8)
//! or `from8` (UTF-8 to UTF-16), FILE a `.utf8` file of encoding's corpus
//! (bench/corpus-gen/<encoding>/<shape>-<size>.utf8, read from the current
//! directory), converted to UTF-16 for `to8`. Both convert the whole file a
//! stage of 256 units or so at a time, as encoding's single-byte codecs
//! call them. ARM is `utf` (utf's convert.bmpToUtf8 and utf8ToBmp), `enc`
//! (encoding's copies, enc_codec.zig), or `gen` (utf's general converters,
//! validUtf16leToUtf8 and utf8ToUtf16le, in the same stages). Time is TSC
//! ticks at 2.6 GHz.
const std = @import("std");
const Io = std.Io;
const utf = @import("utf");
const enc = @import("enc");

const stage_len = 256;

fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("lfence; rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return @as(u64, hi) << 32 | lo;
}

const Arm = enum { utf, enc, gen };

fn to8(comptime arm: Arm, src: []const u16, dst: []u8) usize {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len) {
        const n = @min(stage_len, src.len - i);
        switch (arm) {
            .utf => {
                const r = utf.convert.bmpToUtf8(src[i..][0..n], dst[o..]);
                i += r.read;
                o += r.written;
            },
            .enc => {
                const r = enc.bmpToUtf8(src[i..][0..n], dst[o..]);
                i += r.read;
                o += r.written;
            },
            .gen => {
                o += utf.convert.validUtf16leToUtf8(src[i..][0..n], dst[o..]);
                i += n;
            },
        }
    }
    return o;
}

/// One character, for encoding's copy, which leaves the last bytes and
/// what stops it to its caller: the UTF-16 unit and its length, read inline
/// as encoding's `codec.read` reads one- to three-byte sequences.
inline fn step(src: []const u8) struct { u16, usize } {
    const c = src[0];
    if (c < 0x80) return .{ c, 1 };
    if (c >= 0xC2 and c <= 0xDF and src.len >= 2 and src[1] & 0xC0 == 0x80)
        return .{ @as(u16, c & 0x1F) << 6 | (src[1] & 0x3F), 2 };
    if (c & 0xF0 == 0xE0 and src.len >= 3 and src[1] & 0xC0 == 0x80 and src[2] & 0xC0 == 0x80 and
        (c != 0xE0 or src[1] >= 0xA0) and (c != 0xED or src[1] < 0xA0))
        return .{ @as(u16, c & 0x0F) << 12 | @as(u16, src[1] & 0x3F) << 6 | (src[2] & 0x3F), 3 };
    return .{ 0xFFFD, 1 };
}

fn from8(comptime arm: Arm, src: []const u8, dst: []u16) usize {
    var stage: [stage_len]u16 = undefined;
    var i: usize = 0;
    var sum: usize = 0;
    switch (arm) {
        .utf => while (i < src.len) {
            const r = utf.convert.utf8ToBmp(src[i..], &stage);
            if (r.read == 0) {
                const u, const n = step(src[i..]);
                stage[0] = u;
                i += n;
                sum += 1;
                continue;
            }
            i += r.read;
            sum += r.written + stage[r.written - 1];
        },
        .enc => while (i < src.len) {
            // As encoding's encodeStaged calls it: enough input that the
            // last window can fill the stage.
            const r = enc.utf8ToBmp(src[i..@min(src.len, i + stage_len + enc.window + 2)], &stage);
            if (r.read == 0) {
                const u, const n = step(src[i..]);
                stage[0] = u;
                i += n;
                sum += 1;
                continue;
            }
            i += r.read;
            sum += r.written + stage[r.written - 1];
        },
        .gen => {
            const r = utf.convert.utf8ToUtf16le(src, dst);
            sum = r.written;
        },
    }
    return sum;
}

const Input = struct { name: []const u8, bytes: []u8, units: []u16 };

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 3 or !std.mem.eql(u8, args[1], "serve")) {
        std.debug.print("usage: bmpb serve utf|enc|gen\n", .{});
        return 2;
    }
    const arm = std.meta.stringToEnum(Arm, args[2]) orelse return 2;
    var inputs: std.ArrayList(Input) = .empty;
    var in_buf: [4096]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(io, &in_buf);
    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &stdout.interface;
    // Outputs 2048 bytes into a page, as utf's harness places them.
    const out = try gpa.alignedAlloc(u8, .fromByteUnits(4096), 4 << 20);
    const dst8 = out[2048..];
    const dst16 = std.mem.bytesAsSlice(u16, out[2048..]);
    while (try stdin.interface.takeDelimiter('\n')) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const op = fields.next() orelse return error.BadRequest;
        const file = fields.next() orelse return error.BadRequest;
        var n = try std.fmt.parseInt(u64, fields.next() orelse return error.BadRequest, 10);
        const input = for (inputs.items) |x| {
            if (std.mem.eql(u8, x.name, file)) break x;
        } else blk: {
            const text = try Io.Dir.cwd().readFileAlloc(io, file, gpa, .unlimited);
            const bytes = try gpa.alignedAlloc(u8, .fromByteUnits(4096), text.len);
            @memcpy(bytes, text);
            const units = try gpa.alignedAlloc(u16, .fromByteUnits(4096), text.len);
            const k = try std.unicode.utf8ToUtf16Le(units, text);
            const x: Input = .{ .name = try gpa.dupe(u8, file), .bytes = bytes, .units = units[0..k] };
            try inputs.append(gpa, x);
            break :blk x;
        };
        const is_to8 = std.mem.eql(u8, op, "to8");
        const run = struct {
            fn run(a: Arm, t: bool, x: Input, d8: []u8, d16: []u16, iters: u64) u64 {
                const t0 = rdtsc();
                var i: u64 = 0;
                while (i < iters) : (i += 1) {
                    std.mem.doNotOptimizeAway(x.bytes.ptr);
                    std.mem.doNotOptimizeAway(switch (a) {
                        inline else => |ca| if (t)
                            @call(.never_inline, to8, .{ ca, x.units, d8 })
                        else
                            @call(.never_inline, from8, .{ ca, x.bytes, d16 }),
                    });
                }
                return rdtsc() - t0;
            }
        }.run;
        _ = run(arm, is_to8, input, dst8, dst16, 1);
        var ticks: u64 = 0;
        if (n == 0) {
            n = 1;
            while (true) {
                ticks = run(arm, is_to8, input, dst8, dst16, n);
                if (ticks >= 52_000_000) break;
                n = @max(n + 1, @min(100 * n, n * 52_000_000 * 12 / 10 / @max(ticks, 1)));
            }
        } else ticks = run(arm, is_to8, input, dst8, dst16, n);
        const ns = @as(f64, @floatFromInt(ticks)) / 2.6 / @as(f64, @floatFromInt(n));
        const bytes: f64 = @floatFromInt(if (is_to8) 2 * input.units.len else input.bytes.len);
        const name = std.mem.sliceTo(file, '.');
        const label = name[(std.mem.indexOf(u8, name, "corpus-gen/") orelse 0) + (if (std.mem.indexOf(u8, name, "corpus-gen/") != null) @as(usize, 11) else 0) ..];
        try w.print("Benchmark{s}/{s}\t{d}\t{d:.3} ns/op\t{d:.2} MB/s\n", .{
            if (is_to8) "To8" else "From8", label, n, ns, bytes * 1000 / ns,
        });
        try w.flush();
    }
    return 0;
}
