# Harness

Notes for agents on `bench/`: the comparison benchmarks and the simdutf oracle. `bench/README.md` is the method as a person reads it; this file is how the pieces fit and how to extend them.

## Layout

- `bench/build.zig` and `bench/build.zig.zon`: a Zig build of its own, so the package's build and fetch graph never see the harness. It depends on the package by path (`..`) and on testingx, and installs with `zig build -p ../zig-out`. It builds `bench-std` and `bench-utf` (one source, `bench/zig/arm.zig`, with an `impl` option), `bench-corpus` (`bench/zig/corpus.zig`), and `oracle-compare` (`bench/oracle/compare.zig`). `-Dutf-optimize`, `-Dutf-cpu`, and `-Dutf-dispatch` build `bench-utf` (its own instances of the package and testingx) another way, the last as the package's `.dispatch` dependency argument, passed only when set; the justfile's `optimize`, `cpu`, and `dispatch` variables pass them, through `bench_zig`, to `bench-corpus` and `bench-build` alike so neither reinstalls the other's `bench-utf`.
- `bench/ops.tsv`: the operations, read at run time by every arm from the repository root: name, row, corpus directory, and output bytes per input byte. `bench/summary.awk`: the per-operation geomean that ends `just bench-compare` and that `just bench-summary` reprints.
- `bench/simdutf/main.cpp` and `bench/oracle/oracle.cpp`: built by the justfile with the dev shell's `c++` against nixpkgs' simdutf, found with `pkg-config`. Zig's `c++` would bring libc++, which nixpkgs' libstdc++ build of simdutf cannot link with.
- `bench/rust` and `bench/go`: built by the justfile with the flake's toolchains. `Cargo.lock` pins the crates.
- `bench/corpus/`: `sources.tsv` and `SHA256SUMS`. The corpus itself is gitignored in `bench/corpus-gen/`.

## Arm contract

`bench-<arm> bench|check [OP...]`, run from the repository root, with `BENCHTIME_MS`. Row names are `Benchmark<Row>/<input>`; check lines are `<Row>/<input>\t<checksum>`, where the checksum is `valid=<bool>`, `count=<n>`, or `len=<bytes> fnv=<hash>` with UTF-16 and UTF-32 output hashed as its bytes in memory, and the recipe joins them with simdutf's on the name. An arm reads `bench/ops.tsv`, fails if its own table names an operation the file lacks, and prints `# SKIP Benchmark<Row>: <why>` for a listed operation it has no function for. To add an operation, add a line to `bench/ops.tsv`, map its name in each arm that has an equivalent (at least simdutf's and this package's), and add it to `bench/README.md`'s tables; to add an input kind, add a directory to `bench/zig/corpus.zig` and regenerate `SHA256SUMS`, fetched files included: `cd bench/corpus-gen && find . -type f | sort | sed 's|^\./||' | xargs sha256sum > ../corpus/SHA256SUMS`.

`bench-utf` finds the package's functions with `@hasDecl` under the plan's names, from the table in `Utf.api`: `validate.F` and `validate.FWithErrors`, `convert.SToD` and `convert.validSToD` (generated for every pair), `length.*`, and `base64.encode(dst, src, options)` and `base64.decode(dst, src, options)`. `Utf.wrap` adapts each by its signature: one parameter (`bool`, `Result`, or `usize`, a count) validates or counts, two convert (`Result` or `usize` code units written), three are base64. An operation's base64 options set only the fields it names (`alphabet`, `padding`, `last_chunk`) on a value of the function's options type built with `.{}`, so every field needs a default. A function under another name is a skip; one under another signature, or an options type without a field an operation sets, is a compile error in the harness, not a silent skip: fix the arm in the same change.

## Measurement notes

