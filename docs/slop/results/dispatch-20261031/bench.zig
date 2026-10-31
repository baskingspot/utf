//! Dispatch overhead: validate.utf8 and utf8WithErrors, one build per arm.
const std = @import("std");
const testingx = @import("testingx");
const utf = @import("utf");
const B = testingx.B;

const texts = .{
    .{ "ascii", "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs! 0123456789 " },
    .{ "latin", "Le cœur a ses raisons que la raison ne connaît point. Où êtes-vous allés? Ça va très bien, merci. Die Größe der Bäume überrascht. " },
    .{ "chinese", "中文是世界上使用人数最多的语言之一，汉字有着悠久的历史和丰富的文化内涵。" },
    .{ "emoji", "😀😃😄😁😆😅🤣😂🙂🙃😉😊😇🥰😍🤩😘😗☺😚😙🥲😋😛😜🤪😝🤑🤗🤭" },
};
const sizes = [_]usize{ 8, 16, 32, 64, 256, 1024, 4096, 65536 };

var inputs: [texts.len][sizes.len][]u8 = undefined;

/// `size` bytes of repeated `seed`, cut at a character boundary and padded
/// with spaces, so every input is valid.
fn makeText(a: std.mem.Allocator, seed: []const u8, size: usize) ![]u8 {
    // 16 bytes past a 64-byte boundary, as the harness's inputs can be.
    const buf = (try a.alignedAlloc(u8, .@"64", size + 16))[16..];
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        const n = std.unicode.utf8ByteSequenceLength(seed[j]) catch unreachable;
        if (i + n > size) break;
        @memcpy(buf[i..][0..n], seed[j..][0..n]);
        i += n;
        j = (j + n) % seed.len;
    }
    @memset(buf[i..], ' ');
    return buf;
}

pub fn benchmarkMain(b: *B) !void {
    @setEvalBranchQuota(100_000);
    const a = std.heap.page_allocator;
    inline for (texts, 0..) |t, ti| {
        for (sizes, 0..) |size, si| {
            inputs[ti][si] = try makeText(a, t[1], size);
            std.debug.assert(utf.scalar.validateUtf8(inputs[ti][si]).err == .none);
        }
    }
    inline for (texts, 0..) |t, ti| {
        inline for (sizes, 0..) |size, si| {
            const suffix = "/text=" ++ t[0] ++ std.fmt.comptimePrint("/size={d}", .{size});
            try b.add("ValidateUtf8" ++ suffix, Run(ti, si, false).run);
            try b.add("ValidateUtf8Err" ++ suffix, Run(ti, si, true).run);
        }
    }
}

fn Run(comptime ti: usize, comptime si: usize, comptime with_errors: bool) type {
    return struct {
        fn run(b: *B) !void {
            const in = inputs[ti][si];
            b.setBytes(@intCast(in.len));
            var ok: usize = 0;
            defer b.keepAlive(ok);
            while (try b.loop()) {
                var p: []const u8 = in;
                std.mem.doNotOptimizeAway(&p);
                const r = if (with_errors) utf.validate.utf8WithErrors(p).err == .none else utf.validate.utf8(p);
                ok += @intFromBool(r);
            }
            if (ok == 0) return b.fail();
        }
    };
}
