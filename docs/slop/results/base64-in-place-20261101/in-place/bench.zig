//! Scratch: base64.decode in place against into a buffer of its own, on the
//! MIME corpus's shape (random bytes, standard padded base64, lines of 76
//! characters ending in CRLF), and on unwrapped base64. Every arm copies the
//! input into a work buffer first, since decoding in place consumes it;
//! `Copy` times the copy alone.

const std = @import("std");
const utf = @import("utf");
const linux = std.os.linux;

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const Arm = enum { Copy, Separate, InPlace };

noinline fn run(arm: Arm, work: []u8, text: []const u8, out: []u8) usize {
    @memcpy(work, text);
    asm volatile (""
        :
        : [p] "r" (work.ptr),
        : .{ .memory = true });
    return switch (arm) {
        .Copy => work.len,
        .Separate => utf.base64.decode(out, work, .{}).count,
        .InPlace => utf.base64.decode(work[0..utf.base64.maxDecodedLen(work.len)], work, .{}).count,
    };
}

fn mmap(len: usize) []u8 {
    const addr = linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    const p: [*]u8 = @ptrFromInt(addr);
    @memset(p[0..len], 0x55);
    return p[0..len];
}

pub fn main() void {
    const sizes = [_]usize{ 16, 64, 256, 4096, 65536, 1048576 };
    var prng: std.Random.DefaultPrng = .init(1);
    const rand = prng.random();
    const rot = blk: {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.REALTIME, &ts);
        break :blk @as(usize, @intCast(ts.nsec)) / 1000;
    };
    var j: usize = 0;
    for ([_]bool{ true, false }) |mime| {
        for (sizes) |n| {
            const raw = mmap(n);
            rand.bytes(raw);
            const enc = mmap(utf.base64.encodedLen(n, .{}));
            const elen = utf.base64.encode(enc, raw, .{});
            const text = mmap(elen + elen / 76 * 2 + 64)[0 .. elen + elen / 76 * 2];
            var m: usize = 0;
            for (enc[0..elen], 1..) |c, k| {
                text[m] = c;
                m += 1;
                if (mime and k % 76 == 0) {
                    text[m..][0..2].* = "\r\n".*;
                    m += 2;
                }
            }
            const t = text[0..m];
            const work = mmap(m + 4096)[0..m];
            const out = mmap(m + 4096)[2048..][0..m];
            // The outputs agree.
            const a = run(.Separate, work, t, out);
            const b = run(.InPlace, work, t, out);
            if (a != n or b != n or !std.mem.eql(u8, out[0..n], raw) or !std.mem.eql(u8, work[0..n], raw)) {
                std.debug.print("# {s}random-{d}: in place differs from a separate buffer\n", .{ if (mime) "mime " else "", n });
            }
            for (0..3) |i| {
                const arm: Arm = @enumFromInt((rot + j + i) % 3);
                // Size the loop to 50 ms from a 5 ms run.
                var iters: usize = 1;
                while (true) {
                    const s = now();
                    for (0..iters) |_| _ = run(arm, work, t, out);
                    const e = now() - s;
                    if (e >= 5_000_000) {
                        iters = @max(1, iters * 50_000_000 / e);
                        break;
                    }
                    iters *= 2;
                }
                const s = now();
                for (0..iters) |_| _ = run(arm, work, t, out);
                const e = now() - s;
                const ns = @as(f64, @floatFromInt(e)) / @as(f64, @floatFromInt(iters));
                std.debug.print("Benchmark{s}{t}/random-{d}\t{d}\t{d:.2} ns/op\t{d:.2} MB/s\n", .{
                    if (mime) "Mime" else "",
                    arm,
                    n,
                    iters,
                    ns,
                    @as(f64, @floatFromInt(m)) * 1000 / ns,
                });
            }
            j += 1;
        }
    }
}
