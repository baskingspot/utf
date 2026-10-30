//! Base64 throughput: utf's kernels against simdutf (through its C API),
//! Zig's std.base64, and utf's scalar reference. Arms run interleaved, one
//! sample each in turn, and print Go benchmark lines for benchstat. Speed is
//! input bytes per second: binary bytes for encode, base64 characters for
//! decode.
//!
//! From the repository root, with SIMDUTF the nixpkgs simdutf 9.2.1 store
//! path (`nix build nixpkgs#simdutf`):
//!
//!   zig build-exe -O ReleaseFast -mcpu=native -lc -L$SIMDUTF/lib -lsimdutf \
//!     --dep utf -Mroot=docs/slop/results/base64-20261030/driver.zig -Mutf=src/root.zig
//!   LD_LIBRARY_PATH=$SIMDUTF/lib taskset -c 2 ./root [samples] [max_size] > out.txt
//!
//! SIMDUTF_FORCE_IMPLEMENTATION=haswell or westmere pins simdutf's kernel.

const std = @import("std");
const utf = @import("utf");
const b64 = utf.base64;

const CRes = extern struct { err: c_int, count: usize };
extern fn simdutf_base64_to_binary(input: [*]const u8, len: usize, out: [*]u8, opts: c_int, last: c_int) CRes;
extern fn simdutf_binary_to_base64(input: [*]const u8, len: usize, out: [*]u8, opts: c_int) usize;

const Op = enum { encode, decode, decode_lines };
const Arm = enum { simdutf, utf, utf_ssse3, utf_generic, utf_scalar, std };

const sizes = [_]usize{ 16, 64, 256, 1024, 4096, 65536, 1 << 20 };

const Input = struct {
    raw: []u8,
    clean: []u8,
    lines: []u8,
};

fn now() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn runOnce(op: Op, arm: Arm, in: Input, out: []u8) usize {
    const src = switch (op) {
        .encode => in.raw,
        .decode => in.clean,
        .decode_lines => in.lines,
    };
    switch (op) {
        .encode => return switch (arm) {
            .simdutf => simdutf_binary_to_base64(src.ptr, src.len, out.ptr, 0),
            .utf => b64.encode(out, src, .{}),
            .utf_ssse3 => b64.encodeWith(.ssse3, .standard, out, src, true),
            .utf_generic => b64.encodeWith(.generic, .standard, out, src, true),
            .utf_scalar => b64.scalar.encode(out, src, .{}),
            .std => std.base64.standard.Encoder.encode(out, src).len,
        },
        .decode, .decode_lines => return switch (arm) {
            .simdutf => simdutf_base64_to_binary(src.ptr, src.len, out.ptr, 0, 0).count,
            .utf => b64.decode(out, src, .{}).count,
            .utf_ssse3 => b64.decodeWith(.ssse3, .standard, out, src, .loose).count,
            .utf_generic => b64.decodeWith(.generic, .standard, out, src, .loose).count,
            .utf_scalar => b64.scalar.decode(out, src, .{}).count,
            .std => if (op == .decode) blk: {
                std.base64.standard.Decoder.decode(out[0..in.raw.len], src) catch unreachable;
                break :blk in.raw.len;
            } else std.base64.standard.decoderWithIgnore("\n").decode(out, src) catch unreachable,
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    _ = args.next();
    const samples = if (args.next()) |s| try std.fmt.parseUnsigned(usize, s, 10) else 10;
    // Optionally only sizes up to this many bytes.
    const max_size = if (args.next()) |s| try std.fmt.parseUnsigned(usize, s, 10) else std.math.maxInt(usize);

    var prng: std.Random.DefaultPrng = .init(42);
    var inputs: [sizes.len]Input = undefined;
    for (sizes, &inputs) |n, *in| {
        in.raw = try gpa.alloc(u8, n);
        prng.random().bytes(in.raw);
        in.clean = try gpa.alloc(u8, b64.encodedLen(n, .{}));
        _ = b64.scalar.encode(in.clean, in.raw, .{});
        // MIME-style lines of 76 characters, each ended by LF.
        in.lines = try gpa.alloc(u8, in.clean.len + in.clean.len / 76);
        var m: usize = 0;
        for (in.clean, 1..) |c, k| {
            in.lines[m] = c;
            m += 1;
            if (k % 76 == 0) {
                in.lines[m] = '\n';
                m += 1;
            }
        }
        in.lines = in.lines[0..m];
    }
    const out = try gpa.alloc(u8, 2 << 20);

    // Check every arm agrees before timing anything.
    for (inputs) |in| {
        for (std.enums.values(Op)) |op| {
            const want = runOnce(op, .utf_scalar, in, out);
            for (std.enums.values(Arm)) |arm| {
                if (runOnce(op, arm, in, out) != want) std.debug.panic("{t} {t} disagrees at {d}", .{ op, arm, in.raw.len });
            }
        }
    }

    var buf: [4096]u8 = undefined;
    var cpu_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    const stdout = &w.interface;
    try stdout.print("goos: linux\ngoarch: amd64\npkg: utf/base64\ncpu: {s}\n", .{cpuName(&cpu_buf)});
    try stdout.flush();
    const arms = std.enums.values(Arm);
    for (0..samples) |s| {
        for (std.enums.values(Op)) |op| {
            for (inputs) |in| {
                if (in.raw.len > max_size) continue;
                const bytes = switch (op) {
                    .encode => in.raw.len,
                    .decode => in.clean.len,
                    .decode_lines => in.lines.len,
                };
                // Rotate the starting arm each sample.
                for (0..arms.len) |k| {
                    const arm = arms[(k + s) % arms.len];
                    // Enough iterations for about 20 ms.
                    var iters: usize = 1;
                    while (true) {
                        const t0 = now();
                        for (0..iters) |_| std.mem.doNotOptimizeAway(runOnce(op, arm, in, out));
                        const dt = now() - t0;
                        if (dt > 20 * std.time.ns_per_ms) {
                            const ns = @as(f64, @floatFromInt(dt)) / @as(f64, @floatFromInt(iters));
                            const mbs = @as(f64, @floatFromInt(bytes)) / ns * 1e3;
                            try stdout.print("Benchmark{s}/size={d}/arm={t}-4\t{d}\t{d:.2} ns/op\t{d:.2} MB/s\n", .{ opName(op), in.raw.len, arm, iters, ns, mbs });
                            break;
                        }
                        iters = if (dt < std.time.ns_per_ms) iters * 10 else iters * 2;
                    }
                }
            }
        }
        try stdout.flush();
    }
}

fn opName(op: Op) []const u8 {
    return switch (op) {
        .encode => "Encode",
        .decode => "Decode",
        .decode_lines => "DecodeLines",
    };
}

fn cpuName(buf: []u8) []const u8 {
    const fd = std.os.linux.open("/proc/cpuinfo", .{}, 0);
    defer _ = std.os.linux.close(@intCast(fd));
    const n = std.os.linux.read(@intCast(fd), buf.ptr, buf.len);
    const text = buf[0..n];
    const start = (std.mem.indexOf(u8, text, "model name\t: ") orelse return "unknown") + 13;
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return text[start..end];
}
