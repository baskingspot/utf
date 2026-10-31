//! The Rust arm of `just bench-compare` (bench/README.md): `simdutf8` for
//! UTF-8 validation, `encoding_rs::mem` for UTF-16 validation and
//! transcoding, `base64-simd` for base64, and the standard library's
//! `is_ascii` and `chars().count()`, built for the CPU `just bench-compare` names.
//!
//! Usage, from the repository root, with the same contract as every arm:
//!
//!     bench-rust bench [OP...]   rows in the Go benchmark format
//!     bench-rust check [OP...]   one checksum line per row
//!     bench-rust serve           one row per request line on stdin
//!
//! OP is a name from bench/ops.tsv, which also gives each operation's row
//! name, corpus directory, and output size; none means all. BENCHTIME_MS
//! (default 100) is how long each row's timed loop runs, sized the way Go's
//! `testing.B` sizes one. A `serve` request is `OP INPUT N`: time the row N
//! iterations, or for BENCHTIME_MS when N is 0. Every input starts
//! BENCH_IN_OFFSET bytes (default 0) past a page boundary and its output
//! BENCH_OUT_OFFSET bytes (default 2048) past another, as in every arm.
//!
//! `encoding_rs` replaces ill-formed input with U+FFFD rather than
//! reporting it; on the corpus's valid inputs it does the same work as a
//! checked conversion. Its Latin-1 conversions and `convert_str_to_utf16`
//! assume valid input, as the valid forms do.

use std::hint::black_box;
use std::io::{BufRead, Read, Write};
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

extern "C" {
    fn mmap(addr: *mut u8, len: usize, prot: i32, flags: i32, fd: i32, off: i64) -> *mut u8;
    fn munmap(addr: *mut u8, len: usize) -> i32;
}

/// `len` bytes `off` bytes past a page boundary, in an anonymous mapping of
/// their own: zeroed, and resident only once written. Every arm places its
/// buffers this way.
struct Placed {
    base: *mut u8,
    size: usize,
    off: usize,
    len: usize,
}

impl Placed {
    fn new(len: usize, off: usize) -> Placed {
        let size = (off + len + 4096) / 4096 * 4096;
        // PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS
        let base = unsafe { mmap(std::ptr::null_mut(), size, 3, 0x22, -1, 0) };
        if base as isize == -1 {
            fail("out of memory");
        }
        Placed { base, size, off, len }
    }
    fn bytes(&self) -> &[u8] {
        unsafe { std::slice::from_raw_parts(self.base.add(self.off), self.len) }
    }
    fn bytes_mut(&mut self) -> &mut [u8] {
        unsafe { std::slice::from_raw_parts_mut(self.base.add(self.off), self.len) }
    }
    /// The bytes as native-endian UTF-16 code units; the offsets are even.
    fn units(&self) -> &[u16] {
        unsafe { std::slice::from_raw_parts(self.base.add(self.off) as *const u16, self.len / 2) }
    }
    fn units_mut(&mut self) -> &mut [u16] {
        unsafe { std::slice::from_raw_parts_mut(self.base.add(self.off) as *mut u16, self.len / 2) }
    }
    /// Writes every page of the mapping but the data's bytes: a masked load
    /// whose masked-off lanes reach a page nothing has touched takes a
    /// microcode assist on every call. Nonzero, so the fill is not dropped
    /// as redundant on zeroed memory.
    fn write_rest(&mut self) {
        unsafe {
            std::ptr::write_bytes(self.base, 1, self.off);
            std::ptr::write_bytes(self.base.add(self.off + self.len), 1, self.size - self.off - self.len);
        }
    }
    fn write_all(&mut self) {
        unsafe { std::ptr::write_bytes(self.base, 1, self.size) };
    }
}

impl Drop for Placed {
    fn drop(&mut self) {
        unsafe { munmap(self.base, self.size) };
    }
}

