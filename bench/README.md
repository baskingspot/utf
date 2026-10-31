# utf bench

Benchmarks for validation, transcoding, and base64: this package against simdutf, the Rust crates and Go and Zig standard libraries that do the same jobs, over one pinned corpus. Also here: `utf-oracle`, which runs inputs through simdutf so tests and fuzzers can compare error kinds and positions with it.

These are local numbers, for iterating. They are not claims: a number that gets quoted in the README needs a run on dedicated hardware.

## Arms

Each arm is one program with the same contract. Run from the repository root, `bench-<arm> bench [OP...]` reads the operation's inputs from `bench/corpus-gen/` and prints one row per input in the Go benchmark format: `Benchmark<Row>/<input>`, the iterations, ns/op, and MB/s. `bench-<arm> check [OP...]` runs each row once and prints its checksum: validity for the validation operations, the count for the length functions, and for the others the output's length and FNV-1a hash. With no OP an arm runs every operation; `BENCHTIME_MS` (default 100) is how long each row's timed loop runs.

`bench/ops.tsv` lists the operations, and every arm reads it: each operation's name, row name, input directory, and output buffer size. An arm maps the names to its functions and prints a `# SKIP` line, which benchstat ignores, for an operation it has no equivalent for.

| Arm       | Program                                    | Library                                                                                                                                                                                                        |
| --------- | ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `simdutf` | `bench/simdutf/main.cpp`                   | simdutf 9.2.1 from the flake's nixpkgs, with its runtime dispatch, which picks the best kernel for the CPU (`icelake` on AVX-512 Xeons), or the one `kernel` names                                             |
| `utf`     | `bench/zig/arm.zig`, built with `impl=utf` | this package, ReleaseFast for the host CPU unless `optimize`, `cpu`, and `dispatch` say otherwise                                                                                                              |
| `std`     | `bench/zig/arm.zig`, built with `impl=std` | Zig 0.16's standard library, ReleaseFast for the host CPU                                                                                                                                                      |
| `rust`    | `bench/rust`                               | `simdutf8` 0.1.5, `encoding_rs` 0.8.44, and `base64-simd` 0.8.0, pinned in `Cargo.lock`, and the standard library's `is_ascii` and `chars().count()`, built with `-C target-cpu=native`, LTO, one codegen unit |
| `go`      | `bench/go`                                 | Go 1.26's standard library                                                                                                                                                                                     |

Every arm times the call alone: the input is in memory and the output buffer, `out` bytes per input byte plus 64, is allocated before the loop starts. Every loop is sized the way Go's `testing.B` sizes one, growing the iteration count until a run takes `BENCHTIME_MS`: Go's own `testing.Benchmark`, testingx's `b.loop()` in the Zig arms, and the same rule in the C++ and Rust loops. Throughput counts input bytes: two per UTF-16 code unit, four per UTF-32 one, and the base64 text, line breaks included, for decoding.

## Operations

simdutf and this package have every operation; the names follow one pattern for each family. A conversion's checked form validates as it converts and reports the first error; the valid form assumes valid input.

| Operations                                                              | Inputs                                                                 | `simdutf`                                                                               | `utf` (this package)                                                                                         |
| ----------------------------------------------------------------------- | ---------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `validate-F` for F in `ascii`, `utf8`, `utf16le`, `utf16be`, `utf32`    | `F/`                                                                   | `validate_F`                                                                            | `validate.F`                                                                                                 |
| `validate-F-err`                                                        | `F-err/`                                                               | `validate_F_with_errors`                                                                | `validate.FWithErrors`                                                                                       |
| `S-to-D` for S and D in `utf8`, `utf16le`, `utf16be`, `utf32`, `latin1` | `S/`, or `latin1-as-S/`                                                | `convert_S_to_D_with_errors`                                                            | `convert.SToD`                                                                                               |
| `valid-S-to-D`                                                          | the same                                                               | `convert_valid_S_to_D`                                                                  | `convert.validSToD`                                                                                          |
| `utf16-from-F`, `utf8-from-F`                                           | `F/`                                                                   | `utf16_length_from_F`, `utf8_length_from_F`                                             | `length.utf16FromF`, `length.utf8FromF`                                                                      |
| `count-F` for F in `utf8`, `utf16le`, `utf16be`                         | `F/`                                                                   | `count_F`                                                                               | `length.countF`                                                                                              |
| `base64-encode`, `base64-encode-url`                                    | `binary/`                                                              | `binary_to_base64`, with `base64_url` (no padding)                                      | `base64.encode`, with `.alphabet = .url, .padding = false`                                                   |
| `base64-decode`, `-url`, `-strict`, `-partial`, `-mime`                 | `base64/`, `base64url/`, `base64/`, `base64-unpadded/`, `base64-mime/` | `base64_to_binary`, with `base64_url`, `strict`, `stop_before_partial`, or the defaults | `base64.decode`, with `.alphabet = .url`, `.last_chunk = .strict` or `.stop_before_partial`, or the defaults |

