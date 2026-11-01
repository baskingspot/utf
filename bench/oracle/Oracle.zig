//! The Zig client for `utf-oracle` (bench/oracle/oracle.cpp), which runs
//! inputs through simdutf: hand it a batch of requests and get simdutf's
//! error kind, position, and output for each. A fuzzer or a differential
//! test compares those with this package's `Result`; bench/oracle/compare.zig
//! is one, and `just oracle` runs it.
//!
//!     const oracle: Oracle = .{ .io = io, .gpa = gpa, .path = "zig-out/bin/utf-oracle" };
//!     const responses = try oracle.run(&.{.{ .op = .validate_utf8, .input = bytes }});
//!     if (!Oracle.same(responses[0], utf.scalar.validateUtf8(bytes))) ...
//!
//! Each `run` spawns the oracle once, so batch thousands of requests per
//! call. `just oracle-build` builds the oracle.

const Oracle = @This();

const std = @import("std");
const compat = @import("compat.zig");
const mem = std.mem;
const Io = std.Io;

io: Io,
/// Allocates the encoded batch and the responses, which the caller frees
/// with `free`.
gpa: mem.Allocator,
/// The oracle executable, `zig-out/bin/utf-oracle` from the repository root.
path: []const u8,

/// simdutf's functions, by the number the oracle knows them by. Every
/// conversion is the checked `_with_errors` form; Latin-1 sources cannot
/// fail. UTF-16 and UTF-32 input is bytes in the named or native (little)
/// byte order, and so is their output.
pub const Op = enum(u8) {
    validate_utf8 = 1,
    validate_ascii = 2,
    validate_utf16le = 3,
    validate_utf16be = 4,
    validate_utf32 = 5,
    utf8_to_utf16le = 6,
    utf8_to_utf16be = 7,
    utf8_to_utf32 = 8,
    utf8_to_latin1 = 9,
    utf16le_to_utf8 = 10,
    utf16be_to_utf8 = 11,
    utf16le_to_utf32 = 12,
    utf16be_to_utf32 = 13,
    utf16le_to_latin1 = 14,
    utf16be_to_latin1 = 15,
    utf32_to_utf8 = 16,
    utf32_to_utf16le = 17,
    utf32_to_utf16be = 18,
    utf32_to_latin1 = 19,
    latin1_to_utf8 = 20,
    latin1_to_utf16le = 21,
    latin1_to_utf16be = 22,
    latin1_to_utf32 = 23,
    /// `base64_to_binary`; see `base64Option`.
    base64_decode = 24,
    /// `binary_to_base64`; the option is a `Base64Format`.
    base64_encode = 25,
};

/// simdutf's `error_code`, named as this package's `Error` names the same
/// kinds, so `same` can match them by name. simdutf reports a non-ASCII byte
/// as `too_large`, where this package says `not_ascii`; `run` renames it.
pub const Error = enum(u8) {
    none,
    header_bits,
    too_short,
    too_long,
    overlong,
    too_large,
    surrogate,
    invalid_base64_character,
    base64_input_remainder,
    base64_extra_bits,
    output_buffer_too_small,
    /// simdutf's OTHER, and the oracle's answer to a request it cannot
    /// run, such as UTF-16 input of odd length.
    other,
    /// Not simdutf's: `run` reports `validate_ascii`'s `too_large` as this,
    /// this package's name for it.
    not_ascii,
    _,
};

/// simdutf's `base64_options`.
pub const Base64Format = enum(u4) {
    default = 0,
    url = 1,
    default_no_padding = 2,
    url_with_padding = 3,
    default_accept_garbage = 4,
    url_accept_garbage = 5,
    default_or_url = 8,
    default_or_url_accept_garbage = 12,
};

/// simdutf's `last_chunk_handling_options`.
pub const LastChunk = enum(u2) { loose = 0, strict = 1, stop_before_partial = 2, only_full_chunks = 3 };

/// The option byte of a `base64_decode` request.
pub fn base64Option(format: Base64Format, last_chunk: LastChunk) u8 {
    return compat.enumToInt(format) | @as(u8, compat.enumToInt(last_chunk)) << 4;
}

pub const Request = struct {
    op: Op,
    option: u8 = 0,
    input: []const u8,
};

