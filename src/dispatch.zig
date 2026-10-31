//! Runtime ISA dispatch on x86-64: one build that runs the AVX-512, AVX2,
//! SSE, or generic kernels, whichever the CPU it runs on has.
//!
//! Zig has no per-function target attribute, so build.zig compiles this
//! package once more for each tier above the target's own ISA, as an object
//! for that tier's CPU model, and links the objects into the `utf` module.
//! Each wired public function goes through `call`: in a tier's object, `call`
//! exports the function under a name for that tier; in the main build, it
//! calls the export for the best tier the CPU has, found once with `cpuid`,
//! or runs the function in place when the target's own ISA is the best.
//! Arguments and results cross as machine words under the C calling
//! convention. A call costs a load, a compare, a jump, and a call into the
//! object: 1.0-1.7 ns (docs/slop/results/dispatch-20261031.md).
//!
//! build.zig turns this on for generic x86-64 targets (`-Dcpu=baseline`,
//! `x86_64_v2`, `x86_64_v3`, or a cross target with no CPU given) and leaves
//! it off for a named or native CPU, where `simd.isa` chooses at comptime as
//! before; `-Ddispatch` overrides. aarch64 always chooses at comptime.

const std = @import("std");
const builtin = @import("builtin");
const simd = @import("simd.zig");
const root = @import("root.zig");
const Isa = simd.Isa;
const Tier = simd.Tier;
const above = simd.dispatchAbove;
const x86 = std.Target.x86;

const options = @import("dispatch_options");
/// `off`: no dispatch, `simd.isa` only. `main`: the build consumers call,
/// which dispatches. `kernel`: one tier's object, which exports.
const role = std.meta.stringToEnum(enum { off, main, kernel }, @tagName(options.role)).?;
/// The objects linked into a dispatching build.
const linked = if (role == .main) above(simd.isa) else &[_]Tier{};

/// Runs `f(args)` on the best kernels the CPU has. A public function wires
/// itself up by moving its body into a private `f` and returning
/// `dispatch.call(@src(), f, .{ args })`; `@src()` names the export, so each
/// public function must call it directly. Arguments are slices, pointers,
/// integers, enums, bools, and packed structs, which travel as words, and
/// other types, which travel by pointer, up to six words in all; results
/// are void, a word, or a struct of up to two word fields, like `Result`.
pub inline fn call(
    comptime src: std.builtin.SourceLocation,
    comptime f: anytype,
    args: std.meta.ArgsTuple(@TypeOf(f)),
) Return(f) {
    switch (role) {
        // The result goes through words, so it is built from scalars once:
        // returned as it is, a kernel that returns a struct from more than
        // one place writes each into its own stack slot and the caller
        // copies the chosen one with one 16-byte load, which cannot forward
        // from the narrower stores that wrote it, 5-10 ns a call
        // (docs/slop/results/dispatch-wave3-20261031.md).
        .off => return fromWords(Return(f), toResult(@call(.always_inline, f, args))),
        .kernel => {
            comptime @export(&Entry(f).entry, .{ .name = symbol(src, simd.isa), .visibility = .hidden });
            return @call(.always_inline, f, args);
        },
        .main => {
            const c = if (pin) @intFromEnum(pinned) + 1 else cached.load(.monotonic);
            var w: [6]usize = undefined;
            comptime var i = 0;
            inline for (@typeInfo(@TypeOf(f)).@"fn".params, 0..) |p, k| {
                i += toWords(p.type.?, &args[k], w[i..]);
            }
            // Every path yields the result as a scalar and the struct is
            // built once, after they join: a struct from each path would
            // join as a choice of stack slots, copied out whole (the stall
            // above).
            const r: Ret(Return(f)) = r: {
                if (c == 0) break :r @call(.never_inline, Init(src, f).call, .{ w[0], w[1], w[2], w[3], w[4], w[5] });
                inline for (linked) |t| {
                    if (c == @intFromEnum(t.isa) + 1) {
                        const name = comptime symbol(src, t.isa);
                        const entry = @extern(*const EntryFn(Return(f)), .{ .name = name, .visibility = .hidden });
                        break :r entry(w[0], w[1], w[2], w[3], w[4], w[5]);
                    }
                }
                // Out of line, so what inlines into the caller is only the
                // compares and the calls.
                break :r @call(.never_inline, Entry(f).entry, .{ w[0], w[1], w[2], w[3], w[4], w[5] });
            };
            return fromWords(Return(f), r);
        },
    }
}

