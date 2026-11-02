# Output written on a checked conversion's error, 2026-11-02

The checked conversions return `ConvertResult { err, count, written }` instead of `Result { err, count }`: `err` and `count` as before (simdutf's `result`: the output code units on success, the error's input index on failure), and `written`, the output code units written, which on failure hold the input before the error, as simdutf's `full_result.output_count` has them. baskingspot/encoding asked for it: it recounts the converted prefix with a `length` function after every error (`src/utf16.zig` and `src/utf8.zig` there). The question here is whether the change costs the success path or short calls anything. It does not in native builds; in dispatched builds a first version cost about 0.8 TSC ticks a call, and the committed one returns the same two registers on success as before.

- Machine: Amp orb, KVM guest, Intel Xeon @ 2.60GHz (Ice Lake server, family 6 model 106, AVX-512 with VBMI2), 2 cores × 2 threads; every timed process pinned to CPU 3, nothing built while anything was timed.
- Harness: `just base=c858d53 bench-compare 10 <ops>` for the 20 checked conversions (284 rows each), under Zig 0.17.0 (`nix develop`), ReleaseFast, simdutf 9.2.1 (`icelake`), with `cpu=native` and `cpu=baseline` (dispatched). `base` is the tree before the change (the harness fixes of `c858d53` included), built the same way and run in the same rounds; the `base` column is utf ÷ base per round, median over 10 rounds, with a 95% interval. The arms read `written` from a `ConvertResult` (`r.count` from the old `Result`), what a caller that resumes after an error reads, so an inlined kernel cannot drop it.
- Per-call loop: [calls/](convert-written-20261102/calls/), `short-20261101`'s loop under Zig 0.16.0 (it is 0.16 code), every `convert` function called out of line 1 million times on 16 and 64 ASCII units, TSC ticks per call (2.6 a nanosecond), the minimum over 15 loops and 3 rotating runs. Its wrapper reads `count`, as source that did not change does. The valid forms did not change and are the control: what they move is layout.
- Raw output: [convert-written-20261102/](convert-written-20261102/), a directory per run with `config.txt`, `summary.txt`, `rows.txt`, and `benchstat.txt`.
- Commits, as measured and named in each `config.txt`, before the branch was rebased onto `49bb2f4` (main's own 32-bit `length` fix and gate): `base` is `c858d53`, `4b4cc35` with the 32-bit fix and the harness fixes; `fd75793` is the first version with the arms reading `count` (`native-count/`), `abbacf7` the same with them reading `written` (`native/`, `dispatched-first/`), and `e797098` the committed packing (`dispatched/`, `calls` `final`). The rebased sources differ from the measured ones by a comment in `length.zig`, a test line in `dispatch.zig`, and signatures and test lines wrapped to 120 columns.

## Takeaways

- **Native builds: level.** Harness geomean utf ÷ base 1.000 over 284 rows (37 rows faster beyond their interval, 37 slower, the spread layout gives identical code); every size class 0.994–1.024 and every operation 0.96–1.02. With the arms reading `count` instead (`native-count/`, the commit before the arm read `written`), 1.000 with 1 row faster and 5 slower, all at 0.993 or above. Per call, 16 and 64 units: 0.999 and 1.000, a median of 0.00 ticks. The kernel's `written` is a register it already had: `o` at every return, and `tail`'s one more add on the scalar tails.
- **Dispatched, a result of three fields cost a shift and an `or` a call.** Under the C calling convention three words come back through memory, so `dispatch.zig` returns a `ConvertResult` in two registers. Packing every result (the enum in the low byte of `count`'s word) cost the AVX-512 tier's success path `shl`, `or`, and a zeroed register, which LLVM did not fold: harness 16 units 0.969, 64 0.979, 256 0.987, 4 KiB 0.991 (`dispatched-first/`); per call +0.78 ticks median at 16 and 64 units (1.025 and 1.017), while the unchanged valid forms read 0.946.
- **Committed: on success the two registers are what they were.** `none` means `count` and `written` are equal, so the first word is zero, as a `Result`'s `err` is, and the second is `count`; only a failure packs the error kind and `written` into the first word. The AVX-512 tier's short paths end in `xor eax, eax; vzeroupper; ret` again, the same instructions as before the change but for block order (`objdump` of `utf8ToUtf16le`'s export in both builds), and a caller reading `count` runs the same code. A caller reading `written` pays a `cmov` on its side. Dispatched harness: 16 units 0.987, 64 0.996, 256 0.989, 4 KiB 0.989, from 64 KiB 0.999, all 284 rows 0.995 (22 faster, 49 slower). What is left under 1.0 is long paths moving: `Utf32ToUtf16be` reads 0.88–0.97 from 256 values to 64 KiB here and 0.89–0.97 in the native run with the arms reading `written` (level with them reading `count`), and in this build its long path (`longPath`'s `Long.run`) is the same loop as before in another register assignment and block order. Per call: 16 units 1.040 (median +1.47 ticks), 64 units 1.010, with the valid-form control at 0.987 and 0.990: identical instructions at other addresses, which this loop cannot separate from a change below about 1.5 ticks.
- **simdutf agrees on `written`.** `just oracle` (1,000,000 inputs, `icelake` and `fallback`) adds a check of `convert.utf16leToUtf8` against `convert_utf16_to_utf8_safe_with_details`, the one `full_result` conversion simdutf has with an error other than the output running out, comparing `err`, `count`, `written`, and the bytes written: 250,000 inputs per kernel, 136,180 with an unpaired surrogate, 0 mismatches; 0 mismatches over the 83 checks.
- **Memory**: none. Nothing allocates; a `ConvertResult` is one word larger than a `Result` where it is stored.

## Harness

`base` column: utf ÷ base, geomean by input size, and rows faster (`>`) or slower (`<`) beyond their 95% interval.

| size (units) | native |   > |   < | dispatched, first |   > |   < | dispatched |   > |   < |
| -----------: | -----: | --: | --: | ----------------: | --: | --: | ---------: | --: | --: |
|           16 |  0.998 |   4 |   5 |             0.969 |   0 |  14 |      0.987 |   3 |   7 |
|           64 |  1.024 |  15 |   4 |             0.979 |   3 |  12 |      0.996 |   4 |   6 |
|          256 |  0.994 |   4 |   7 |             0.987 |   2 |  10 |      0.989 |   8 |  13 |
|         4096 |  0.996 |   2 |   3 |             0.991 |   0 |   7 |      0.989 |   0 |   4 |
|        65536 |  0.999 |   1 |   2 |             0.996 |   0 |   3 |      0.999 |   1 |   2 |
|      1048576 |  1.000 |   0 |   0 |             0.999 |   0 |   0 |      0.999 |   1 |   0 |
| corpus texts |  0.997 |  11 |  16 |             0.995 |   1 |  12 |      0.997 |   5 |  17 |
|      all 284 |  1.000 |  37 |  37 |             0.990 |   6 |  58 |      0.995 |  22 |  49 |

Native, per operation (utf GB/s, utf ÷ simdutf, utf ÷ base):

| operation        | rows | utf GB/s | ÷ simdutf | ÷ base |
| ---------------- | ---: | -------: | --------: | -----: |
| Utf8ToUtf16le    |   15 |     7.47 |      1.18 |   1.01 |
| Utf8ToUtf16be    |   15 |     7.41 |      1.23 |   1.00 |
| Utf8ToUtf32      |   15 |     6.01 |      1.15 |   1.00 |
| Utf8ToLatin1     |   13 |    15.48 |      1.23 |   1.00 |
| Utf16leToUtf8    |   15 |    17.01 |      1.37 |   1.00 |
| Utf16leToUtf16be |   15 |    31.89 |      1.48 |   1.00 |
| Utf16leToUtf32   |   15 |    20.80 |      1.11 |   1.00 |
| Utf16leToLatin1  |   13 |    31.41 |      1.06 |   1.00 |
| Utf16beToUtf8    |   15 |    16.10 |      1.33 |   0.99 |
| Utf16beToUtf16le |   15 |    31.82 |      1.50 |   1.00 |
| Utf16beToUtf32   |   15 |    20.23 |      1.12 |   1.00 |
| Utf16beToLatin1  |   13 |    30.45 |      1.08 |   0.99 |
| Utf32ToUtf8      |   15 |    24.98 |      2.04 |   1.00 |
| Utf32ToUtf16le   |   15 |    40.30 |      1.20 |   1.02 |
| Utf32ToUtf16be   |   15 |    39.21 |      1.31 |   0.96 |
| Utf32ToLatin1    |   13 |    44.06 |      1.13 |   1.00 |
| Latin1ToUtf8     |   13 |    14.71 |      1.11 |   1.02 |
| Latin1ToUtf16le  |   13 |    15.76 |      1.07 |   1.01 |
| Latin1ToUtf16be  |   13 |    16.00 |      1.07 |   1.00 |
| Latin1ToUtf32    |   13 |    10.35 |      1.08 |   1.00 |
| all              |  284 |    18.97 |      1.23 |   1.00 |

Dispatched, per operation:

| operation        | rows | utf GB/s | ÷ simdutf | ÷ base |
| ---------------- | ---: | -------: | --------: | -----: |
| Utf8ToUtf16le    |   15 |     7.54 |      1.19 |   1.00 |
| Utf8ToUtf16be    |   15 |     7.34 |      1.22 |   1.00 |
| Utf8ToUtf32      |   15 |     5.92 |      1.13 |   1.00 |
| Utf8ToLatin1     |   13 |    14.29 |      1.14 |   0.99 |
| Utf16leToUtf8    |   15 |    16.03 |      1.29 |   1.00 |
| Utf16leToUtf16be |   15 |    31.27 |      1.44 |   0.99 |
| Utf16leToUtf32   |   15 |    20.35 |      1.08 |   1.00 |
| Utf16leToLatin1  |   13 |    30.13 |      1.01 |   1.00 |
| Utf16beToUtf8    |   15 |    16.02 |      1.32 |   0.99 |
| Utf16beToUtf16le |   15 |    30.44 |      1.43 |   0.98 |
| Utf16beToUtf32   |   15 |    19.88 |      1.10 |   1.00 |
| Utf16beToLatin1  |   13 |    29.12 |      1.03 |   1.02 |
| Utf32ToUtf8      |   15 |    24.23 |      1.97 |   0.99 |
| Utf32ToUtf16le   |   15 |    40.23 |      1.20 |   0.99 |
| Utf32ToUtf16be   |   15 |    38.22 |      1.27 |   0.96 |
| Utf32ToLatin1    |   13 |    40.58 |      1.05 |   1.00 |
| Latin1ToUtf8     |   13 |    13.96 |      1.05 |   1.00 |
| Latin1ToUtf16le  |   13 |    14.25 |      0.97 |   1.00 |
| Latin1ToUtf16be  |   13 |    14.25 |      0.96 |   1.00 |
| Latin1ToUtf32    |   13 |     9.40 |      0.98 |   1.00 |
| all              |  284 |    18.21 |      1.18 |   0.99 |

## Per call

TSC ticks per call, 16 and 64 ASCII units; `before` is `c858d53`, `first` the packed version, `final` the committed one. Geomean after ÷ before over the 20 checked and the 20 valid conversions:

| build             | form    |    16 |    64 |
| ----------------- | ------- | ----: | ----: |
| native            | checked | 0.999 | 1.000 |
| native            | valid   | 1.001 | 1.001 |
| dispatched, first | checked | 1.025 | 1.017 |
| dispatched, first | valid   | 0.946 | 0.946 |
| dispatched, final | checked | 1.040 | 1.010 |
| dispatched, final | valid   | 0.987 | 0.990 |

Every row is in [calls/ascii.txt](convert-written-20261102/calls/ascii.txt) (native and first) and [calls/ascii2.txt](convert-written-20261102/calls/ascii2.txt) (first and final, one run).

## The API

```zig
pub const ConvertResult = struct {
    err: Error,
    count: usize, // Result's: output units on success, the error's input index on failure
    written: usize, // output units written: count on success, the input before count on failure

    pub fn result(r: ConvertResult) Result; // simdutf's `result`
};
```

Code that reads `err` and `count` builds unchanged; code that names `utf.Result` for a conversion's result names `utf.ConvertResult`. In encoding, UTF-16 to UTF-8 after an error:

```zig
// before
if (r.err == .none) return .{ .read = 2 * n, .written = r.count };
const before = units[0..r.count];
const written = if (d.big_endian) utf.length.utf8FromUtf16be(before) else utf.length.utf8FromUtf16le(before);
return .{ .read = 2 * r.count, .written = written };
// after
return .{ .read = 2 * (if (r.err == .none) n else r.count), .written = r.written };
```

Tests: `expectSame` in `convert.zig` compares the whole `ConvertResult`, `written` included, with the scalar reference for every conversion, every error kind at every position of 200-code-point texts in four mixes (across 64-byte blocks and at the end), too-small outputs, every alignment, and million-unit inputs, at every tier (`dispatch.forEachLevel`), and checks the reference's `written` against a conversion of the input before `count`. `dispatch.zig`'s word test round-trips a `ConvertResult` through both representations at the largest values each holds.
