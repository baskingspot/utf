//! Base64 throughput, interleaved A/B: this tree's kernels (`utf`), another
//! tree's (`old`, for before and after), simdutf's kernels by name, Zig's
//! std.base64, and the scalar reference. Arms run one sample each in turn,
//! the first rotating, and print Go benchmark lines for benchstat. Every
//! arm is called through a function pointer, so none is inlined into the
//! timing loop. Speed is input bytes per second: binary bytes for encode,
//! base64 characters for decode.
//!
//! From the repository root, with OLD a checkout of the baseline commit
//! (`git worktree add /tmp/old <commit>`):
//!
//!   d=docs/slop/results/base64-20261031 lib=$(pkg-config --variable=libdir simdutf)
//!   c++ -O3 -std=c++20 -shared -fPIC -o /tmp/libshim.so \
//!     $d/shim.cpp $(pkg-config --cflags --libs simdutf)
//!   zig build-exe -O ReleaseFast -mcpu=native -lc -L/tmp -lshim \
//!     --dep utf --dep old -Mroot=$d/driver.zig --dep dispatch_options \
//!     -Mutf=src/root.zig -Mold=$OLD/src/root.zig -Mdispatch_options=$d/dispatch_options.zig
//!   LD_LIBRARY_PATH=/tmp:$lib taskset -c 2 ./root SAMPLES MAX_SIZE ARM... > out.txt
//!   benchstat -col /arm out.txt
//!
//! Arms: `utf` and `old` (the native kernel), `utf.<isa>` and `old.<isa>`
//! (one kernel), `simdutf` (its runtime choice) and `simdutf.<kernel>`
//! (`icelake`, `haswell`, `westmere`, `fallback`), `std`, and `scalar`. OPS
//! (default `encode,decode,lines`) picks the operations; `lines` decodes the
//! same base64 in 76-character lines ended by LF, and `crlf` by CR LF, as
//! MIME writes it. SIZES
//! (comma-separated binary sizes) replaces the default sizes. With ADJACENT
//! set, each input is copied to a buffer and the output placed right after
//! it, 16-byte aligned, as an arena hands out an input and then its output.
//! OFFSET puts each input that many bytes past a 64-byte boundary.

const std = @import("std");
const utf = @import("utf");
const old = @import("old");

extern fn shim_impl(name: [*:0]const u8) ?*const anyopaque;
extern fn shim_encode(impl: *const anyopaque, in: [*]const u8, n: usize, out: [*]u8) usize;
extern fn shim_decode(impl: *const anyopaque, in: [*]const u8, n: usize, out: [*]u8) usize;

const Op = enum { encode, decode, lines, crlf };

const default_sizes = [_]usize{ 16, 32, 64, 256, 1024, 4096, 65536, 1 << 20 };

const Input = struct { raw: []u8, clean: []u8, lines: []u8, crlf: []u8 };

/// One arm: a Zig function, or a simdutf kernel.
const Arm = struct {
    name: []const u8,
    encode: ?*const fn ([]u8, []const u8) usize = null,
    decode: ?*const fn ([]u8, []const u8) usize = null,
    simdutf: ?*const anyopaque = null,

    fn run(arm: Arm, op: Op, src: []const u8, out: []u8) usize {
        if (arm.simdutf) |impl| return switch (op) {
            .encode => shim_encode(impl, src.ptr, src.len, out.ptr),
            .decode, .lines, .crlf => shim_decode(impl, src.ptr, src.len, out.ptr),
        };
        return switch (op) {
            .encode => arm.encode.?(out, src),
            .decode, .lines, .crlf => arm.decode.?(out, src),
        };
    }
};

/// The arms of one tree of this package: `prefix`, and `prefix.<isa>` for
/// each kernel the build can run.
fn treeArms(comptime prefix: []const u8, comptime b64: type) []const Arm {
    comptime var arms: []const Arm = &.{zigArm(prefix, b64, null)};
    inline for (comptime std.enums.values(b64.Isa)) |isa| {
        if (comptime isa.supported()) arms = arms ++ .{zigArm(prefix ++ "." ++ @tagName(isa), b64, isa)};
    }
    return arms;
}