/// The first dispatched call, out of line so the callers' copies of `call`
/// keep only the hot path.
/// It takes the words, as the entries do, so the caller keeps nothing on
/// the stack for it.
fn Init(comptime src: std.builtin.SourceLocation, comptime f: anytype) type {
    return struct {
        fn call(w0: usize, w1: usize, w2: usize, w3: usize, w4: usize, w5: usize) callconv(.c) Ret(Return(f)) {
            @branchHint(.cold);
            _ = init();
            return toResult(dispatch.call(src, f, argsFromWords(f, .{ w0, w1, w2, w3, w4, w5 })));
        }
    };
}

const dispatch = @This();

fn Return(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

/// Two words, the first in the low half: on x86-64 a `u128`, which comes
/// back in two registers under the C calling convention, and which LLVM,
/// unlike a struct of two words, keeps in registers instead of a stack slot.
const Words = @Int(.unsigned, 2 * @bitSizeOf(usize));

/// What an entry returns for a function returning `R`: `R` itself where the
/// C calling convention has it, so the call can be a tail call, else words.
fn Ret(comptime R: type) type {
    return if (R == void or R == bool or R == usize) R else Words;
}

fn EntryFn(comptime R: type) type {
    return fn (usize, usize, usize, usize, usize, usize) callconv(.c) Ret(R);
}

fn Entry(comptime f: anytype) type {
    return struct {
        fn entry(w0: usize, w1: usize, w2: usize, w3: usize, w4: usize, w5: usize) callconv(.c) Ret(Return(f)) {
            return toResult(@call(.always_inline, f, argsFromWords(f, .{ w0, w1, w2, w3, w4, w5 })));
        }
    };
}

inline fn argsFromWords(comptime f: anytype, w: [6]usize) std.meta.ArgsTuple(@TypeOf(f)) {
    var args: std.meta.ArgsTuple(@TypeOf(f)) = undefined;
    comptime var i = 0;
    inline for (@typeInfo(@TypeOf(f)).@"fn".params, 0..) |p, k| {
        args[k] = argFromWords(p.type.?, w[i..]);
        i += comptime wordCount(p.type.?);
    }
    comptime std.debug.assert(i <= w.len);
    return args;
}

/// How an argument of type `T` travels: a slice as its pointer and length,
/// a scalar as one word, anything else as a pointer to it.
const Pass = enum { slice, word, ref };

fn pass(comptime T: type) Pass {
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice) .slice else .word,
        .int => |n| if (n.bits <= @bitSizeOf(usize)) .word else .ref,
        .bool, .@"enum" => .word,
        .@"struct" => |s| if (s.layout == .@"packed" and @bitSizeOf(T) <= @bitSizeOf(usize)) .word else .ref,
        else => .ref,
    };
}

fn wordCount(comptime T: type) usize {
    return if (pass(T) == .slice) 2 else 1;
}

inline fn toWords(comptime T: type, x: *const T, w: []usize) usize {
    switch (comptime pass(T)) {
        .slice => {
            w[0] = @intFromPtr(x.ptr);
            w[1] = x.len;
        },
        .ref => w[0] = @intFromPtr(x),
        .word => w[0] = toWord(x.*),
    }
    return comptime wordCount(T);
}

inline fn argFromWords(comptime T: type, w: []const usize) T {
    return switch (comptime pass(T)) {
        .slice => @as(@TypeOf(@as(T, undefined).ptr), @ptrFromInt(w[0]))[0..w[1]],
        .ref => @as(*const T, @ptrFromInt(w[0])).*,
        .word => fromWord(T, w[0]),
    };
}

inline fn toWord(x: anytype) usize {
    const T = @TypeOf(x);
    return switch (@typeInfo(T)) {
        .pointer => @intFromPtr(x),
        .bool => @intFromBool(x),
        .@"enum" => @intCast(@intFromEnum(x)),
        .int => |n| @as(@Int(.unsigned, @bitSizeOf(usize)), @as(@Int(.unsigned, n.bits), @bitCast(x))),
        .@"struct" => @as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(x)),
        else => @compileError("dispatch: no word for " ++ @typeName(T)),
    };
}

inline fn fromWord(comptime T: type, w: usize) T {
    return switch (@typeInfo(T)) {
        .pointer => @ptrFromInt(w),
        .bool => w != 0,
        .@"enum" => @enumFromInt(w),
        .int => |n| @bitCast(@as(@Int(.unsigned, n.bits), @truncate(w))),
        .@"struct" => @bitCast(@as(@Int(.unsigned, @bitSizeOf(T)), @truncate(w))),
        else => @compileError("dispatch: no word for " ++ @typeName(T)),
    };
}