- testingx prints ns/op as a whole number of nanoseconds (`Result.nsPerOp` is an integer), which is a 10–20% step for 16-byte inputs. MB/s is computed from the raw total, so `bench-compare` feeds benchstat only throughput, converted to GB/s. Raw rows keep ns/op.
- Every arm calls the function out of line, so a loop cannot keep a kernel's constants in registers across calls or fold its setup into the loop: the C++ loop calls into libsimdutf, the Zig loops use `@call(.never_inline, ...)`, Rust calls through a `black_box`ed function pointer, and Go through a function value inside `testing.Benchmark`'s closure. Inlined, `utf`'s 16-byte UTF-8 validation read 3.1 GB/s for a call that costs 10.4 ns, 1.5 GB/s ([harness-fix-20261031.md](results/harness-fix-20261031.md)).
- Each loop iteration first escapes the input pointer with a memory clobber (`doNotOptimizeAway`, `asm volatile`, `black_box`), so a pure call cannot be hoisted out of the loop.
- Peak RSS is GNU time around one `check` pass per arm and operation. The floor is the inputs and output buffers, about 2–14 MiB depending on the operation (UTF-32 inputs are the largest); the rest is runtime.
- Every arm allocates `n * out + 64` bytes of output, from `bench/ops.tsv`, per input. `check` leaves it unwritten, so only the pages an arm writes count in RSS; `bench` writes all of it before timing. A masked AVX-512 store whose masked-off lanes overhang into a page nothing has written takes a microcode assist on every call, since it never faults the page in; the base64 orb saw simdutf's 4 KiB decode drop from 44 to 21 GB/s that way. No corpus size hit it in this harness, but a new size could. `base64-decode-mime` gets one byte per input byte because Rust's `forgiving_decode` asserts it, compacting the input into the output before decoding there.
- `cpu`, `optimize`, and `dispatch` change only `bench-utf`; testingx's header (`cpu:`, `mode:`) in `raw-utf.txt` records the CPU and mode, and `config.txt` records the variables and simdutf's kernel. A `baseline` or `x86_64_v*` build dispatches at runtime unless `dispatch=false`, so on an AVX-512 machine `cpu=x86_64_v3` alone runs the AVX-512 kernels of whatever dispatches; compare with simdutf's `haswell` only with `dispatch=false`.
- A full run (66 operations, 877 rows for simdutf and this package, 156 for std, 248 for Rust, 141 for Go) takes about 36 minutes for 6 rounds at the default `BENCHTIME_MS` on the 4-vCPU orb.

## Oracle

Protocol (little endian): request `u8 op, u8 option, u32 len, bytes`; response `u8 error, u64 count, u32 len, bytes`. The oracle reads all of stdin before it writes, so a client writes a whole batch, closes stdin, and reads. `Oracle.run` does that and spawns once per batch; use batches of thousands. Op numbers are the `Oracle.Op` enum. simdutf honors `SIMDUTF_FORCE_IMPLEMENTATION` (`fallback`, `haswell`, `icelake`, ...), which `just oracle` uses to check the scalar kernel too.

simdutf's error codes match `src/result.zig`'s `Error` by name except for ASCII, where simdutf says `TOO_LARGE` and the package says `not_ascii`. `Oracle.sameError` matches by name, so an ASCII comparison needs that one case mapped.

`bench/oracle/compare.zig` has a table of checks per input kind (UTF-8, UTF-16LE, base64). Each check names a function of ours and the oracle op it is compared with; one that does not exist yet is skipped. The `std.*` checks hold Zig's std against simdutf so the conversion and base64 plumbing is exercised before the package has those functions. The base64 check assumes the package's default options mean simdutf's defaults: the standard alphabet, loose last chunk, whitespace skipped. To fuzz a new function against simdutf, add a check to the table; for one-off use, import `Oracle` from a program in the bench build.

## Results so far

- `results/baseline-20261030.md`: simdutf, std, Rust, and Go on the whole corpus, and the oracle against `scalar.validateUtf8` (no mismatches).
- `results/harness-fix-20261031.md`: the out-of-line calls and written output buffers, old harness against new; `utf`'s and Rust's 16–256-byte rows were overstated by up to 2×.
- `results/baseline-20261031.md`: every operation, after wave 1 and runtime dispatch: the native build against simdutf's `icelake` and the AVX2 build against `haswell`, with the gap per operation.
