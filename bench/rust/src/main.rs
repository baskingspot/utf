//! The Rust arm of `just bench-compare` (bench/README.md): `simdutf8` for
//! UTF-8 validation, `encoding_rs::mem` for UTF-16 validation and
//! transcoding, `base64-simd` for base64, and the standard library's
//! `is_ascii` and `chars().count()`, built with `-C target-cpu=native`.
//!
//! Usage, from the repository root, with the same contract as every arm:
//!
//!     bench-rust bench [OP...]   rows in the Go benchmark format
//!     bench-rust check [OP...]   one checksum line per row
//!
//! OP is a name from bench/ops.tsv, which also gives each operation's row
//! name, corpus directory, and output size; none means all. BENCHTIME_MS
//! (default 100) is how long each row's timed loop runs, sized the way Go's
//! `testing.B` sizes one.
//!
//! `encoding_rs` replaces ill-formed input with U+FFFD rather than
//! reporting it; on the corpus's valid inputs it does the same work as a
//! checked conversion. Its Latin-1 conversions and `convert_str_to_utf16`
//! assume valid input, as the valid forms do.

use std::hint::black_box;
use std::time::{Duration, Instant};

const CORPUS: &str = "bench/corpus-gen";

/// What one call returns, for the checksum: validity, the bytes written,
/// or a count.
#[derive(Clone, Copy)]
enum Out {
    Valid(bool),
    Len(usize),
    Count(usize),
}

/// The input as bytes, and as UTF-16 code units for the UTF-16 inputs.
struct Input {
    name: String,
    bytes: Vec<u8>,
    units: Vec<u16>,
}

/// An operation from bench/ops.tsv.
struct Op {
    arg: String,
    row: String,
    dir: String,
    num: usize,
    den: usize,
}

impl Op {
    fn out_len(&self, n: usize) -> usize {
        if self.num == 0 {
            0
        } else {
            n * self.num / self.den + 64
        }
    }
}

type Fn = fn(&Input, &mut [u8], &mut [u16]) -> Out;

/// Valid UTF-8, without checking.
fn as_str(bytes: &[u8]) -> &str {
    unsafe { std::str::from_utf8_unchecked(bytes) }
}

fn validate_ascii(input: &Input, _: &mut [u8], _: &mut [u16]) -> Out {
    Out::Valid(input.bytes.is_ascii())
}

fn validate_utf8(input: &Input, _: &mut [u8], _: &mut [u16]) -> Out {
    Out::Valid(simdutf8::basic::from_utf8(&input.bytes).is_ok())
}

fn validate_utf8_err(input: &Input, _: &mut [u8], _: &mut [u16]) -> Out {
    // compat reports where the error is, as a checked validation does.
    Out::Valid(simdutf8::compat::from_utf8(&input.bytes).is_ok())
}

fn validate_utf16le(input: &Input, _: &mut [u8], _: &mut [u16]) -> Out {
    // The position of the first error, as a checked validation reports.
    Out::Valid(encoding_rs::mem::utf16_valid_up_to(&input.units) == input.units.len())
}

fn utf8_to_utf16le(input: &Input, _: &mut [u8], out: &mut [u16]) -> Out {
    Out::Len(2 * encoding_rs::mem::convert_utf8_to_utf16(&input.bytes, out))
}

fn valid_utf8_to_utf16le(input: &Input, _: &mut [u8], out: &mut [u16]) -> Out {
    Out::Len(2 * encoding_rs::mem::convert_str_to_utf16(as_str(&input.bytes), out))
}

fn valid_utf8_to_latin1(input: &Input, out: &mut [u8], _: &mut [u16]) -> Out {
    Out::Len(encoding_rs::mem::convert_utf8_to_latin1_lossy(&input.bytes, out))
}

fn utf16le_to_utf8(input: &Input, out: &mut [u8], _: &mut [u16]) -> Out {
    Out::Len(encoding_rs::mem::convert_utf16_to_utf8(&input.units, out))
}

fn valid_utf16le_to_latin1(input: &Input, out: &mut [u8], _: &mut [u16]) -> Out {
    encoding_rs::mem::convert_utf16_to_latin1_lossy(&input.units, out);
    Out::Len(input.units.len())
}

fn latin1_to_utf8(input: &Input, out: &mut [u8], _: &mut [u16]) -> Out {
    Out::Len(encoding_rs::mem::convert_latin1_to_utf8(&input.bytes, out))
}