A conversion to Latin-1 reads `latin1-as-S/`, text every form can hold in Latin-1. The exceptions in simdutf: conversions from Latin-1 have one form, `convert_latin1_to_D`, which both rows time, and the UTF-16 byte swaps are `change_endianness_utf16`, after `validate_utf16le_with_errors` (or `be`) for the checked form. The length functions that need no SIMD are left out: `utf16FromLatin1`, `utf32FromLatin1`, `latin1FromUtf16`, and `latin1FromUtf32` return the input length, and `utf32FromUtf8`, `latin1FromUtf8`, and `utf32FromUtf16le` and `be` are the code-point counts in both libraries.

The other arms time an operation only where their library has a function for it:

| Operation                                      | `std` (Zig 0.16)                    | `rust`                                            | `go`                                                    |
| ---------------------------------------------- | ----------------------------------- | ------------------------------------------------- | ------------------------------------------------------- |
| `validate-ascii`, `-err`                       |                                     | `<[u8]>::is_ascii`                                |                                                         |
| `validate-utf8`                                | `unicode.utf8ValidateSlice`         | `simdutf8::basic::from_utf8`                      | `utf8.Valid`                                            |
| `validate-utf8-err`                            | `unicode.utf8ValidateSlice`         | `simdutf8::compat::from_utf8`                     | `utf8.Valid`                                            |
| `validate-utf16le`, `-err`                     |                                     | `encoding_rs::mem::utf16_valid_up_to`             |                                                         |
| `utf8-to-utf16le`                              | `unicode.utf8ToUtf16Le`             | `encoding_rs::mem::convert_utf8_to_utf16`         | `utf8.DecodeRune`, `utf16.AppendRune`                   |
| `valid-utf8-to-utf16le`                        |                                     | `encoding_rs::mem::convert_str_to_utf16`          |                                                         |
| `utf8-to-utf32`                                |                                     |                                                   | `utf8.DecodeRune`                                       |
| `valid-utf8-to-latin1`                         |                                     | `encoding_rs::mem::convert_utf8_to_latin1_lossy`  |                                                         |
| `utf16le-to-utf8`                              | `unicode.utf16LeToUtf8`             | `encoding_rs::mem::convert_utf16_to_utf8`         | `utf16.DecodeRune`, `utf8.AppendRune`                   |
| `valid-utf16le-to-latin1`                      |                                     | `encoding_rs::mem::convert_utf16_to_latin1_lossy` |                                                         |
| `utf32-to-utf8`                                |                                     |                                                   | `utf8.ValidRune`, `utf8.AppendRune`                     |
| `latin1-to-utf8`, `valid-latin1-to-utf8`       |                                     | `encoding_rs::mem::convert_latin1_to_utf8`        |                                                         |
| `latin1-to-utf16le`, `valid-latin1-to-utf16le` |                                     | `encoding_rs::mem::convert_latin1_to_utf16`       |                                                         |
| `utf16-from-utf8`                              | `unicode.calcUtf16LeLen`            |                                                   |                                                         |
| `utf8-from-utf16le`                            | `unicode.calcWtf8Len`               |                                                   |                                                         |
| `count-utf8`                                   | `unicode.utf8CountCodepoints`       | `str::chars().count()`                            | `utf8.RuneCount`                                        |
| `count-utf16le`                                | `unicode.utf16CountCodepoints`      |                                                   |                                                         |
| `base64-encode`                                | `base64.standard.Encoder`           | `base64_simd::STANDARD.encode`                    | `base64.StdEncoding.Encode`                             |
| `base64-encode-url`                            | `base64.url_safe_no_pad.Encoder`    | `base64_simd::URL_SAFE_NO_PAD.encode`             | `base64.RawURLEncoding.Encode`                          |
| `base64-decode`, `base64-decode-strict`        | `base64.standard.Decoder`           | `base64_simd::STANDARD.decode`                    | `base64.StdEncoding.Decode`, and `.Strict()` for strict |
| `base64-decode-url`                            | `base64.url_safe_no_pad.Decoder`    | `base64_simd::URL_SAFE_NO_PAD.decode`             | `base64.RawURLEncoding.Decode`                          |
| `base64-decode-mime`                           | `base64.standard.decoderWithIgnore` | `base64_simd::forgiving_decode`                   | `base64.StdEncoding.Decode`                             |

