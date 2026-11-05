//! Runtime ISA dispatch on x86-64: one build that runs the AVX-512, AVX2,
//! SSE, or generic kernels, whichever the CPU it runs on has.
//!
//! Zig has no per-function target attribute, so build.zig compiles this
//! package once more for each tier above the target's own ISA, as an object
//! for that tier's CPU model, and links the objects into the `utf` module.
//! Each wired public function goes through `call`: in a tier's object, `call`
//! exports the function under a name for that tier; in the main build, it
//! calls through a pointer of its own to the export for the best tier the
//! CPU has, found with `cpuid` on its first call, or to the function in
//! place when the target's own ISA is the best. Arguments and results cross
//! as machine words under the C calling convention. A call costs a load and
//! an indirect call into the object: a median 0.9 ns over the kernel in
//! place, where simdutf's dispatch costs 2.6 ns
//! (docs/slop/results/calls-20261031.md).
//!
//! build.zig turns this on for generic x86-64 targets (`-Dcpu=baseline`,
//! `x86_64_v2`, `x86_64_v3`, or a cross target with no CPU given) and leaves
//! it off for a named or native CPU, where `simd.isa` chooses at comptime as
//! before; `-Ddispatch` overrides. aarch64 always chooses at comptime.

const std = @import("std");
const compat = @import("compat.zig");
const builtin = @import("builtin");
const simd = @import("simd.zig");
const root = @import("root.zig");
const bmp = @import("bmp.zig");
const Isa = simd.Isa;
const Tier = simd.Tier;
const above = simd.dispatchAbove;
const x86 = std.Target.x86;

const options = @import("dispatch_options");
/// `off`: no dispatch, `simd.isa` only. `main`: the build consumers call,
/// which dispatches. `kernel`: one tier's object, which exports. `tables`:
/// the object that defines the tables the tiers share (`shared`).
const role = std.meta.stringToEnum(enum { off, main, kernel, tables }, @tagName(options.role)).?;
/// Whether this build is a tier's object, whose kernels are each an entry
/// of their own, called out of line. There a kernel puts its long path out
/// of line too, so that the registers its loops save cost short calls
/// nothing; inline, as elsewhere, the kernel is inlined into its callers,
/// long path and all (docs/slop/results/calls-20261031.md).
pub const exported = role == .kernel;
/// The objects linked into a dispatching build.
const linked = if (role == .main) above(simd.isa) else &[_]Tier{};

/// Runs `f(args)` on the best kernels the CPU has. A public function wires
/// itself up by moving its body into a private `f` and returning
/// `dispatch.call(@src(), f, .{ args })`; `@src()` names the export, so each
/// public function must call it directly. Arguments are slices, pointers,
/// integers, enums, bools, and structs of those that fit in a word, which
/// travel as words, and other types, which travel by pointer, up to six
/// words in all; results
/// are void, a word, a struct of up to two word fields, like `Result`, or
/// one of three, like `ConvertResult` (`Ret`).
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
        // The tables object calls nothing.
        .tables => unreachable,
        .kernel => {
            comptime @export(&Entry(f).entry, .{ .name = symbol(src, simd.isa), .visibility = .hidden });
            return @call(.always_inline, f, args);
        },
        .main => {
            var w: [6]usize = undefined;
            comptime var i = 0;
            inline for (comptime compat.paramTypes(@typeInfo(@TypeOf(f)).@"fn"), 0..) |p, k| {
                i += toWords(p.?, &args[k], w[i..]);
            }
            const S = Slot(src, f);
            // A test that pins another tier sends the call back through
            // `resolve`, which picks the pinned one.
            if (pin and S.isa != pinned) S.entry = &S.resolve;
            // One load and one indirect call, where a cached tier and a
            // jump to its call cost a load, a compare, a table load, an
            // indirect jump, and a direct call
            // (docs/slop/results/calls-20261031.md). The result comes back
            // as a scalar and the struct is built from it here: a struct
            // returned whole joined as a choice of stack slots, copied out
            // with one wide load that cannot forward (the stall above).
            const entry = @atomicLoad(*const EntryFn(Return(f)), &S.entry, .monotonic);
            return fromWords(Return(f), entry(w[0], w[1], w[2], w[3], w[4], w[5]));
        },
    }
}