inline fn toResult(r: anytype) Ret(@TypeOf(r)) {
    const R = @TypeOf(r);
    if (Ret(R) == R) return r;
    return switch (@typeInfo(R)) {
        .@"struct" => |s| blk: {
            if (s.fields.len > 2) @compileError("dispatch: more than two fields in " ++ @typeName(R));
            var w: Words = 0;
            inline for (s.fields, 0..) |field, k| {
                w |= @as(Words, toWord(@field(r, field.name))) << (@bitSizeOf(usize) * k);
            }
            break :blk w;
        },
        else => toWord(r),
    };
}

inline fn fromWords(comptime R: type, w: Ret(R)) R {
    if (Ret(R) == R) return w;
    return switch (@typeInfo(R)) {
        .@"struct" => |s| blk: {
            var r: R = undefined;
            inline for (s.fields, 0..) |field, k| {
                @field(r, field.name) = fromWord(field.type, @truncate(w >> (@bitSizeOf(usize) * k)));
            }
            break :blk r;
        },
        else => fromWord(R, @truncate(w)),
    };
}

/// The export for `src`'s function in `isa`'s object, such as
/// `utf_1a2b3c4d_avx2_validate_utf8`. The prefix is unique to this build of
/// the package, so two builds of it can link into one program.
fn symbol(comptime src: std.builtin.SourceLocation, comptime isa: Isa) [:0]const u8 {
    comptime {
        var file: []const u8 = src.file;
        if (std.mem.endsWith(u8, file, ".zig")) file = file[0 .. file.len - 4];
        var name: [file.len]u8 = undefined;
        for (&name, file) |*c, s| c.* = if (std.ascii.isAlphanumeric(s)) s else '_';
        const n = name;
        return options.prefix ++ "_" ++ @tagName(isa) ++ "_" ++ n ++ "_" ++ src.fn_name;
    }
}

// A safety panic in a tier's object goes to the main build's panic handler,
// which is the program's, so the objects carry no panic machinery of their
// own. This file is each object's root.
pub const panic = std.debug.FullPanic(forwardPanic);

fn forwardPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    const PanicFn = fn ([*]const u8, usize, usize) callconv(.c) noreturn;
    const main = @extern(*const PanicFn, .{ .name = options.prefix ++ "_panic", .visibility = .hidden });
    main(msg.ptr, msg.len, ret_addr orelse @returnAddress());
}

fn panicEntry(ptr: [*]const u8, len: usize, ret_addr: usize) callconv(.c) noreturn {
    std.builtin.panic.call(ptr[0..len], ret_addr);
}

comptime {
    switch (role) {
        .off => {},
        .main => @export(&panicEntry, .{ .name = options.prefix ++ "_panic", .visibility = .hidden }),
        // Every public function, so each `call` in them exports.
        .kernel => {
            referenceAll(root);
            _ = &kernelIsa;
        },
    }
}

fn referenceAll(comptime T: type) void {
    inline for (@typeInfo(T).@"struct".decls) |d| {
        const x = @field(T, d.name);
        switch (@typeInfo(@TypeOf(x))) {
            .@"fn" => |info| if (!info.is_generic) {
                _ = &x;
            },
            .type => if (@typeInfo(x) == .@"struct" and x != T) referenceAll(x),
            else => {},
        }
    }
}

/// The best tier this CPU has among the linked ones, found on the first
/// call. Stored as the tag plus one, so zero means not yet.
var cached: std.atomic.Value(u8) = .init(0);

/// In this repository's own test builds (`dispatch_options.pin`), the tier
/// every call takes: the target's own ISA unless a test sets it, so the
/// tests at each `-Dcpu` check that level's kernels, and `forEachLevel`
/// runs a test once per tier.
var pinned: Isa = simd.isa;
const pin = builtin.is_test and options.pin;

/// The ISA calls dispatch to.
pub inline fn level() Isa {
    if (pin) return pinned;
    const c = cached.load(.monotonic);
    if (c != 0) return @enumFromInt(c - 1);
    return init();
}

noinline fn init() Isa {
    @branchHint(.cold);
    const l = best(detect());
    cached.store(@intFromEnum(l) + 1, .monotonic);
    return l;
}

/// The best linked tier `cpu` supports, else the target's own ISA.
fn best(features: std.Target.Cpu.Feature.Set) Isa {
    inline for (linked) |t| {
        if (supports(features, t)) return t.isa;
    }
    return simd.isa;
}

