// bench-rust's timed loop around a call that returns at once.
use std::hint::black_box;
use std::time::Instant;
struct Input { bytes: Vec<u8> }
#[derive(Clone, Copy)]
enum Out { Count(usize) }
type Fn = fn(&Input, &mut [u8]) -> Out;
#[inline(never)]
fn noop(input: &Input, _: &mut [u8]) -> Out { Out::Count(input.bytes.len()) }
fn main() {
    let input = Input { bytes: vec![0u8; 16] };
    let mut out = vec![0u8; 64];
    let f: Fn = noop;
    let n = 50_000_000u64;
    for _ in 0..5 {
        let start = Instant::now();
        for _ in 0..n {
            black_box(black_box(f)(black_box(&input), black_box(&mut out[..])));
        }
        println!("rust {:.3} ns/op", start.elapsed().as_nanos() as f64 / n as f64);
    }
}