The arms do not all do the same work, and the table shows where:

- simdutf, this package, `simdutf8::compat`, and `utf16_valid_up_to` report where an error is; Zig's std, Go's `utf8.Valid`, and Rust's `is_ascii` say only whether there is one, so their `-err` rows time the plain validator.
- `encoding_rs` replaces ill-formed input with U+FFFD instead of reporting it. Every corpus input it converts is valid, so on the corpus it does a checked conversion's work. Its Latin-1 conversions and `convert_str_to_utf16` assume valid input, as the valid forms do.
- Zig's std validates as it counts, except `calcWtf8Len`; simdutf's length functions assume valid input; this package's are defined on any input and do not validate.
- Go's standard library has no slice-to-slice transcoder, so the Go conversions decode one rune at a time and store or append it to a buffer allocated in advance, which is how a Go program avoids allocating.
- simdutf's decoder skips ASCII whitespace, as this package's does; Zig's std decoder with ignored characters skips the same set, Rust's forgiving decoder strips whitespace into the output buffer and decodes there, and Go's skips CR and LF. Only `base64-mime/` has whitespace. The std, Rust, and Go standard decoders reject a missing pad (and std's and Rust's nonzero bits past the last byte), so `base64-decode` is a strict decode in those arms.

`bench-utf` looks for each function under its planned name, `utf.validate.utf8` and so on, and skips an operation whose function is not there yet with a `# SKIP` line. The harness runs before the package has every function and fills in as they land.

## Equivalence

`just bench-compare` runs every arm's `check` first and compares each checksum with simdutf's, on every row both arms have. It stops if any differs, so the rows it times do the same work.

## Corpus

`bench/corpus/sources.tsv` lists the fetched texts and `bench/corpus/SHA256SUMS` pins every corpus file, fetched or generated. None of the corpus is committed. `just bench-corpus` fetches into the gitignored `bench/corpus-gen/lipsum/`, generates the rest with `bench/zig/corpus.zig`, and fails on any difference.

The fetched texts are simdutf's benchmark set, the `lipsum` directory of [lemire/unicode_lipsum](https://github.com/lemire/unicode_lipsum) at commit `b0f1d0c1cb0cb168fc08dbf0e3b7100cdec517dc`: lorem-ipsum-style text in nine scripts, in UTF-8 and UTF-16LE. They come from the `simdutf8` crate, by Hans Kratz, MIT or Apache-2.0.

| Directory                                                                         | Inputs                                                                                                                                                                                                   |
| --------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `utf8/`                                                                           | `arabic`, `chinese`, `emoji`, `hebrew`, `hindi`, `japanese`, `korean`, `latin`, `russian` (65–105 KB each), and generated `ascii-N`                                                                      |
| `utf16le/`                                                                        | the same nine texts in UTF-16LE (47–174 KB, with a byte-order mark), and `ascii-N` widened to UTF-16                                                                                                     |
| `utf16be/`                                                                        | `utf16le/` byte-swapped                                                                                                                                                                                  |
| `utf32/`                                                                          | `utf8/` in UTF-32LE                                                                                                                                                                                      |
| `ascii/`                                                                          | the ASCII texts of `utf8/`: `ascii-N` and `latin`                                                                                                                                                        |
| `latin1/`                                                                         | `ascii/`, and generated `latin1-N`: `ascii-N`'s words with one letter in eight an accented one from 0xE0–0xFF                                                                                            |
| `latin1-as-utf8/`, `latin1-as-utf16le/`, `latin1-as-utf16be/`, `latin1-as-utf32/` | `latin1/` in each Unicode form                                                                                                                                                                           |
| `ascii-err/`, `utf8-err/`, `utf16le-err/`, `utf16be-err/`, `utf32-err/`           | each valid directory with an error in its last character: the last byte made 0xFF in ASCII, the first byte of the last character made 0xFF in UTF-8, the last code unit made 0xD800 in UTF-16 and UTF-32 |
| `binary/`                                                                         | `random-N`: random bytes from a fixed seed                                                                                                                                                               |
| `base64/`, `base64url/`, `base64-unpadded/`                                       | `random-N` in standard padded base64, URL-safe base64 without padding, and standard base64 without padding                                                                                               |
| `base64-mime/`                                                                    | `base64/` in lines of 76 characters, each ended by CRLF, as MIME bodies are                                                                                                                              |