fn zigArm(comptime name: []const u8, comptime b64: type, comptime isa: ?b64.Isa) Arm {
    const F = struct {
        fn encode(out: []u8, src: []const u8) usize {
            if (isa) |k| return b64.encodeWith(k, .standard, out, src, true);
            return b64.encode(out, src, .{});
        }
        fn decode(out: []u8, src: []const u8) usize {
            const r = if (isa) |k| b64.decodeWith(k, .standard, out, src, .loose) else b64.decode(out, src, .{});
            return if (r.err == .none) r.count else std.math.maxInt(usize);
        }
    };
    return .{ .name = name, .encode = F.encode, .decode = F.decode };
}

const fixed_arms = treeArms("utf", utf.base64) ++ treeArms("old", old.base64) ++ [_]Arm{
    .{ .name = "scalar", .encode = struct {
        fn f(out: []u8, src: []const u8) usize {
            return utf.base64.scalar.encode(out, src, .{});
        }
    }.f, .decode = struct {
        fn f(out: []u8, src: []const u8) usize {
            const r = utf.base64.scalar.decode(out, src, .{});
            return if (r.err == .none) r.count else std.math.maxInt(usize);
        }
    }.f },
    .{
        .name = "std",
        .encode = struct {
            fn f(out: []u8, src: []const u8) usize {
                return std.base64.standard.Encoder.encode(out, src).len;
            }
        }.f,
        .decode = struct {
            fn f(out: []u8, src: []const u8) usize {
                // std rejects whitespace unless told which to ignore.
                if (std.mem.indexOfScalar(u8, src, '\n') == null) {
                    const n = std.base64.standard.Decoder.calcSizeForSlice(src) catch unreachable;
                    std.base64.standard.Decoder.decode(out[0..n], src) catch unreachable;
                    return n;
                }
                return std.base64.standard.decoderWithIgnore("\r\n").decode(out, src) catch unreachable;
            }
        }.f,
    },
};