fn offset_env(name: &str, default: usize) -> usize {
    let off = std::env::var(name).ok().map_or(default, |v| v.parse().unwrap_or_else(|_| fail(&format!("{name} needs a number"))));
    if off >= 4096 || off % 4 != 0 {
        fail(&format!("{name} must be a multiple of 4 under 4096"));
    }
    off
}

/// One input file. Its UTF-16 code units are its bytes, read in place: the
/// corpus is little endian, as this machine is.
struct Input {
    name: String,
    data: Placed,
}

impl Input {
    fn bytes(&self) -> &[u8] {
        self.data.bytes()
    }
    fn units(&self) -> &[u16] {
        self.data.units()
    }
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

type Fn = fn(&Input, &mut Placed) -> Out;

/// Valid UTF-8, without checking.
fn as_str(bytes: &[u8]) -> &str {
    unsafe { std::str::from_utf8_unchecked(bytes) }
}

fn validate_ascii(input: &Input, _: &mut Placed) -> Out {
    Out::Valid(input.bytes().is_ascii())
}

fn validate_utf8(input: &Input, _: &mut Placed) -> Out {
    Out::Valid(simdutf8::basic::from_utf8(input.bytes()).is_ok())
}

fn validate_utf8_err(input: &Input, _: &mut Placed) -> Out {
    // compat reports where the error is, as a checked validation does.
    Out::Valid(simdutf8::compat::from_utf8(input.bytes()).is_ok())
}

fn validate_utf16le(input: &Input, _: &mut Placed) -> Out {
    // The position of the first error, as a checked validation reports.
    Out::Valid(encoding_rs::mem::utf16_valid_up_to(input.units()) == input.units().len())
}

fn utf8_to_utf16le(input: &Input, out: &mut Placed) -> Out {
    Out::Len(2 * encoding_rs::mem::convert_utf8_to_utf16(input.bytes(), out.units_mut()))
}

fn valid_utf8_to_utf16le(input: &Input, out: &mut Placed) -> Out {
    Out::Len(2 * encoding_rs::mem::convert_str_to_utf16(as_str(input.bytes()), out.units_mut()))
}

fn valid_utf8_to_latin1(input: &Input, out: &mut Placed) -> Out {
    Out::Len(encoding_rs::mem::convert_utf8_to_latin1_lossy(input.bytes(), out.bytes_mut()))
}

fn utf16le_to_utf8(input: &Input, out: &mut Placed) -> Out {
    Out::Len(encoding_rs::mem::convert_utf16_to_utf8(input.units(), out.bytes_mut()))
}

fn valid_utf16le_to_latin1(input: &Input, out: &mut Placed) -> Out {
    encoding_rs::mem::convert_utf16_to_latin1_lossy(input.units(), out.bytes_mut());
    Out::Len(input.units().len())
}

fn latin1_to_utf8(input: &Input, out: &mut Placed) -> Out {
    Out::Len(encoding_rs::mem::convert_latin1_to_utf8(input.bytes(), out.bytes_mut()))
}

fn latin1_to_utf16le(input: &Input, out: &mut Placed) -> Out {
    encoding_rs::mem::convert_latin1_to_utf16(input.bytes(), out.units_mut());
    Out::Len(2 * input.bytes().len())
}

fn count_utf8(input: &Input, _: &mut Placed) -> Out {
    Out::Count(as_str(input.bytes()).chars().count())
}

fn base64_encode(input: &Input, out: &mut Placed) -> Out {
    Out::Len(base64_simd::STANDARD.encode(input.bytes(), base64_simd::Out::from_slice(out.bytes_mut())).len())
}

fn base64_encode_url(input: &Input, out: &mut Placed) -> Out {
    Out::Len(base64_simd::URL_SAFE_NO_PAD.encode(input.bytes(), base64_simd::Out::from_slice(out.bytes_mut())).len())
}

fn decoded(r: Result<&mut [u8], base64_simd::Error>) -> Out {
    match r {
        Ok(decoded) => Out::Len(decoded.len()),
        Err(_) => Out::Valid(false),
    }
}

// STANDARD rejects a missing pad and nonzero bits past the last byte, so it
// does the strict decode's work in base64-decode too.
fn base64_decode(input: &Input, out: &mut Placed) -> Out {
    decoded(base64_simd::STANDARD.decode(input.bytes(), base64_simd::Out::from_slice(out.bytes_mut())))
}

fn base64_decode_url(input: &Input, out: &mut Placed) -> Out {
    decoded(base64_simd::URL_SAFE_NO_PAD.decode(input.bytes(), base64_simd::Out::from_slice(out.bytes_mut())))
}

// WHATWG forgiving-base64, which skips ASCII whitespace, as simdutf does;
// it needs an output buffer as long as the input.
fn base64_decode_mime(input: &Input, out: &mut Placed) -> Out {
    decoded(base64_simd::forgiving_decode(input.bytes(), base64_simd::Out::from_slice(out.bytes_mut())))
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
fn load(dir: &str, in_offset: usize) -> Vec<Input> {
    let path = format!("{CORPUS}/{dir}");
    let entries = std::fs::read_dir(&path).unwrap_or_else(|e| fail(&format!("open {path}: {e} (run `just bench-corpus`)")));
    let mut inputs: Vec<Input> = entries
        .map(|entry| entry.unwrap().path())
        .map(|path| {
            let mut file = std::fs::File::open(&path).unwrap();
            let mut data = Placed::new(file.metadata().unwrap().len() as usize, in_offset);
            file.read_exact(data.bytes_mut()).unwrap();
            data.write_rest();
            Input { name: path.file_name().unwrap().to_string_lossy().into_owned(), data }
        })
        .collect();
    inputs.sort_by(|a, b| a.data.len.cmp(&b.data.len).then_with(|| a.name.cmp(&b.name)));
    inputs
}

fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf29ce484222325u64, |h, &b| (h ^ b as u64).wrapping_mul(0x100000001b3))
}

