//! Per-call cost of short calls: every public function of `validate`,
//! `convert`, `length`, and `base64` (encode, decode) called out of line in
//! a loop, as the harness's arms call, timed with the TSC; the minimum over
//! 15 loops of 1 million calls. Each case is an exported `case_<module>_<fn>`
//! wrapper, so objdump shows its prologue in a native build, where the
//! kernel is inlined into it. `calls [FILTER] [LENS]`; prints
//! `module.fn/len ticks`, len in units of the source. Inputs are ASCII letters, valid in every format
//! and as base64, or with `LATIN=1` bytes 0xA0-0xFF for Latin-1 sources.
const std = @import("std");
const utf = @import("utf");

fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("lfence; rdtsc; lfence"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return @as(u64, hi) << 32 | lo;
}

var in_buf: [8192]u8 align(4096) = undefined;
var in_latin: [8192]u8 align(4096) = undefined;
var out_buf: [65536]u8 align(4096) = undefined;
var pad_buf: [8192]u8 align(4096) = undefined;

fn view(comptime S: type, bytes: anytype) S {
    const U = @typeInfo(S).pointer.child;
    const P = if (@typeInfo(S).pointer.is_const) [*]const U else [*]U;
    return @as(P, @ptrCast(@alignCast(bytes.ptr)))[0 .. bytes.len / @sizeOf(U)];
}

const Run = *const fn ([*]const u8, usize, [*]u8, usize) callconv(.c) usize;
const Case = struct { name: []const u8, run: Run, latin: bool, unit: usize };

fn Wrap(comptime f: anytype) type {
    return struct {
        fn run(ip: [*]const u8, il: usize, op: [*]u8, ol: usize) callconv(.c) usize {
            const in = ip[0..il];
            const out = op[0..ol];
            const P = @typeInfo(@TypeOf(f)).@"fn".params;
            const r = switch (P.len) {
                1 => f(view(P[0].type.?, in)),
                2 => f(view(P[0].type.?, in), view(P[1].type.?, out)),
                3 => f(out, in, .{}),
                else => unreachable,
            };
            return switch (@TypeOf(r)) {
                bool => @intFromBool(r),
                usize => r,
                utf.Result => if (r.err == .none) r.count else 0,
                else => unreachable,
            };
        }
    };
}

const cases = blk: {
    var list: []const Case = &.{};
    for (.{ "validate", "length", "convert", "base64" }) |m| {
        const M = @field(utf, m);
        for (@typeInfo(M).@"struct".decls) |d| {
            const x = @field(M, d.name);
            if (@typeInfo(@TypeOf(x)) != .@"fn") continue;
            const info = @typeInfo(@TypeOf(x)).@"fn";
            if (info.is_generic) continue;
            if (std.mem.eql(u8, m, "base64") and !std.mem.eql(u8, d.name, "encode") and !std.mem.eql(u8, d.name, "decode")) continue;
            if (std.mem.eql(u8, m, "length") and info.params.len != 1) continue;
            const W = Wrap(x);
            @export(&W.run, .{ .name = "case_" ++ m ++ "_" ++ d.name });
            list = list ++ .{Case{
                .name = m ++ "." ++ d.name,
                .run = &W.run,
                .latin = std.mem.startsWith(u8, d.name, "latin1") or std.mem.startsWith(u8, d.name, "validLatin1"),
                .unit = if (info.params.len == 3) 1 else @sizeOf(@typeInfo(info.params[0].type.?).pointer.child),
            }};
        }
    }
    break :blk list;
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const filter: []const u8 = if (args.len > 1) args[1] else "";
    var lens_buf: [16]usize = undefined;
    var lens: []usize = lens_buf[0..0];
    if (args.len > 2) {
        var it = std.mem.tokenizeScalar(u8, args[2], ',');
        while (it.next()) |t| {
            lens_buf[lens.len] = try std.fmt.parseInt(usize, t, 10);
            lens = lens_buf[0 .. lens.len + 1];
        }
    } else {
        lens_buf[0..2].* = .{ 16, 64 };
        lens = lens_buf[0..2];
    }
    const latin = init.environ_map.get("LATIN") != null;
    // INOFF and OUTOFF: the input's offset in its page (default 0) and the
    // output's (default 2048).
    const in_off = if (init.environ_map.get("INOFF")) |v| try std.fmt.parseInt(usize, v, 10) else 0;
    const out_off = if (init.environ_map.get("OUTOFF")) |v| try std.fmt.parseInt(usize, v, 10) else 2048;
    for (&in_buf, 0..) |*x, i| x.* = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"[i % 64];
    for (&in_latin, 0..) |*x, i| x.* = @intCast(0xA0 + i % 96);
    @memset(&out_buf, 0);
    const iters = 1_000_000;
    const rounds = 15;
    var buf: [256]u8 = undefined;
    // MMAP: the input and output each in a fresh mapping of one page, as
    // the harness places them.
    const use_map = init.environ_map.get("MMAP") != null;
    const map_in = std.heap.page_allocator.rawAlloc(65536, .fromByteUnits(4096), @returnAddress()).?;
    const map_out = std.heap.page_allocator.rawAlloc(65536 * 4, .fromByteUnits(4096), @returnAddress()).?;
    @memset(map_out[0 .. 65536 * 4], 0);
    for (cases) |cs| {
        if (std.mem.indexOf(u8, cs.name, filter) == null) continue;
        for (lens) |len| {
            var best: u64 = std.math.maxInt(u64);
            var src: []const u8 = if (latin and cs.latin) in_latin[in_off..][0 .. len * cs.unit] else in_buf[in_off..][0 .. len * cs.unit];
            var out: []u8 = out_buf[out_off..];
            // A padded base64 input, as the harness's: the last two
            // characters `=`, the one before them one with zero low bits.
            if (std.mem.eql(u8, cs.name, "base64.decode") and len >= 4) {
                @memcpy(pad_buf[0..len], in_buf[0..len]);
                pad_buf[len - 3] = 'A';
                pad_buf[len - 2] = '=';
                pad_buf[len - 1] = '=';
                src = pad_buf[0..len];
            }
            if (use_map) {
                @memset(map_in[0..65536], 0);
                @memcpy(map_in[in_off..][0..src.len], src);
                src = map_in[in_off..][0..src.len];
                out = map_out[out_off .. out_off + 4 * len * cs.unit + 64];
            }
            for (0..rounds) |_| {
                const start = rdtsc();
                for (0..iters) |_| {
                    std.mem.doNotOptimizeAway(src.ptr);
                    std.mem.doNotOptimizeAway(cs.run(src.ptr, src.len, out.ptr, out.len));
                }
                best = @min(best, rdtsc() - start);
            }
            const line = try std.fmt.bufPrint(&buf, "{s}/{d}\t{d:.2}\n", .{ cs.name, len, @as(f64, @floatFromInt(best)) / iters });
            std.debug.print("{s}", .{line});
        }
    }
}