fn supports(features: std.Target.Cpu.Feature.Set, t: Tier) bool {
    for (t.need) |f| {
        if (!x86.featureSetHas(features, f)) return false;
    }
    return true;
}

/// The features of the CPU this runs on that any tier needs, from `cpuid`,
/// with the AVX and AVX-512 ones only where the OS saves their registers.
fn detect() std.Target.Cpu.Feature.Set {
    return if (builtin.cpu.arch == .x86_64) detectX86() else .empty;
}

/// Feature bits in `cpuid` leaves 1 and 7.
const Bit = struct { x86.Feature, u5 };
const leaf1_ecx = [_]Bit{
    .{ .sse3, 0 },   .{ .ssse3, 9 },   .{ .fma, 12 },   .{ .cx16, 13 }, .{ .sse4_1, 19 }, .{ .sse4_2, 20 },
    .{ .movbe, 22 }, .{ .popcnt, 23 }, .{ .xsave, 26 }, .{ .avx, 28 },  .{ .f16c, 29 },
};
const leaf7_ebx = [_]Bit{
    .{ .bmi, 3 },       .{ .avx2, 5 },      .{ .bmi2, 8 },      .{ .avx512f, 16 },
    .{ .avx512dq, 17 }, .{ .avx512cd, 28 }, .{ .avx512bw, 30 }, .{ .avx512vl, 31 },
};
const leaf7_ecx = [_]Bit{
    .{ .avx512vbmi, 1 }, .{ .avx512vbmi2, 6 }, .{ .gfni, 8 }, .{ .avx512bitalg, 12 }, .{ .avx512vpopcntdq, 14 },
};

fn detectX86() std.Target.Cpu.Feature.Set {
    var set: std.Target.Cpu.Feature.Set = .empty;
    const max = cpuid(0, 0)[0];
    const l1 = cpuid(1, 0);
    for (leaf1_ecx) |b| {
        if (l1[2] >> b[1] & 1 != 0) set.addFeature(@intFromEnum(b[0]));
    }
    if (max >= 7) {
        const l7 = cpuid(7, 0);
        for (leaf7_ebx) |b| {
            if (l7[1] >> b[1] & 1 != 0) set.addFeature(@intFromEnum(b[0]));
        }
        for (leaf7_ecx) |b| {
            if (l7[2] >> b[1] & 1 != 0) set.addFeature(@intFromEnum(b[0]));
        }
    }
    if (cpuid(0x80000000, 0)[0] >= 0x80000001) {
        const e1 = cpuid(0x80000001, 0);
        if (e1[2] & 1 != 0) set.addFeature(@intFromEnum(x86.Feature.sahf));
        if (e1[2] >> 5 & 1 != 0) set.addFeature(@intFromEnum(x86.Feature.lzcnt));
    }
    // XCR0: SSE and AVX state (bits 1, 2); AVX-512 opmask and upper ZMM
    // state (bits 5, 6, 7). Readable only when the OS set OSXSAVE.
    const xcr0: u32 = if (l1[2] >> 27 & 1 != 0) xgetbv() else 0;
    if (xcr0 & 0x6 != 0x6) {
        for ([_]x86.Feature{ .avx, .avx2, .fma, .f16c }) |f| set.removeFeature(@intFromEnum(f));
    }
    if (xcr0 & 0xE6 != 0xE6) {
        for (simd.tiers[0].need) |f| {
            if (std.mem.startsWith(u8, @tagName(f), "avx512")) set.removeFeature(@intFromEnum(f));
        }
    }
    return set;
}

fn cpuid(leaf: u32, sub: u32) [4]u32 {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf),
          [_] "{ecx}" (sub),
    );
    return .{ eax, ebx, ecx, edx };
}

fn xgetbv() u32 {
    return asm volatile (
        \\ xor %%ecx, %%ecx
        \\ xgetbv
        : [_] "={eax}" (-> u32),
        :
        : .{ .edx = true, .ecx = true });
}

/// Runs `f(args)` once for the target's own ISA and once for each linked
/// tier this CPU has, with every dispatched call taking that tier. For tests
/// of wired functions, so one test build checks every kernel through the
/// path consumers call.
pub fn forEachLevel(comptime f: anytype, args: anytype) !void {
    comptime std.debug.assert(pin);
    defer pinned = simd.isa;
    const cpu = detect();
    pinned = simd.isa;
    try @call(.auto, f, args);
    inline for (linked) |t| {
        if (supports(cpu, t)) {
            pinned = t.isa;
            try @call(.auto, f, args);
        }
    }
}