/// Calls `f` through its pointer, hidden from the optimizer, so the call
/// stays out of line, as a C call to simdutf is, and the loop does not keep
/// the function's constants.
fn run(f: Fn, input: &Input, out: &mut Placed, n: u64) -> Duration {
    let start = Instant::now();
    for _ in 0..n {
        black_box(black_box(f)(black_box(input), black_box(&mut *out)));
    }
    start.elapsed()
}

/// Times `f` on one input: `n` iterations after one untimed call, or with
/// `n` 0, sized the way Go's `testing.B` sizes a loop, growing `n` until a
/// run takes the goal. Prints the row.
fn measure(op: &Op, f: Fn, input: &Input, out: &mut Placed, mut n: u64, goal: Duration) {
    let elapsed = if n > 0 {
        run(f, input, out, 1);
        run(f, input, out, n)
    } else {
        let max_n = 1_000_000_000;
        n = 1;
        let mut elapsed = run(f, input, out, n);
        while elapsed < goal && n < max_n {
            let last = n;
            let prev_ns = elapsed.as_nanos().max(1);
            let mut next = (goal.as_nanos() * last as u128 / prev_ns) as u64;
            next += next / 5;
            n = next.max(last + 1).min(100 * last).min(max_n);
            elapsed = run(f, input, out, n);
        }
        elapsed
    };
    let ns_per_op = elapsed.as_nanos() as f64 / n as f64;
    let mb_per_s = input.data.len as f64 * n as f64 / 1e6 / elapsed.as_secs_f64();
    let mut stdout = std::io::stdout().lock();
    writeln!(stdout, "Benchmark{}/{}\t{n}\t{ns_per_op:.2} ns/op\t{mb_per_s:.2} MB/s", op.row, input.name).unwrap();
    stdout.flush().unwrap();
}

