# Harness

Notes for agents on `bench/`: the comparison benchmarks and the simdutf oracle. `bench/README.md` is the method as a person reads it; this file is how the pieces fit and how to extend them.

## Layout

- `bench/build.zig` and `bench/build.zig.zon`: a Zig build of its own, so the package's build and fetch graph never see the harness. It depends on the package by path (`..`) and on testingx, and installs with `zig build -p ../zig-out`. It builds `bench-std` and `bench-utf` (one source, `bench/zig/arm.zig`, with an `impl` option), `bench-corpus` (`bench/zig/corpus.zig`), and `oracle-compare` (`bench/oracle/compare.zig`).
- `bench/simdutf/main.cpp` and `bench/oracle/oracle.cpp`: built by the justfile with the dev shell's `c++` against nixpkgs' simdutf, found with `pkg-config`. Zig's `c++` would bring libc++, which nixpkgs' libstdc++ build of simdutf cannot link with.
- `bench/rust` and `bench/go`: built by the justfile with the flake's toolchains. `Cargo.lock` pins the crates.
- `bench/corpus/`: `sources.tsv` and `SHA256SUMS`. The corpus itself is gitignored in `bench/corpus-gen/`.

## Arm contract

`bench-<arm> bench|check [OP...]`, run from the repository root, with `BENCHTIME_MS`. Row names are `Benchmark<Row>/<input>`; check lines are `<Row>/<input>\t<checksum>`, and the recipe joins them with simdutf's on the name. To add an operation, add it to all five arms' tables with the same `arg`, row name, and corpus directory, and to `bench/README.md`'s table; to add an input kind, add a directory to `bench/zig/corpus.zig` and regenerate `SHA256SUMS`, fetched files included: `cd bench/corpus-gen && find . -type f | sort | sed 's|^\./||' | xargs sha256sum > ../corpus/SHA256SUMS`.

`bench-utf` finds the package's functions with `@hasDecl` under the plan's names: `validate.utf8`, `validate.utf8WithErrors`, `convert.utf8ToUtf16le(src, dst)`, `convert.utf16leToUtf8(src, dst)`, `base64.encode(dst, src, options)`, and `base64.decode(dst, src, options)`, the base64 ones with an options value of `.{}` when every field has a default. A function under another name or signature is a compile error in the harness, not a silent skip: fix the arm in the same change.

## Measurement notes

- testingx prints ns/op as a whole number of nanoseconds (`Result.nsPerOp` is an integer), which is a 10–20% step for 16-byte inputs. MB/s is computed from the raw total, so `bench-compare` feeds benchstat only throughput, converted to GB/s. Raw rows keep ns/op.
- The C++ and Rust loops are generic over the function, so the call is direct, as in the Zig arms; Go calls through a function value inside `testing.Benchmark`'s closure.
- Each loop iteration first escapes the input pointer with a memory clobber (`doNotOptimizeAway`, `asm volatile`, `black_box`), so a pure call cannot be hoisted out of the loop.
- Peak RSS is GNU time around one `check` pass per arm and operation. The floor is the inputs and output buffers, about 2–6 MiB depending on the operation; the rest is runtime.

## Oracle

Protocol (little endian): request `u8 op, u8 option, u32 len, bytes`; response `u8 error, u64 count, u32 len, bytes`. The oracle reads all of stdin before it writes, so a client writes a whole batch, closes stdin, and reads. `Oracle.run` does that and spawns once per batch; use batches of thousands. Op numbers are the `Oracle.Op` enum. simdutf honors `SIMDUTF_FORCE_IMPLEMENTATION` (`fallback`, `haswell`, `icelake`, ...), which `just oracle` uses to check the scalar kernel too.

simdutf's error codes match `src/result.zig`'s `Error` by name except for ASCII, where simdutf says `TOO_LARGE` and the package says `not_ascii`. `Oracle.sameError` matches by name, so an ASCII comparison needs that one case mapped.

`bench/oracle/compare.zig` has a table of checks per input kind (UTF-8, UTF-16LE, base64). Each check names a function of ours and the oracle op it is compared with; one that does not exist yet is skipped. The `std.*` checks hold Zig's std against simdutf so the conversion and base64 plumbing is exercised before the package has those functions. The base64 check assumes the package's default options mean simdutf's defaults: the standard alphabet, loose last chunk, whitespace skipped. To fuzz a new function against simdutf, add a check to the table; for one-off use, import `Oracle` from a program in the bench build.

## Results so far

- `results/baseline-20261030.md`: simdutf, std, Rust, and Go on the whole corpus, and the oracle against `scalar.validateUtf8` (no mismatches).