/// The ISA of the kernels a dispatched call runs, read inside them.
fn kernelIsa() Isa {
    return call(@src(), isaHere, .{});
}

fn isaHere() Isa {
    return simd.isa;
}

const testing = std.testing;
const scalar = @import("scalar.zig");
const validate = @import("validate.zig");
const Result = @import("result.zig").Result;

test "arguments and results cross as words unchanged" {
    const Opts = struct { a: u8, b: bool };
    const P = packed struct(u8) { x: u3, y: u5 };
    const E = enum(u8) { one = 1, two = 2 };
    const s: []const u16 = &.{ 1, 2, 3 };
    var w: [6]usize = undefined;
    var i: usize = 0;
    const o: Opts = .{ .a = 9, .b = true };
    const p: P = .{ .x = 5, .y = 17 };
    const n: i32 = -4;
    i += toWords([]const u16, &s, w[i..]);
    i += toWords(Opts, &o, w[i..]);
    i += toWords(P, &p, w[i..]);
    i += toWords(i32, &n, w[i..]);
    try testing.expectEqual(5, i);
    try testing.expectEqualSlices(u16, s, argFromWords([]const u16, w[0..]));
    try testing.expectEqual(o, argFromWords(Opts, w[2..]));
    try testing.expectEqual(p, argFromWords(P, w[3..]));
    try testing.expectEqual(n, argFromWords(i32, w[4..]));
    const r = Result.fail(.surrogate, 1 << 40);
    try testing.expectEqual(r, fromWords(Result, toResult(r)));
    try testing.expectEqual(E.two, fromWords(E, toResult(E.two)));
    try testing.expectEqual(true, fromWords(bool, toResult(true)));
}

test "detect agrees with std's CPU detection" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const native = (try std.zig.system.resolveTargetQuery(testing.io, .{})).cpu;
    const cpu = detect();
    for (simd.tiers) |t| try testing.expectEqual(supports(native.features, t), supports(cpu, t));
    try testing.expectEqual(best(native.features), best(cpu));
}

test "above lists the tiers better than a build's own ISA" {
    try testing.expectEqual(3, above(.generic).len);
    try testing.expectEqual(2, above(.sse).len);
    try testing.expectEqual(Isa.avx2, above(.sse)[0 + 1].isa);
    try testing.expectEqual(1, above(.avx2).len);
    try testing.expectEqual(0, above(.avx512).len);
    try testing.expectEqual(0, above(.neon).len);
}

var levels_run: usize = 0;

fn checkKernelIsa() !void {
    try testing.expectEqual(level(), kernelIsa());
    levels_run += 1;
}

test "each tier's calls run that tier's kernels" {
    levels_run = 0;
    try forEachLevel(checkKernelIsa, .{});
    const cpu = detect();
    var want: usize = 1;
    for (linked) |t| want += @intFromBool(supports(cpu, t));
    try testing.expectEqual(want, levels_run);
}

fn checkUtf8(bytes: []const u8) !void {
    const want = scalar.validateUtf8(bytes);
    try testing.expectEqual(want, validate.utf8WithErrors(bytes));
    try testing.expectEqual(want.err == .none, validate.utf8(bytes));
}

fn utf8Cases() !void {
    // Each error kind at every position in and across blocks and at the end,
    // after ASCII and after multibyte text.
    const errors = [_][]const u8{
        "\xf8",     "\xc3",         "\xe2\x82",         "\x80",
        "\xc0\x80", "\xe0\x9f\xbf", "\xf4\x90\x80\x80", "\xed\xa0\x80",
    };
    const fill = [_][]const u8{ "a", "\xc3\xa9", "\xe4\xb8\xad", "\xf0\x9f\x98\x80" };
    var buf: [5 * 64 + 20]u8 = undefined;
    for (fill) |text| {
        for (0..buf.len - 8) |len| {
            var j: usize = 0;
            while (j + text.len <= len) : (j += text.len) @memcpy(buf[j..][0..text.len], text);
            @memset(buf[j..len], 'b');
            try checkUtf8(buf[0..len]);
            for (errors) |e| {
                if (len + e.len > buf.len) continue;
                @memcpy(buf[len..][0..e.len], e);
                try checkUtf8(buf[0 .. len + e.len]);
                @memset(buf[len + e.len ..], 'c');
                try checkUtf8(buf[0..@min(buf.len, len + e.len + 70)]);
            }
        }
    }
}

test "validate.utf8 and utf8WithErrors match scalar on every tier" {
    try forEachLevel(utf8Cases, .{});
}