fn now() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    _ = args.next();
    const samples = try std.fmt.parseUnsigned(usize, args.next() orelse "10", 10);
    const max_size = try std.fmt.parseUnsigned(usize, args.next() orelse "1048576", 10);
    var arms: std.ArrayList(Arm) = .empty;
    while (args.next()) |name| {
        if (std.mem.startsWith(u8, name, "simdutf")) {
            const kernel = if (std.mem.indexOfScalar(u8, name, '.')) |dot| name[dot + 1 ..] else "";
            const z = try gpa.dupeZ(u8, kernel);
            const impl = if (kernel.len == 0) shim_impl("icelake") orelse shim_impl("haswell") else shim_impl(z);
            try arms.append(gpa, .{ .name = name, .simdutf = impl orelse std.debug.panic("no simdutf kernel {s}", .{name}) });
            continue;
        }
        for (fixed_arms) |arm| {
            if (std.mem.eql(u8, arm.name, name)) break try arms.append(gpa, arm);
        } else std.debug.panic("no arm {s}", .{name});
    }
    var ops: std.ArrayList(Op) = .empty;
    var op_names = std.mem.tokenizeScalar(u8, init.environ_map.get("OPS") orelse "encode,decode,lines", ',');
    while (op_names.next()) |name| try ops.append(gpa, std.meta.stringToEnum(Op, name) orelse std.debug.panic("no op {s}", .{name}));

    var sizes: std.ArrayList(usize) = .empty;
    if (init.environ_map.get("SIZES")) |list| {
        var it = std.mem.tokenizeScalar(u8, list, ',');
        while (it.next()) |n| try sizes.append(gpa, try std.fmt.parseUnsigned(usize, n, 10));
    } else try sizes.appendSlice(gpa, &default_sizes);

    var prng: std.Random.DefaultPrng = .init(42);
    const inputs = try gpa.alloc(Input, sizes.items.len);
    for (sizes.items, inputs) |n, *in| {
        in.raw = try gpa.alloc(u8, n);
        prng.random().bytes(in.raw);
        in.clean = try gpa.alloc(u8, utf.base64.encodedLen(n, .{}));
        _ = utf.base64.scalar.encode(in.clean, in.raw, .{});
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
        in.crlf = try gpa.alloc(u8, in.clean.len + in.clean.len / 76 * 2);
        m = 0;
        for (in.clean, 1..) |c, k| {
            in.crlf[m] = c;
            m += 1;
            if (k % 76 == 0) {
                in.crlf[m..][0..2].* = "\r\n".*;
                m += 2;
            }
        }
        in.crlf = in.crlf[0..m];
    }
    const out = try gpa.alloc(u8, 2 << 20);
    const adjacent = init.environ_map.get("ADJACENT") != null;
    const fresh = init.environ_map.get("FRESH") != null;
    const offset = try std.fmt.parseUnsigned(usize, init.environ_map.get("OFFSET") orelse "0", 10);
    const adj = try gpa.alignedAlloc(u8, .@"64", 5 << 20);

    // Every arm must agree with the scalar reference before anything is timed.
    const scalar_arm = fixed_arms[fixed_arms.len - 2];
    for (inputs) |in| {
        for (std.enums.values(Op)) |op| {
            const src = source(op, in);
            const want = scalar_arm.run(op, src, out);
            const want_hash = std.hash.Wyhash.hash(0, out[0..want]);
            for (arms.items) |arm| {
                @memset(out, 0xaa);
                const got = arm.run(op, src, out);
                if (got != want or std.hash.Wyhash.hash(0, out[0..got]) != want_hash)
                    std.debug.panic("{s} {t} disagrees at {d}", .{ arm.name, op, in.raw.len });
            }
        }
    }

    var buf: [4096]u8 = undefined;
    var cpu_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    const stdout = &w.interface;
    try stdout.print("goos: linux\ngoarch: amd64\npkg: utf/base64\ncpu: {s}\n", .{cpuName(&cpu_buf)});
    try stdout.flush();
    for (0..samples) |s| {
        for (ops.items) |op| {
            for (inputs) |in| {
                if (in.raw.len > max_size) continue;
                const src, const dst = if (adjacent or offset != 0) blk: {
                    const s0 = source(op, in);
                    @memcpy(adj[offset..][0..s0.len], s0);
                    break :blk .{ adj[offset..][0..s0.len], if (adjacent) adj[std.mem.alignForward(usize, offset + s0.len, 16)..] else out };
                } else .{ source(op, in), out };
                const exact = if (fresh) try std.heap.page_allocator.alloc(u8, src.len / 3 * 4 + 64) else dst;
                defer if (fresh) std.heap.page_allocator.free(exact);
                for (0..arms.items.len) |k| {
                    const arm = arms.items[(k + s) % arms.items.len];
                    // Enough iterations for about 20 ms.
                    var iters: usize = 1;
                    while (true) {
                        const t0 = now();
                        for (0..iters) |_| {
                            std.mem.doNotOptimizeAway(src.ptr);
                            std.mem.doNotOptimizeAway(arm.run(op, src, exact));
                        }
                        const dt = now() - t0;
                        if (dt > 20 * std.time.ns_per_ms) {
                            const ns = @as(f64, @floatFromInt(dt)) / @as(f64, @floatFromInt(iters));
                            const mbs = @as(f64, @floatFromInt(src.len)) / ns * 1e3;
                            try stdout.print("Benchmark{s}/size={d}/arm={s}-4\t{d}\t{d:.2} ns/op\t{d:.2} MB/s\n", .{ opName(op), in.raw.len, arm.name, iters, ns, mbs });
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

fn source(op: Op, in: Input) []const u8 {
    return switch (op) {
        .encode => in.raw,
        .decode => in.clean,
        .lines => in.lines,
        .crlf => in.crlf,
    };
}

fn opName(op: Op) []const u8 {
    return switch (op) {
        .encode => "Encode",
        .decode => "Decode",
        .lines => "DecodeLines",
        .crlf => "DecodeCrlf",
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
