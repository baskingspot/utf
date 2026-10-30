# utf bench

Benchmarks for validation, transcoding, and base64: this package against simdutf, the Rust crates and Go and Zig standard libraries that do the same jobs, over one pinned corpus. Also here: `utf-oracle`, which runs inputs through simdutf so tests and fuzzers can compare error kinds and positions with it.

These are local numbers, for iterating. They are not claims: a number that gets quoted in the README needs a run on dedicated hardware.

## Arms

Each arm is one program with the same contract. Run from the repository root, `bench-<arm> bench [OP...]` reads the operation's inputs from `bench/corpus-gen/` and prints one row per input in the Go benchmark format: `Benchmark<Op>/<input>`, the iterations, ns/op, and MB/s. `bench-<arm> check [OP...]` runs each row once and prints its checksum: validity for the validation operations, and for the others the output's length and FNV-1a hash. With no OP an arm runs all six; `BENCHTIME_MS` (default 100) is how long each row's timed loop runs.

| Operation           | Inputs      | `simdutf`                             | `utf` (this package)             | `std` (Zig 0.16)                 | `rust`                                    | `go`                                  |
| ------------------- | ----------- | ------------------------------------- | -------------------------------- | -------------------------------- | ----------------------------------------- | ------------------------------------- |
| `validate-utf8`     | `utf8/`     | `validate_utf8`                       | `validate.utf8`                  | `unicode.utf8ValidateSlice`      | `simdutf8::basic::from_utf8`              | `utf8.Valid`                          |
| `validate-utf8-err` | `utf8-err/` | `validate_utf8_with_errors`           | `validate.utf8WithErrors`        | `unicode.utf8ValidateSlice`      | `simdutf8::compat::from_utf8`             | `utf8.Valid`                          |
| `utf8-to-utf16le`   | `utf8/`     | `convert_utf8_to_utf16le_with_errors` | `convert.utf8ToUtf16le`          | `unicode.utf8ToUtf16Le`          | `encoding_rs::mem::convert_utf8_to_utf16` | `utf8.DecodeRune`, `utf16.AppendRune` |
| `utf16le-to-utf8`   | `utf16le/`  | `convert_utf16le_to_utf8_with_errors` | `convert.utf16leToUtf8`          | `unicode.utf16LeToUtf8`          | `encoding_rs::mem::convert_utf16_to_utf8` | `utf16.DecodeRune`, `utf8.AppendRune` |
| `base64-encode`     | `binary/`   | `binary_to_base64`                    | `base64.encode`, default options | `base64.standard.Encoder.encode` | `base64_simd::STANDARD.encode`            | `base64.StdEncoding.Encode`           |
| `base64-decode`     | `base64/`   | `base64_to_binary`                    | `base64.decode`, default options | `base64.standard.Decoder.decode` | `base64_simd::STANDARD.decode`            | `base64.StdEncoding.Decode`           |

| Arm       | Program                                    | Library                                                                                                                                           |
| --------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `simdutf` | `bench/simdutf/main.cpp`                   | simdutf 9.2.1 from the flake's nixpkgs, with its runtime dispatch, which picks the best kernel for the CPU (`icelake` on AVX-512 Xeons)           |
| `utf`     | `bench/zig/arm.zig`, built with `impl=utf` | this package, ReleaseFast for the host CPU                                                                                                        |
| `std`     | `bench/zig/arm.zig`, built with `impl=std` | Zig 0.16's standard library, ReleaseFast for the host CPU                                                                                         |
| `rust`    | `bench/rust`                               | `simdutf8` 0.1.5, `encoding_rs` 0.8.44, and `base64-simd` 0.8.0, pinned in `Cargo.lock`, built with `-C target-cpu=native`, LTO, one codegen unit |
| `go`      | `bench/go`                                 | Go 1.26's standard library                                                                                                                        |

Every arm times the call alone: the input is in memory and the output buffer is allocated before the loop starts. Every loop is sized the way Go's `testing.B` sizes one, growing the iteration count until a run takes `BENCHTIME_MS`: Go's own `testing.Benchmark`, testingx's `b.loop()` in the Zig arms, and the same rule in the C++ and Rust loops. Throughput counts input bytes: two per UTF-16 code unit, and the base64 text for decoding.

The arms do not all do the same work on bad input, and the table shows where:

- simdutf, this package, and `simdutf8::compat` report where an error is; Zig's std and Go's `utf8.Valid` say only whether there is one, so their `validate-utf8-err` rows time the plain validator.
- `encoding_rs` replaces ill-formed input with U+FFFD instead of reporting it. Every corpus input is valid, so on the corpus it does a checked conversion's work.
- Go's standard library has no slice-to-slice transcoder, so the Go conversions decode one rune at a time and append it to a buffer allocated in advance, which is how a Go program avoids allocating.
- simdutf's decoder skips ASCII whitespace, as this package's does; the others reject it. The corpus's base64 has none.

`bench-utf` looks for each function under its planned name, `utf.validate.utf8` and so on, and skips an operation whose function is not there yet with a `# SKIP` line, which benchstat ignores. The harness runs before the package has every function and fills in as they land.

## Equivalence

`just bench-compare` runs every arm's `check` first and compares each checksum with simdutf's, on every row both arms have. It stops if any differs, so the rows it times do the same work.

## Corpus

`bench/corpus/sources.tsv` lists the fetched texts and `bench/corpus/SHA256SUMS` pins every corpus file, fetched or generated. None of the corpus is committed. `just bench-corpus` fetches into the gitignored `bench/corpus-gen/lipsum/`, generates the rest with `bench/zig/corpus.zig`, and fails on any difference.

The fetched texts are simdutf's benchmark set, the `lipsum` directory of [lemire/unicode_lipsum](https://github.com/lemire/unicode_lipsum) at commit `b0f1d0c1cb0cb168fc08dbf0e3b7100cdec517dc`: lorem-ipsum-style text in nine scripts, in UTF-8 and UTF-16LE. They come from the `simdutf8` crate, by Hans Kratz, MIT or Apache-2.0.

| Directory   | Inputs                                                                                                                              |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `utf8/`     | `arabic`, `chinese`, `emoji`, `hebrew`, `hindi`, `japanese`, `korean`, `latin`, `russian` (65–105 KB each), and generated `ascii-N` |
| `utf8-err/` | `utf8/` with the first byte of its last character replaced by 0xFF, so validation finds an error in the last few bytes              |
| `utf16le/`  | the same nine texts in UTF-16LE (47–174 KB, with a byte-order mark), and `ascii-N` widened to UTF-16                                |
| `binary/`   | `random-N`: random bytes from a fixed seed                                                                                          |
| `base64/`   | `random-N` in standard padded base64                                                                                                |

N is 16, 64, 256, 4096, 65536, and 1048576 bytes. `ascii-N` is lower-case words with spaces, periods, and newlines. Every arm reads a directory's inputs smallest first.

## Method

`just bench-compare [ROUNDS] [OPS...]` (default 6 rounds, all operations) fetches the corpus, builds the five arms, checks equivalence, and measures peak RSS: GNU `time` around one `check` pass per arm and operation, which holds the same inputs and output buffers as the timed loop, so the differences are the arms' runtimes. Then it runs ROUNDS rounds. A round runs each arm once, in an order that rotates each round, so drift on the machine lands on every arm alike. Every run is pinned with `taskset` to the last core, which also makes Go's runtime use one processor. `benchstat` then compares the arms' throughput in GB/s with simdutf as the base; it writes a row with any value under 1 GB/s in thousandths, so `983.1m` is 0.98 GB/s. Everything lands in `zig-out/bench-compare/`: the raw output, the checksums, `rss.txt`, and `benchstat.txt`.

`just bench-compare 10 validate-utf8 base64-decode` runs only those two operations. The Zig arms take testingx's flags after the operations, such as `zig-out/bin/bench-utf bench validate-utf8 --cycles` for cycles and instructions per row.

## Oracle

`utf-oracle` (`bench/oracle/oracle.cpp`, built by `just oracle-build`) reads length-prefixed requests on stdin, runs each through simdutf's checked function, and writes simdutf's `result` and output back: UTF-8, UTF-16LE and BE, and UTF-32 validation and every conversion among them and Latin-1, and base64 both ways with simdutf's options. The protocol is at the top of the source. `bench/oracle/Oracle.zig` is the Zig client, which sends a batch and matches simdutf's error codes with this package's `Error` by name.

`just oracle [N] [SEED]` runs `bench/oracle/compare.zig`: a sweep of every two-byte sequence and a grid of three- and four-byte ones, at the start of the input and across a 64-byte block boundary, then N random and adversarial UTF-8 inputs (default one million) and a quarter as many UTF-16LE and base64 inputs, each through simdutf and through every function of this package that exists. It prints each disagreement on error kind, position, or output with the bytes around it, and runs twice: with simdutf's best kernel and with `SIMDUTF_FORCE_IMPLEMENTATION=fallback`, its scalar code.