pub const Response = struct {
    err: Error,
    /// The error's position in input code units, or the output code units
    /// written.
    count: u64,
    /// The output, on success; empty on failure. It points into the batch's
    /// memory, which `free` releases.
    output: []const u8,
};

pub const RunError = error{ OracleFailed, BadResponse } || mem.Allocator.Error ||
    std.process.SpawnError || Io.File.Writer.Error || Io.Reader.LimitedAllocError || std.process.Child.WaitError;

/// Runs one batch through the oracle and returns a response per request,
/// in order. Free the result with `free`.
pub fn run(oracle: Oracle, requests: []const Request) RunError![]Response {
    var batch: std.ArrayList(u8) = .empty;
    defer batch.deinit(oracle.gpa);
    for (requests) |req| {
        var header: [6]u8 = undefined;
        header[0] = compat.enumToInt(req.op);
        header[1] = req.option;
        mem.writeInt(u32, header[2..6], @intCast(req.input.len), .little);
        try batch.appendSlice(oracle.gpa, &header);
        try batch.appendSlice(oracle.gpa, req.input);
    }

    var child = try std.process.spawn(oracle.io, .{
        .argv = &.{oracle.path},
        .stdin = .pipe,
        .stdout = .pipe,
    });
    defer if (child.id != null) child.kill(oracle.io);
    // The oracle reads to EOF before it writes, so the whole batch goes in
    // first.
    try child.stdin.?.writeStreamingAll(oracle.io, batch.items);
    child.stdin.?.close(oracle.io);
    child.stdin = null;
    var buf: [64 * 1024]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(oracle.io, &buf);
    const bytes = try reader.interface.allocRemaining(oracle.gpa, .unlimited);
    errdefer oracle.gpa.free(bytes);
    const term = try child.wait(oracle.io);
    if (term != .exited or term.exited != 0) return error.OracleFailed;

    // The responses and the bytes they point into are one allocation:
    // the response array, then the raw bytes.
    const responses = try oracle.gpa.alloc(Response, requests.len + 1);
    errdefer oracle.gpa.free(responses);
    var at: usize = 0;
    for (responses[0..requests.len], requests) |*resp, req| {
        if (bytes.len - at < 13) return error.BadResponse;
        const len = mem.readInt(u32, bytes[at + 9 ..][0..4], .little);
        if (bytes.len - at - 13 < len) return error.BadResponse;
        const err: Error = compat.enumFromInt(Error, @intCast(bytes[at]));
        resp.* = .{
            .err = if (req.op == .validate_ascii and err == .too_large) .not_ascii else err,
            .count = mem.readInt(u64, bytes[at + 1 ..][0..8], .little),
            .output = bytes[at + 13 ..][0..len],
        };
        at += 13 + len;
    }
    if (at != bytes.len) return error.BadResponse;
    // The extra last element remembers the raw bytes for `free`.
    responses[requests.len] = .{ .err = .none, .count = 0, .output = bytes };
    return responses[0..requests.len];
}

/// Frees what `run` returned.
pub fn free(oracle: Oracle, responses: []Response) void {
    const all = responses.ptr[0 .. responses.len + 1];
    oracle.gpa.free(all[responses.len].output);
    oracle.gpa.free(all);
}

/// Whether simdutf's answer is this package's `Result`: the same error,
/// matched by name, and the same count.
pub fn same(resp: Response, result: anytype) bool {
    return resp.count == result.count and sameError(resp.err, result.err);
}

/// Whether simdutf's error and one of this package's `Error`s have the same
/// name.
pub fn sameError(err: Error, ours: anytype) bool {
    return switch (err) {
        _ => false,
        inline else => |e| mem.eql(u8, @tagName(e), @tagName(ours)),
    };
}

/// Starts the oracle with `--implementation` and returns the simdutf kernel
/// it reports, such as `icelake` or `fallback`, copied into `buf`.
pub fn implementation(oracle: Oracle, buf: []u8) ![]const u8 {
    const result = try std.process.run(oracle.gpa, oracle.io, .{ .argv = &.{ oracle.path, "--implementation" } });
    defer oracle.gpa.free(result.stdout);
    defer oracle.gpa.free(result.stderr);
    const name = mem.trimEnd(u8, result.stdout, "\n");
    if (name.len > buf.len) return error.NoSpaceLeft;
    @memcpy(buf[0..name.len], name);
    return buf[0..name.len];
}
