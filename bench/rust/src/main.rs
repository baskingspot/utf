//! The Rust arm of `just bench-compare` (bench/README.md): `simdutf8` for
//! validation, `encoding_rs::mem` for transcoding, and `base64-simd` for
//! base64, built with `-C target-cpu=native`.
//!
//! Usage, from the repository root, with the same contract as every arm:
//!
//!     bench-rust bench [OP...]   rows in the Go benchmark format
//!     bench-rust check [OP...]   one checksum line per row
//!
//! OP is validate-utf8, validate-utf8-err, utf8-to-utf16le, utf16le-to-utf8,
//! base64-encode, or base64-decode; none means all. BENCHTIME_MS (default
//! 100) is how long each row's timed loop runs, sized the way Go's
//! `testing.B` sizes one.
//!
//! `encoding_rs` replaces ill-formed input with U+FFFD rather than
//! reporting it; on the corpus's valid inputs it does the same work as a
//! checked conversion.

use std::hint::black_box;
use std::time::{Duration, Instant};

const CORPUS: &str = "bench/corpus-gen";

/// What one call returns, for the checksum: validity, or the bytes written.
#[derive(Clone, Copy)]
enum Out {
    Valid(bool),
    Len(usize),
}

/// The input as bytes, or as UTF-16 code units for the UTF-16 operations.
struct Input {
    name: String,
    bytes: Vec<u8>,
    units: Vec<u16>,
}

struct Op {
    arg: &'static str,
    row: &'static str,
    dir: &'static str,
    out_len: fn(usize) -> usize,
    run: fn(&Input, &mut [u8], &mut [u16]) -> Out,
}

fn validate_utf8(input: &Input, _: &mut [u8], _: &mut [u16]) -> Out {
    Out::Valid(simdutf8::basic::from_utf8(&input.bytes).is_ok())
}

fn validate_utf8_err(input: &Input, _: &mut [u8], _: &mut [u16]) -> Out {
    // compat reports where the error is, as a checked validation does.
    Out::Valid(simdutf8::compat::from_utf8(&input.bytes).is_ok())
}

fn utf8_to_utf16le(input: &Input, _: &mut [u8], out: &mut [u16]) -> Out {
    Out::Len(2 * encoding_rs::mem::convert_utf8_to_utf16(&input.bytes, out))
}

fn utf16le_to_utf8(input: &Input, out: &mut [u8], _: &mut [u16]) -> Out {
    Out::Len(encoding_rs::mem::convert_utf16_to_utf8(&input.units, out))
}

fn base64_encode(input: &Input, out: &mut [u8], _: &mut [u16]) -> Out {
    let n = base64_simd::STANDARD.encode(&input.bytes, base64_simd::Out::from_slice(out)).len();
    Out::Len(n)
}

fn base64_decode(input: &Input, out: &mut [u8], _: &mut [u16]) -> Out {
    match base64_simd::STANDARD.decode(&input.bytes, base64_simd::Out::from_slice(out)) {
        Ok(decoded) => Out::Len(decoded.len()),
        Err(_) => Out::Valid(false),
    }
}

const OPS: &[Op] = &[
    Op { arg: "validate-utf8", row: "ValidateUtf8", dir: "utf8", out_len: |_| 0, run: validate_utf8 },
    Op { arg: "validate-utf8-err", row: "ValidateUtf8Err", dir: "utf8-err", out_len: |_| 0, run: validate_utf8_err },
    // encoding_rs wants one more unit than the input has bytes.
    Op { arg: "utf8-to-utf16le", row: "Utf8ToUtf16le", dir: "utf8", out_len: |n| n + 1, run: utf8_to_utf16le },
    Op { arg: "utf16le-to-utf8", row: "Utf16leToUtf8", dir: "utf16le", out_len: |n| 3 * n + 3, run: utf16le_to_utf8 },
    Op { arg: "base64-encode", row: "Base64Encode", dir: "binary", out_len: |n| (n + 2) / 3 * 4, run: base64_encode },
    Op { arg: "base64-decode", row: "Base64Decode", dir: "base64", out_len: |n| n / 4 * 3 + 3, run: base64_decode },
];

fn fail(message: &str) -> ! {
    eprintln!("bench-rust: {message}");
    std::process::exit(1);
}

/// Every file in `bench/corpus-gen/<dir>`, smallest first, then by name.
fn load(dir: &str) -> Vec<Input> {
    let path = format!("{CORPUS}/{dir}");
    let entries = std::fs::read_dir(&path).unwrap_or_else(|e| fail(&format!("open {path}: {e} (run `just bench-corpus`)")));
    let mut inputs: Vec<Input> = entries
        .map(|entry| entry.unwrap().path())
        .map(|path| {
            let bytes = std::fs::read(&path).unwrap();
            // Only the UTF-16 inputs need their code units.
            let units = if dir == "utf16le" { bytes.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect() } else { Vec::new() };
            Input { name: path.file_name().unwrap().to_string_lossy().into_owned(), bytes, units }
        })
        .collect();
    inputs.sort_by(|a, b| a.bytes.len().cmp(&b.bytes.len()).then_with(|| a.name.cmp(&b.name)));
    inputs
}

fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf29ce484222325u64, |h, &b| (h ^ b as u64).wrapping_mul(0x100000001b3))
}

/// Generic over the function, so the loop calls it directly, as the other
/// arms' loops do, and not through `Op::run`'s pointer.
fn run<F: Fn(&Input, &mut [u8], &mut [u16]) -> Out>(f: &F, input: &Input, out8: &mut [u8], out16: &mut [u16], n: u64) -> Duration {
    let start = Instant::now();
    for _ in 0..n {
        black_box(f(black_box(input), black_box(&mut *out8), black_box(&mut *out16)));
    }
    start.elapsed()
}

/// Go's `testing.B` loop sizing: grow `n` until a run takes the goal.
fn bench<F: Fn(&Input, &mut [u8], &mut [u16]) -> Out>(f: F, input: &Input, out8: &mut [u8], out16: &mut [u16], goal: Duration) -> (u64, Duration) {
    let max_n = 1_000_000_000;
    let mut n: u64 = 1;
    let mut elapsed = run(&f, input, out8, out16, n);
    while elapsed < goal && n < max_n {
        let last = n;
        let prev_ns = elapsed.as_nanos().max(1);
        let mut next = (goal.as_nanos() * last as u128 / prev_ns) as u64;
        next += next / 5;
        n = next.max(last + 1).min(100 * last).min(max_n);
        elapsed = run(&f, input, out8, out16, n);
    }
    (n, elapsed)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let check = match args.get(1).map(String::as_str) {
        Some("check") => true,
        Some("bench") => false,
        _ => {
            eprintln!("usage: bench-rust bench|check [OP...]");
            std::process::exit(2);
        }
    };
    let wanted = &args[2..];
    for w in wanted {
        if !OPS.iter().any(|op| op.arg == w) {
            eprintln!("bench-rust: unknown operation {w}");
            std::process::exit(2);
        }
    }
    let goal_ms: u64 = std::env::var("BENCHTIME_MS").ok().map_or(100, |v| v.parse().unwrap_or_else(|_| fail("BENCHTIME_MS needs a number")));
    let goal = Duration::from_millis(goal_ms);

    for op in OPS {
        if !wanted.is_empty() && !wanted.iter().any(|w| w == op.arg) {
            continue;
        }
        for input in load(op.dir) {
            let len = (op.out_len)(input.bytes.len());
            // Only UTF-8 to UTF-16 writes code units; the rest write bytes.
            let wide = op.arg == "utf8-to-utf16le";
            let mut out8 = vec![0u8; if wide { 0 } else { len }];
            let mut out16 = vec![0u16; if wide { len } else { 0 }];
            if check {
                match (op.run)(&input, &mut out8, &mut out16) {
                    Out::Valid(v) => println!("{}/{}\tvalid={v}", op.row, input.name),
                    Out::Len(n) => {
                        // UTF-16 output is hashed as its little-endian bytes.
                        let bytes: Vec<u8> = if op.arg == "utf8-to-utf16le" {
                            out16[..n / 2].iter().flat_map(|u| u.to_le_bytes()).collect()
                        } else {
                            out8[..n].to_vec()
                        };
                        println!("{}/{}\tlen={n} fnv={:016x}", op.row, input.name, fnv1a(&bytes));
                    }
                }
                continue;
            }
            let (o8, o16) = (&mut out8[..], &mut out16[..]);
            let (n, elapsed) = match op.arg {
                "validate-utf8" => bench(validate_utf8, &input, o8, o16, goal),
                "validate-utf8-err" => bench(validate_utf8_err, &input, o8, o16, goal),
                "utf8-to-utf16le" => bench(utf8_to_utf16le, &input, o8, o16, goal),
                "utf16le-to-utf8" => bench(utf16le_to_utf8, &input, o8, o16, goal),
                "base64-encode" => bench(base64_encode, &input, o8, o16, goal),
                _ => bench(base64_decode, &input, o8, o16, goal),
            };
            let ns_per_op = elapsed.as_nanos() as f64 / n as f64;
            let mb_per_s = input.bytes.len() as f64 * n as f64 / 1e6 / elapsed.as_secs_f64();
            println!("Benchmark{}/{}\t{n}\t{ns_per_op:.2} ns/op\t{mb_per_s:.2} MB/s", op.row, input.name);
        }
    }
}