/// The entry `call` takes for `src`'s function: a pointer to the best tier's
/// export, which starts as `resolve`. Its first call finds the tier and
/// stores the pointer, as an ELF IFUNC would at load time; a racing first
/// call stores the same pointer.
fn Slot(comptime src: std.builtin.SourceLocation, comptime f: anytype) type {
    return struct {
        var entry: *const EntryFn(Return(f)) = &resolve;
        /// The tier `entry` was resolved for, in pinned test builds.
        var isa: Isa = if (pin) simd.isa else undefined;

        fn resolve(w0: usize, w1: usize, w2: usize, w3: usize, w4: usize, w5: usize) callconv(.c) Ret(Return(f)) {
            @branchHint(.cold);
            const l = level();
            const e = pick(l);
            if (pin) isa = l;
            @atomicStore(*const EntryFn(Return(f)), &entry, e, .monotonic);
            return e(w0, w1, w2, w3, w4, w5);
        }

        fn pick(l: Isa) *const EntryFn(Return(f)) {
            inline for (linked) |t| {
                if (l == t.isa) return @extern(*const EntryFn(Return(f)), .{
                    .name = symbol(src, t.isa),
                    .visibility = .hidden,
                });
            }
            return &Entry(f).entry;
        }
    };
}

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
    return RetAs(R, tight);
}

/// Whether a struct of three fields crosses in two words: where results
/// cross into a tier's object, which is only on x86-64. Its first field is
/// an enum of a byte and the other two are words, equal where the enum is
/// its first value, as `ConvertResult`'s `count` and `written` are on
/// success. The second word is the first word field. The first word is zero
/// for the first enum value, as a `Result`'s is on success, and otherwise
/// the enum in its low byte and the third field in the 56 bits above, which
/// hold it because it counts code units in memory, and x86-64 user
/// addresses are below 2^56 (2^47 without 5-level paging). Three words would
/// come back through memory under the C calling convention, a store and a
/// load a call; packing every result cost the dispatched checked
/// conversions 0.8 TSC ticks a call (docs/slop/results/convert-written-20261102.md).
/// Elsewhere, where no result crosses (and on 32-bit targets, which do not
/// dispatch), it is three words, which LLVM keeps in registers within the
/// function.
const tight = role != .off;

fn RetAs(comptime R: type, comptime t: bool) type {
    if (R == void or R == bool or R == usize) return R;
    if (@typeInfo(R) == .@"struct" and compat.fieldCount(@typeInfo(R).@"struct") == 3 and !t) {
        return @Int(.unsigned, 3 * @bitSizeOf(usize));
    }
    return Words;
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
    inline for (comptime compat.paramTypes(@typeInfo(@TypeOf(f)).@"fn"), 0..) |p, k| {
        args[k] = argFromWords(p.?, w[i..]);
        i += comptime wordCount(p.?);
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
        .@"struct" => if (fieldBits(T) <= @bitSizeOf(usize)) .word else .ref,
        else => .ref,
    };
}

/// The bits of a word that hold `T`, a struct, packed as it is or field by
/// field, such as `base64.EncodeOptions`; more than a word where a field is
/// not an integer, enum, or bool. In a word, such options cost no stack
/// store and reload around the call.
fn fieldBits(comptime T: type) usize {
    const s = @typeInfo(T).@"struct";
    if (s.layout == .@"packed") return @bitSizeOf(T);
    var bits: usize = 0;
    const count = comptime compat.fieldCount(s);
    inline for (0..count) |i| bits += switch (@typeInfo(compat.FieldType(s, i))) {
        .int, .@"enum", .bool => @bitSizeOf(compat.FieldType(s, i)),
        else => @bitSizeOf(usize) + 1,
    };
    return bits;
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
    const s = switch (@typeInfo(T)) {
        .@"struct" => |s| if (s.layout == .@"packed") return scalarWord(x) else s,
        else => return scalarWord(x),
    };
    // A struct of scalars, field by field from the low bits.
    var w: usize = 0;
    comptime var at = 0;
    const count = comptime compat.fieldCount(s);
    inline for (0..count) |i| {
        const name = comptime compat.fieldName(s, i);
        const field_t = comptime compat.FieldType(s, i);
        w |= scalarWord(@field(x, name)) << at;
        at += @bitSizeOf(field_t);
    }
    return w;
}