fn latin1_to_utf16le(input: &Input, _: &mut [u8], out: &mut [u16]) -> Out {
    encoding_rs::mem::convert_latin1_to_utf16(&input.bytes, out);
    Out::Len(2 * input.bytes.len())
}

fn count_utf8(input: &Input, _: &mut [u8], _: &mut [u16]) -> Out {
    Out::Count(as_str(&input.bytes).chars().count())
}

fn base64_encode(input: &Input, out: &mut [u8], _: &mut [u16]) -> Out {
    Out::Len(base64_simd::STANDARD.encode(&input.bytes, base64_simd::Out::from_slice(out)).len())
}

fn base64_encode_url(input: &Input, out: &mut [u8], _: &mut [u16]) -> Out {
    Out::Len(base64_simd::URL_SAFE_NO_PAD.encode(&input.bytes, base64_simd::Out::from_slice(out)).len())
}

fn decoded(r: Result<&mut [u8], base64_simd::Error>) -> Out {
    match r {
        Ok(decoded) => Out::Len(decoded.len()),
        Err(_) => Out::Valid(false),
    }
}

// STANDARD rejects a missing pad and nonzero bits past the last byte, so it
// does the strict decode's work in base64-decode too.
fn base64_decode(input: &Input, out: &mut [u8], _: &mut [u16]) -> Out {
    decoded(base64_simd::STANDARD.decode(&input.bytes, base64_simd::Out::from_slice(out)))
}

fn base64_decode_url(input: &Input, out: &mut [u8], _: &mut [u16]) -> Out {
    decoded(base64_simd::URL_SAFE_NO_PAD.decode(&input.bytes, base64_simd::Out::from_slice(out)))
}

// WHATWG forgiving-base64, which skips ASCII whitespace, as simdutf does;
// it needs an output buffer as long as the input.
fn base64_decode_mime(input: &Input, out: &mut [u8], _: &mut [u16]) -> Out {
    decoded(base64_simd::forgiving_decode(&input.bytes, base64_simd::Out::from_slice(out)))
}

/// The operations this arm has, by name. The Latin-1 conversions have one
/// form, which both rows time.
const IMPLS: &[(&str, Fn)] = &[
    ("validate-ascii", validate_ascii),
    ("validate-ascii-err", validate_ascii),
    ("validate-utf8", validate_utf8),
    ("validate-utf8-err", validate_utf8_err),
    ("validate-utf16le", validate_utf16le),
    ("validate-utf16le-err", validate_utf16le),
    ("utf8-to-utf16le", utf8_to_utf16le),
    ("valid-utf8-to-utf16le", valid_utf8_to_utf16le),
    ("valid-utf8-to-latin1", valid_utf8_to_latin1),
    ("utf16le-to-utf8", utf16le_to_utf8),
    ("valid-utf16le-to-latin1", valid_utf16le_to_latin1),
    ("latin1-to-utf8", latin1_to_utf8),
    ("valid-latin1-to-utf8", latin1_to_utf8),
    ("latin1-to-utf16le", latin1_to_utf16le),
    ("valid-latin1-to-utf16le", latin1_to_utf16le),
    ("count-utf8", count_utf8),
    ("base64-encode", base64_encode),
    ("base64-encode-url", base64_encode_url),
    ("base64-decode", base64_decode),
    ("base64-decode-url", base64_decode_url),
    ("base64-decode-strict", base64_decode),
    ("base64-decode-mime", base64_decode_mime),
];

fn fail(message: &str) -> ! {
    eprintln!("bench-rust: {message}");
    std::process::exit(1);
}

fn read_ops() -> Vec<Op> {
    let text = std::fs::read_to_string("bench/ops.tsv").unwrap_or_else(|e| fail(&format!("open bench/ops.tsv: {e} (run from the repository root)")));
    let ops: Vec<Op> = text
        .lines()
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(|line| {
            let fields: Vec<&str> = line.split('\t').collect();
            let (num, den) = fields[3].split_once('/').unwrap_or((fields[3], "1"));
            Op { arg: fields[0].into(), row: fields[1].into(), dir: fields[2].into(), num: num.parse().unwrap(), den: den.parse().unwrap() }
        })
        .collect();
    for (arg, _) in IMPLS {
        if !ops.iter().any(|op| op.arg == *arg) {
            fail(&format!("operation {arg} is not in bench/ops.tsv"));
        }
    }
    ops
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
            let units = if dir.contains("utf16le") { bytes.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect() } else { Vec::new() };
            Input { name: path.file_name().unwrap().to_string_lossy().into_owned(), bytes, units }
        })
        .collect();
    inputs.sort_by(|a, b| a.bytes.len().cmp(&b.bytes.len()).then_with(|| a.name.cmp(&b.name)));
    inputs
}

fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf29ce484222325u64, |h, &b| (h ^ b as u64).wrapping_mul(0x100000001b3))
}

/// Calls `f` through its pointer, hidden from the optimizer, so the call
/// stays out of line, as a C call to simdutf is, and the loop does not keep
/// the function's constants.
fn run(f: Fn, input: &Input, out8: &mut [u8], out16: &mut [u16], n: u64) -> Duration {
    let start = Instant::now();
    for _ in 0..n {
        black_box(black_box(f)(black_box(input), black_box(&mut *out8), black_box(&mut *out16)));
    }
    start.elapsed()
}

/// Go's `testing.B` loop sizing: grow `n` until a run takes the goal.
fn bench(f: Fn, input: &Input, out8: &mut [u8], out16: &mut [u16], goal: Duration) -> (u64, Duration) {
    let max_n = 1_000_000_000;
    let mut n: u64 = 1;
    let mut elapsed = run(f, input, out8, out16, n);
    while elapsed < goal && n < max_n {
        let last = n;
        let prev_ns = elapsed.as_nanos().max(1);
        let mut next = (goal.as_nanos() * last as u128 / prev_ns) as u64;
        next += next / 5;
        n = next.max(last + 1).min(100 * last).min(max_n);
        elapsed = run(f, input, out8, out16, n);
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
    let ops = read_ops();
    let wanted = &args[2..];
    for w in wanted {
        if !ops.iter().any(|op| op.arg == *w) {
            eprintln!("bench-rust: unknown operation {w}");
            std::process::exit(2);
        }
    }
    let goal_ms: u64 = std::env::var("BENCHTIME_MS").ok().map_or(100, |v| v.parse().unwrap_or_else(|_| fail("BENCHTIME_MS needs a number")));
    let goal = Duration::from_millis(goal_ms);

    for op in &ops {
        if !wanted.is_empty() && !wanted.iter().any(|w| *w == op.arg) {
            continue;
        }
        let Some((_, f)) = IMPLS.iter().find(|(arg, _)| *arg == op.arg) else {
            println!("# SKIP Benchmark{}: Rust has no equivalent here", op.row);
            continue;
        };
        // Only the conversions to UTF-16 write code units; the rest write bytes.
        let wide = op.arg.ends_with("-to-utf16le");
        for input in load(&op.dir) {
            let len = op.out_len(input.bytes.len());
            let mut out8 = vec![0u8; if wide { 0 } else { len }];
            let mut out16 = vec![0u16; if wide { len / 2 } else { 0 }];
            if check {
                match f(&input, &mut out8, &mut out16) {
                    Out::Valid(v) => println!("{}/{}\tvalid={v}", op.row, input.name),
                    Out::Count(n) => println!("{}/{}\tcount={n}", op.row, input.name),
                    Out::Len(n) => {
                        // UTF-16 output is hashed as its little-endian bytes.
                        let bytes: Vec<u8> = if wide { out16[..n / 2].iter().flat_map(|u| u.to_le_bytes()).collect() } else { out8[..n].to_vec() };
                        println!("{}/{}\tlen={n} fnv={:016x}", op.row, input.name, fnv1a(&bytes));
                    }
                }
                continue;
            }
            // Fault every page in before timing: a masked store that
            // overhangs into a page nothing has written takes a microcode
            // assist on every call. Nonzero, so the fill is not dropped as
            // redundant on zeroed memory.
            out8.fill(1);
            out16.fill(1);
            let (n, elapsed) = bench(*f, &input, &mut out8, &mut out16, goal);
            let ns_per_op = elapsed.as_nanos() as f64 / n as f64;
            let mb_per_s = input.bytes.len() as f64 * n as f64 / 1e6 / elapsed.as_secs_f64();
            println!("Benchmark{}/{}\t{n}\t{ns_per_op:.2} ns/op\t{mb_per_s:.2} MB/s", op.row, input.name);
        }
    }
}