/// A fresh output buffer for an input of `n` bytes. Unwritten, so that in
/// `check` only the pages written count in RSS; `bench` and `serve` write it
/// before timing, since a masked store that overhangs into a page nothing
/// has written takes a microcode assist on every call.
fn output(op: &Op, n: usize, out_offset: usize) -> Placed {
    Placed::new(op.out_len(n), out_offset)
}

/// `serve`: one row per request line, `OP INPUT N`, until stdin ends. The
/// requested operation's inputs and outputs stay loaded until another is
/// requested.
fn serve(ops: &[Op], goal: Duration, in_offset: usize, out_offset: usize) {
    let mut loaded: Option<(usize, Vec<Input>, Vec<Placed>)> = None;
    for line in std::io::stdin().lock().lines() {
        let line = line.unwrap();
        let fields: Vec<&str> = line.split_whitespace().collect();
        let [arg, name, n] = fields[..] else { fail(&format!("bad request: {line}")) };
        let n: u64 = n.parse().unwrap_or_else(|_| fail(&format!("bad request: {line}")));
        let i = ops.iter().position(|op| op.arg == arg).unwrap_or_else(|| fail(&format!("no operation {arg}")));
        let Some((_, f)) = IMPLS.iter().find(|(a, _)| *a == arg) else { fail(&format!("no operation {arg}")) };
        if loaded.as_ref().is_none_or(|(j, _, _)| *j != i) {
            let inputs = load(&ops[i].dir, in_offset);
            let outs = inputs
                .iter()
                .map(|input| {
                    let mut out = output(&ops[i], input.data.len, out_offset);
                    out.write_all();
                    out
                })
                .collect();
            loaded = Some((i, inputs, outs));
        }
        let (_, inputs, outs) = loaded.as_mut().unwrap();
        let k = inputs.iter().position(|input| input.name == name).unwrap_or_else(|| fail(&format!("no input {name} for {arg}")));
        measure(&ops[i], *f, &inputs[k], &mut outs[k], n, goal);
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let check = match args.get(1).map(String::as_str) {
        Some("check") => true,
        Some("bench" | "serve") => false,
        _ => {
            eprintln!("usage: bench-rust bench|check [OP...] | serve");
            std::process::exit(2);
        }
    };
    let ops = read_ops();
    let goal_ms: u64 = std::env::var("BENCHTIME_MS").ok().map_or(100, |v| v.parse().unwrap_or_else(|_| fail("BENCHTIME_MS needs a number")));
    let goal = Duration::from_millis(goal_ms);
    let in_offset = offset_env("BENCH_IN_OFFSET", 0);
    let out_offset = offset_env("BENCH_OUT_OFFSET", 2048);
    if args[1] == "serve" {
        serve(&ops, goal, in_offset, out_offset);
        return;
    }
    let wanted = &args[2..];
    for w in wanted {
        if !ops.iter().any(|op| op.arg == *w) {
            eprintln!("bench-rust: unknown operation {w}");
            std::process::exit(2);
        }
    }

    for op in &ops {
        if !wanted.is_empty() && !wanted.iter().any(|w| *w == op.arg) {
            continue;
        }
        let Some((_, f)) = IMPLS.iter().find(|(arg, _)| *arg == op.arg) else {
            println!("# SKIP Benchmark{}: Rust has no equivalent here", op.row);
            continue;
        };
        for input in load(&op.dir, in_offset) {
            let mut out = output(op, input.data.len, out_offset);
            if check {
                match f(&input, &mut out) {
                    Out::Valid(v) => println!("{}/{}\tvalid={v}", op.row, input.name),
                    Out::Count(n) => println!("{}/{}\tcount={n}", op.row, input.name),
                    // UTF-16 output is its bytes in memory, little endian here.
                    Out::Len(n) => println!("{}/{}\tlen={n} fnv={:016x}", op.row, input.name, fnv1a(&out.bytes()[..n])),
                }
                continue;
            }
            out.write_all();
            measure(op, *f, &input, &mut out, 0, goal);
        }
    }
}