inline fn scalarWord(x: anytype) usize {
    const T = @TypeOf(x);
    return switch (@typeInfo(T)) {
        .pointer => @intFromPtr(x),
        .bool => @intFromBool(x),
        .@"enum" => @intCast(compat.enumToInt(x)),
        .int => |n| @as(@Int(.unsigned, @bitSizeOf(usize)), @as(@Int(.unsigned, n.bits), @bitCast(x))),
        .@"struct" => @as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(x)),
        else => @compileError("dispatch: no word for " ++ @typeName(T)),
    };
}

inline fn fromWord(comptime T: type, w: usize) T {
    const s = switch (@typeInfo(T)) {
        .@"struct" => |s| if (s.layout == .@"packed") return scalarFromWord(T, w) else s,
        else => return scalarFromWord(T, w),
    };
    var x: T = undefined;
    comptime var at = 0;
    const count = comptime compat.fieldCount(s);
    inline for (0..count) |i| {
        const name = comptime compat.fieldName(s, i);
        const field_t = comptime compat.FieldType(s, i);
        @field(x, name) = scalarFromWord(field_t, w >> at & ((1 << @bitSizeOf(field_t)) - 1));
        at += @bitSizeOf(field_t);
    }
    return x;
}

inline fn scalarFromWord(comptime T: type, w: usize) T {
    return switch (@typeInfo(T)) {
        .pointer => @ptrFromInt(w),
        .bool => w != 0,
        .@"enum" => compat.enumFromInt(T, w),
        .int => |n| @bitCast(@as(@Int(.unsigned, n.bits), @truncate(w))),
        .@"struct" => @bitCast(@as(@Int(.unsigned, @bitSizeOf(T)), @truncate(w))),
        else => @compileError("dispatch: no word for " ++ @typeName(T)),
    };
}

/// `value`, a table the kernels of more than one tier read, once in a
/// program. In a dispatching build the main object exports it as `name`
/// under this build's prefix when its kernels read it, and the tier objects
/// link to that copy, where the SSE and AVX2 objects had one each. The
/// tables object (build.zig) exports every such table too, weakly: the tier
/// objects keep every kernel, and so every reference, until the linker
/// drops the unreached ones, and unoptimized builds drop none, so without
/// that copy a program that reads none of the tables leaves them undefined,
/// which Zig's Mach-O linker rejects. Each copy there has a section of its
/// own, which the linker drops when the main object's copy wins or no
/// kernel reads it. On COFF, where lld-link takes a weak symbol and a
/// definition for duplicates, the tables object's copy is the only one and
/// every reference is a plain one. `value` holds no vectors, which 0.17
/// does not export, and is 16-byte aligned for the kernels' loads.
/// Elsewhere it is `value`.
pub fn shared(comptime name: []const u8, comptime value: anytype) *align(16) const @TypeOf(value) {
    const T = @TypeOf(value);
    const S = struct {
        const v: T align(16) = value;
    };
    if (role == .off) return &S.v;
    const global = options.prefix ++ "_" ++ name;
    const coff = builtin.target.ofmt == .coff;
    if (role == .tables) {
        @export(&S.v, .{ .name = global, .linkage = if (coff) .strong else .weak, .visibility = .hidden });
        return &S.v;
    }
    if (coff) return @extern(*align(16) const T, .{ .name = global, .visibility = .hidden });
    if (role == .main) {
        @export(&S.v, .{ .name = global, .visibility = .hidden });
        return &S.v;
    }
    return @extern(?*align(16) const T, .{ .name = global, .linkage = .weak, .visibility = .hidden }).?;
}