N is 16, 64, 256, 4096, 65536, and 1048576 bytes. `ascii-N` is lower-case words with spaces, periods, and newlines. Every arm reads a directory's inputs smallest first.

## Method

`just bench-compare [ROUNDS] [OPS...]` (default 6 rounds, all operations) fetches the corpus, builds the five arms, checks equivalence, and measures peak RSS: GNU `time` around one `check` pass per arm and operation, which holds the same inputs and output buffers as the timed loop, so the differences are the arms' runtimes. Then it runs ROUNDS rounds. A round runs each arm once, in an order that rotates each round, so drift on the machine lands on every arm alike. Every run is pinned with `taskset` to the last core, which also makes Go's runtime use one processor. `benchstat` then compares the arms' throughput in GB/s with simdutf as the base, into `benchstat.txt`; it writes a row with any value under 1 GB/s in thousandths, so `983.1m` is 0.98 GB/s. Last comes the summary, one line per operation: this package's geometric-mean throughput, its geometric-mean ratio to each other arm over the inputs both have (above 1, this package is faster), and its slowest input against simdutf. `just bench-summary [DIR]` prints it again for a saved run. Everything lands in `zig-out/bench-compare/`: the raw output, the checksums, `config.txt` (the variables and simdutf's kernel), `rss.txt`, `benchstat.txt`, and `summary.txt`.

`just bench-compare 10 validate-utf8 base64-decode` runs only those two operations. Four variables, set before the recipe name, change the builds:

| Variable   | Default        | Values                                                       | Effect                                                                                                                                                                                               |
| ---------- | -------------- | ------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `optimize` | `ReleaseFast`  | `ReleaseSafe`, or any Zig optimize mode                      | the `utf` arm's optimize mode                                                                                                                                                                        |
| `cpu`      | `native`       | `baseline`, `x86_64_v2`, `x86_64_v3`, or any Zig CPU model   | the CPU the `utf` arm is built for                                                                                                                                                                   |
| `dispatch` | the package's  | `true`, `false`                                              | whether the `utf` arm picks its x86-64 kernels at runtime; the package does by default for `baseline` and the `x86_64` levels, which is how distributions build, and not for `native` or a named CPU |
| `kernel`   | simdutf's pick | `haswell`, `westmere`, `fallback`, or another simdutf kernel | `SIMDUTF_FORCE_IMPLEMENTATION` for the simdutf arm                                                                                                                                                   |

`just cpu=baseline bench-compare` measures a distribution's build, which dispatches at runtime, against simdutf's runtime pick, as a distribution's user gets both. `just cpu=baseline dispatch=false kernel=fallback bench-compare` measures the plain generic path against simdutf's scalar kernel, and `just cpu=x86_64_v3 dispatch=false kernel=haswell bench-compare` an AVX2 build against simdutf's AVX2 kernel. The other arms keep their builds. The Zig arms take testingx's flags after the operations, such as `zig-out/bin/bench-utf bench validate-utf8 --cycles` for cycles and instructions per row.

## Oracle

`utf-oracle` (`bench/oracle/oracle.cpp`, built by `just oracle-build`) reads length-prefixed requests on stdin, runs each through simdutf's checked function, and writes simdutf's `result` and output back: UTF-8, UTF-16LE and BE, and UTF-32 validation and every conversion among them and Latin-1, and base64 both ways with simdutf's options. The protocol is at the top of the source. `bench/oracle/Oracle.zig` is the Zig client, which sends a batch and matches simdutf's error codes with this package's `Error` by name.

`just oracle [N] [SEED]` runs `bench/oracle/compare.zig`: a sweep of every two-byte sequence and a grid of three- and four-byte ones, at the start of the input and across a 64-byte block boundary, then N random and adversarial UTF-8 inputs (default one million) and a quarter as many UTF-16LE and base64 inputs, each through simdutf and through every function of this package that exists. It prints each disagreement on error kind, position, or output with the bytes around it, and runs twice: with simdutf's best kernel and with `SIMDUTF_FORCE_IMPLEMENTATION=fallback`, its scalar code.
