//! What a checked operation reports: an error kind and a position. On
//! success `count` is the number of code units written or validated; on
//! failure it is the index, in input code units, where the error starts.

/// Why an input was rejected. The UTF kinds and their positions match
/// simdutf's `error_code` and `result`, so simdutf is a differential oracle.
pub const Error = enum(u8) {
    none,
    /// A UTF-8 byte of the form 11111xxx.
    header_bits,
    /// A UTF-8 sequence that ends before its continuation bytes do.
    too_short,
    /// A continuation byte where none was expected.
    too_long,
    /// A UTF-8 sequence longer than the shortest one for its code point,
    /// including the leads 0xC0 and 0xC1.
    overlong,
    /// A code point above U+10FFFF, including 4-byte sequences led by
    /// 0xF5-0xF7.
    too_large,
    /// A surrogate code point (U+D800-U+DFFF) in UTF-8 or UTF-32, or an
    /// unpaired surrogate in UTF-16.
    surrogate,
    /// A byte above 0x7F where only ASCII is allowed.
    not_ascii,
    /// A byte that is not in the base64 alphabet and not ignorable space.
    invalid_base64_character,
    /// Base64 input whose last chunk cannot be decoded under the options.
    base64_input_remainder,
    /// Base64 input with nonzero bits in the padding position.
    base64_extra_bits,
    /// The output buffer is smaller than the operation needs.
    output_buffer_too_small,
};

pub const Result = struct {
    err: Error,
    count: usize,

    pub fn ok(count: usize) Result {
        return .{ .err = .none, .count = count };
    }

    pub fn fail(err: Error, position: usize) Result {
        return .{ .err = err, .count = position };
    }
};