/// For a kernel's own out-of-line parts, as for `call`: `pack` turns a
/// result into what an entry returns, a scalar that comes back in
/// registers, and `unpack` builds the result from it. A `Result` returned
/// whole from a `noinline` function went through memory, where loading its
/// `err` from the upper half of the 16-byte store that wrote it stalled,
/// about 7 ns a call (docs/slop/results/calls-20261031.md).
pub const Packed = Ret;
pub const pack = toResult;
pub const unpack = fromWords;

inline fn toResult(r: anytype) Ret(@TypeOf(r)) {
    return toResultAs(tight, r);
}

inline fn fromWords(comptime R: type, w: Ret(R)) R {
    return fromWordsAs(R, tight, w);
}

inline fn toResultAs(comptime t: bool, r: anytype) RetAs(@TypeOf(r), t) {
    const R = @TypeOf(r);
    const W = RetAs(R, t);
    if (W == R) return r;
    return switch (@typeInfo(R)) {
        .@"struct" => |s| blk: {
            const count = comptime compat.fieldCount(s);
            if (count > 3) @compileError("dispatch: more than three fields in " ++ @typeName(R));
            if (count == 3 and @bitSizeOf(W) < 3 * @bitSizeOf(usize)) {
                comptime checkTight(s);
                const tag = toWord(@field(r, compat.fieldName(s, 0)));
                const first = @field(r, compat.fieldName(s, 1));
                const second = @field(r, compat.fieldName(s, 2));
                const high = @as(W, first) << @bitSizeOf(usize);
                // The first enum value (`none`) says the two words are
                // equal: the low word is zero, as a two-field result's tag
                // is, with no shifts on the path every success takes.
                if (tag == 0) {
                    std.debug.assert(second == first);
                    break :blk high;
                }
                std.debug.assert(second >> (@bitSizeOf(usize) - 8) == 0);
                break :blk @as(W, tag | second << 8) | high;
            }
            var w: W = 0;
            inline for (0..count) |k| {
                const name = comptime compat.fieldName(s, k);
                w |= @as(W, toWord(@field(r, name))) << (@bitSizeOf(usize) * k);
            }
            break :blk w;
        },
        else => toWord(r),
    };
}

inline fn fromWordsAs(comptime R: type, comptime t: bool, w: RetAs(R, t)) R {
    const W = RetAs(R, t);
    if (W == R) return w;
    return switch (@typeInfo(R)) {
        .@"struct" => |s| blk: {
            var r: R = undefined;
            const count = comptime compat.fieldCount(s);
            if (count == 3 and @bitSizeOf(W) < 3 * @bitSizeOf(usize)) {
                comptime checkTight(s);
                const low: usize = @truncate(w);
                const first: usize = @truncate(w >> @bitSizeOf(usize));
                @field(r, compat.fieldName(s, 0)) = fromWord(compat.FieldType(s, 0), low & 0xFF);
                @field(r, compat.fieldName(s, 1)) = first;
                @field(r, compat.fieldName(s, 2)) = if (low & 0xFF == 0) first else low >> 8;
                break :blk r;
            }
            inline for (0..count) |k| {
                const name = comptime compat.fieldName(s, k);
                const field_t = comptime compat.FieldType(s, k);
                @field(r, name) = fromWord(field_t, @truncate(w >> (@bitSizeOf(usize) * k)));
            }
            break :blk r;
        },
        else => fromWord(R, @truncate(w)),
    };
}

/// A struct that crosses in two words with three fields: an enum of a byte,
/// then two words that are equal where the enum is its first value, on a
/// 64-bit target (`tight`).
fn checkTight(comptime s: std.builtin.Type.Struct) void {
    const ok = @bitSizeOf(usize) == 64 and
        @typeInfo(compat.FieldType(s, 0)) == .@"enum" and @bitSizeOf(compat.FieldType(s, 0)) <= 8 and
        compat.FieldType(s, 1) == usize and compat.FieldType(s, 2) == usize;
    if (!ok) @compileError("dispatch: three fields cross only as an enum of a byte and two usize, on 64-bit targets");
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
// own. This file is each object's root. Only modes with safety checks have
// such panics, so only they export the entry: exported, it would link the
// handler, and with it std's stack-trace and DWARF code, into every
// ReleaseFast program, about 170 KB.
pub const panic = std.debug.FullPanic(forwardPanic);

fn forwardPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    const PanicFn = fn ([*]const u8, usize, usize) callconv(.c) noreturn;
    const main = @extern(*const PanicFn, .{ .name = options.prefix ++ "_panic", .visibility = .hidden });
    main(msg.ptr, msg.len, ret_addr orelse @returnAddress());
}

fn panicEntry(ptr: [*]const u8, len: usize, ret_addr: usize) callconv(.c) noreturn {
    // ziglint-ignore: Z011 -- 0.16 has no std.lang
    std.builtin.panic.call(ptr[0..len], ret_addr);
}

comptime {
    switch (role) {
        .off => {},
        .main => if (std.debug.runtime_safety) {
            @export(&panicEntry, .{ .name = options.prefix ++ "_panic", .visibility = .hidden });
        },
        // Every public function, so each `call` in them exports.
        .kernel => {
            referenceAll(root);
            _ = &kernelIsa;
        },
        .tables => _ = bmp.shared_tables,
    }
}

fn referenceAll(comptime T: type) void {
    inline for (comptime compat.declNames(@typeInfo(T).@"struct")) |name| {
        const x = @field(T, name);
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
    if (c != 0) return compat.enumFromInt(Isa, c - 1);
    return init();
}

noinline fn init() Isa {
    @branchHint(.cold);
    const l = best(detect());
    cached.store(compat.enumToInt(l) + 1, .monotonic);
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
        if (l1[2] >> b[1] & 1 != 0) set.addFeature(compat.enumToInt(b[0]));
    }
    if (max >= 7) {
        const l7 = cpuid(7, 0);
        for (leaf7_ebx) |b| {
            if (l7[1] >> b[1] & 1 != 0) set.addFeature(compat.enumToInt(b[0]));
        }
        for (leaf7_ecx) |b| {
            if (l7[2] >> b[1] & 1 != 0) set.addFeature(compat.enumToInt(b[0]));
        }
    }
    if (cpuid(0x80000000, 0)[0] >= 0x80000001) {
        const e1 = cpuid(0x80000001, 0);
        if (e1[2] & 1 != 0) set.addFeature(compat.enumToInt(x86.Feature.sahf));
        if (e1[2] >> 5 & 1 != 0) set.addFeature(compat.enumToInt(x86.Feature.lzcnt));
    }
    // XCR0: SSE and AVX state (bits 1, 2); AVX-512 opmask and upper ZMM
    // state (bits 5, 6, 7). Readable only when the OS set OSXSAVE.
    const xcr0: u32 = if (l1[2] >> 27 & 1 != 0) xgetbv() else 0;
    if (xcr0 & 0x6 != 0x6) {
        for ([_]x86.Feature{ .avx, .avx2, .fma, .f16c }) |f| set.removeFeature(compat.enumToInt(f));
    }
    if (xcr0 & 0xE6 != 0xE6) {
        for (simd.tiers[0].need) |f| {
            if (std.mem.startsWith(u8, @tagName(f), "avx512")) set.removeFeature(compat.enumToInt(f));
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
const ConvertResult = @import("result.zig").ConvertResult;

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
    const r = Result.fail(.surrogate, 1 << (@bitSizeOf(usize) - 24));
    try testing.expectEqual(r, fromWords(Result, toResult(r)));
    // In three words, and in two where results cross into a tier's object,
    // whichever this build is, with each field at its largest.
    const big = std.math.maxInt(usize);
    const c = ConvertResult.fail(.output_buffer_too_small, big, big - 1);
    try testing.expectEqual(c, fromWordsAs(ConvertResult, false, toResultAs(false, c)));
    if (@bitSizeOf(usize) == 64) {
        const t = ConvertResult.fail(.output_buffer_too_small, big, (1 << 56) - 1);
        try testing.expectEqual(t, fromWordsAs(ConvertResult, true, toResultAs(true, t)));
        const ok = ConvertResult.ok(big);
        try testing.expectEqual(ok, fromWordsAs(ConvertResult, true, toResultAs(true, ok)));
        try testing.expectEqual(2 * @bitSizeOf(usize), @bitSizeOf(RetAs(ConvertResult, true)));
    }
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
