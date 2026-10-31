# Validation, wave 2, 2026-10-31

The wave-2 pass over `src/validate.zig`: every public validator dispatched at runtime, long inputs loaded from 64-byte boundaries, masked loads for short inputs on AVX-512, error positions from lane masks, and the decisions 2 and 3 of the plan for validation. Measured against simdutf (`icelake` and `haswell`), Rust, and Zig's std with `just bench-compare`, and with a scratch suite for the A/Bs. Compare within a table, not across tables.

- Machine: Amp orb, KVM guest, Intel Xeon @ 2.60GHz (Ice Lake server, AVX-512 with VBMI2), 4 vCPUs: CPUs 2 and 3 are one core. Every timed process pinned to CPU 3, with nothing on CPU 2 while it ran.
- Zig 0.16.0 ReleaseFast; simdutf 9.2.1 (nixpkgs); Rust 1.99.0 (`simdutf8` 0.1.5, `encoding_rs`), `-C target-cpu=native`.
- Harness runs, 6 rounds at `BENCHTIME_MS=100`, the ten validation operations of `bench/ops.tsv` (the UTF-16 and UTF-32 operations rerun after their last changes, at one and two blocks; the other operations did not change after their run):
  - **native**: `just bench-compare 6 validate-...`, the package built for the host (`.avx512`, no dispatch) against simdutf's `icelake`, as committed.
  - **native, harness fixed**: the same, with two local edits that are not in this branch: `bench/zig/arm.zig` passes one word of each result to `doNotOptimizeAway` instead of the 16-byte `Out` union, and `dispatch.call` calls the kernel with `@call(.auto, ...)` instead of `.always_inline` in builds that do not dispatch. Both remove a copy that stalls store-to-load forwarding; see [What sets the short rows](#what-sets-the-short-rows).
  - **AVX2**: `just cpu=x86_64_v3 dispatch=false kernel=haswell bench-compare 6 validate-...`.
- A/Bs: the scratch suite in [validate-wave2-20261031/suite/](validate-wave2-20261031/suite/): every operation and form (plain, `WithErrors` on valid input, `Err` on input with an error in its last character) on five texts (ASCII, Latin, Arabic, Chinese, emoji) at 7 bytes to 1 MiB, each input 16 bytes past a 64-byte boundary as the harness's are, 16 calls per testingx iteration through `@call(.never_inline)`, and a C++ driver for simdutf's kernels on the same inputs. `ab.sh` alternates the binaries round by round on CPU 3 and runs benchstat; `cmp.py` prints medians and ratios. Raw output and benchstat per A/B in [validate-wave2-20261031/ab/](validate-wave2-20261031/ab/).
- `head` is `7d7cb56`, wave 1. Builds in the suite have dispatch off, as the harness's native build does.

## Takeaways

- **Against `icelake`** (native, as committed): geomean 1.28 over the ten validation operations, from 0.81 in [baseline-20261031.md](baseline-20261031.md). Per operation: ASCII 1.33, ASCII-err 1.15, UTF-8 1.36, UTF-8-err 1.72, UTF-16LE 1.03, UTF-16LE-err 1.39, UTF-16BE 1.34, UTF-16BE-err 1.34, UTF-32 1.15, UTF-32-err 1.08. With the harness's two copies removed: 1.34, and no operation under 1.10.
- **Long inputs** (4 KiB to 1 MiB and the corpus texts), native: ASCII 142–177 GB/s against `icelake`'s 129–168 (was 52 against 147 on the 87 KB Latin text); UTF-16 141–182 against 132–150 (was 45–53), 1.5–2.0× `icelake` in the `-err` and big-endian forms, where simdutf has no fast path; UTF-32 118–121 against 97–99 (was 46); UTF-8 on non-ASCII text 19.6–20.0 against 15.9–16.5. 1 MiB rows are memory-bound and level (31–34 GB/s for UTF-16 and UTF-32, 86–124 for ASCII, varying run to run in both libraries).
- **Against `haswell`** (AVX2 build): geomean 2.45; every operation leads (UTF-8 1.31, UTF-8-err 1.46, ASCII 1.53, UTF-32 1.65, the rest 1.8–3.8). Slowest row 0.92, UTF-8 on 64 bytes of ASCII.
- **Short inputs** in the harness are set by costs outside the kernels (see [What sets the short rows](#what-sets-the-short-rows)). In the scratch suite, which calls the package as a caller that does not inline it, 16 bytes of ASCII validate in 2.4 ns, UTF-16 and UTF-32 in 7–45 bytes run 1.2–1.9× faster than wave 1 from masked loads, and UTF-16 at one and two blocks (64–128 bytes) 1.35–2.0× faster than before the two-block path.
- **Rust, before the harness fix** (`is_ascii` inlined into its loop, ours inlined into some rows): it led only ASCII validation at 16–256 bytes, 6.3 against 4.7 GB/s at 16 bytes, 21.9 against 17.5 at 64, 52 against 37 at 256. At 16 bytes testingx's `B.loop()`, a call per iteration, alone costs 2.8 ns (a row that calls nothing runs at 5.7 GB/s); Rust's loop and `is_ascii` together take 2.5 ns. With both called out of line (next section) we lead it there too. From 4 KiB we are 1.6–2.8× Rust on ASCII and 1.2–1.5× on UTF-8, and 5–20× `encoding_rs` on UTF-16.
- **Memory**: validation allocates nothing; peak RSS unchanged (the inputs plus the process, the same as Zig std's).
- **Short inputs, harness at `d3cd9ab`**: see the next section. With the harness's result copy removed, ASCII and UTF-8 lead Rust at 16–256 bytes but for one row (0.96), and UTF-8 on ASCII leads `icelake` from 16 bytes; as committed, the copy puts every short row under simdutf.
- **Correctness**: the differential tests run through the public functions on every tier the CPU has (`dispatch.forEachLevel`), and pass in Debug on native, in ReleaseSafe on native, `x86_64_v3`, `x86_64_v2`, and baseline, and under qemu on aarch64 and aarch64_be. `just oracle`: see the end.

## Short inputs after the harness fix (`d3cd9ab`)

`e772079` made every Zig arm call out of line and Rust call through a function pointer ([harness-fix-20261031.md](harness-fix-20261031.md)). Rerun on `d3cd9ab` with this branch, 6 rounds of the ten operations, three ways: native as committed (`harness/h2-native`), native with the row passing one word of the result to `doNotOptimizeAway` and `dispatch.call` using `.auto` (`harness/h2-hp`, the edits in `harness/fixed.diff`), and AVX2 against `haswell` as committed (`harness/h2-avx2`). The `÷ rust` and `÷ std` columns are from the one-word run, where Rust and std were measured alongside.

Out of line, the row still reads the 16-byte `Out` union back whole right after the call wrote it by fields (`vmovups xmm0, [rbp-0x70]` after the call in every `opBenchmark` row), so every Zig row now pays the forwarding stall, where before only rows that LLVM did not inline did: that is most of the "10.4 ns for 16 bytes of UTF-8" (one word: 5.5 ns, against simdutf's 5.8 and Rust's 9.5). std's rows pay it too.

| Row                          |   utf | ÷ icelake | utf, one word | ÷ icelake | ÷ rust | ÷ std | AVX2 utf | ÷ haswell |
| ---------------------------- | ----: | --------: | ------------: | --------: | -----: | ----: | -------: | --------: |
| ValidateAscii/ascii-16       |  1.82 |      0.73 |          4.05 |      1.63 |   1.94 |     - |     1.82 |      1.45 |
| ValidateAscii/ascii-64       |  7.29 |      0.77 |         16.19 |      1.71 |   1.99 |     - |     7.30 |      0.83 |
| ValidateAscii/ascii-256      | 27.41 |      0.83 |         41.60 |      1.26 |   1.43 |     - |    28.17 |      1.04 |
| ValidateAsciiErr/ascii-16    |  1.82 |      0.77 |          3.52 |      1.49 |   1.67 |     - |     1.80 |      1.96 |
| ValidateAsciiErr/ascii-64    |  6.62 |      0.53 |         10.98 |      0.88 |   1.30 |     - |     6.75 |      1.80 |
| ValidateAsciiErr/ascii-256   | 24.00 |      0.85 |         28.99 |      1.02 |   0.96 |     - |    24.20 |      1.77 |
| ValidateUtf8/ascii-16        |  1.68 |      0.61 |          2.93 |      1.07 |   1.72 |  1.89 |     1.70 |      1.46 |
| ValidateUtf8/ascii-64        |  6.41 |      0.71 |          9.87 |      1.09 |   1.35 |  0.94 |     6.80 |      0.94 |
| ValidateUtf8/ascii-256       | 23.29 |      1.05 |         31.78 |      1.46 |   1.20 |  1.13 |    24.89 |      1.06 |
| ValidateUtf8Err/ascii-16     |  1.24 |      1.49 |          1.39 |      1.66 |   1.60 |  0.90 |     1.11 |      1.89 |
| ValidateUtf8Err/ascii-64     |  4.70 |      1.72 |          5.17 |      1.89 |   1.73 |  1.36 |     4.23 |      1.68 |
| ValidateUtf8Err/ascii-256    | 17.53 |      2.56 |         18.15 |      2.68 |   1.59 |  1.46 |    15.65 |      1.41 |
| ValidateUtf16le/ascii-16     |  3.32 |      0.77 |          5.84 |      1.35 |   1.77 |     - |     3.21 |      1.49 |
| ValidateUtf16le/ascii-64     | 13.23 |      0.77 |         23.38 |      1.39 |   4.30 |     - |    13.67 |      4.70 |
| ValidateUtf16le/ascii-256    | 37.77 |      0.83 |         40.94 |      0.90 |   6.82 |     - |    35.92 |      4.38 |
| ValidateUtf16leErr/ascii-16  |  3.10 |      0.69 |          4.96 |      1.10 |   2.18 |     - |     3.02 |      1.43 |
| ValidateUtf16leErr/ascii-64  | 11.03 |      0.75 |         13.38 |      0.91 |   2.96 |     - |    10.83 |      3.77 |
| ValidateUtf16leErr/ascii-256 | 36.07 |      0.95 |         37.81 |      1.00 |   6.90 |     - |    31.89 |      3.69 |
| ValidateUtf16be/ascii-16     |  3.31 |      0.67 |          5.83 |      1.17 |      - |     - |     3.20 |      1.49 |
| ValidateUtf16be/ascii-64     | 13.25 |      0.70 |         23.39 |      1.24 |      - |     - |    13.23 |      4.55 |
| ValidateUtf16be/ascii-256    | 36.10 |      1.09 |         39.70 |      1.20 |      - |     - |    33.56 |      4.34 |
| ValidateUtf16beErr/ascii-16  |  3.11 |      0.69 |          4.76 |      1.06 |      - |     - |     2.94 |      1.39 |
| ValidateUtf16beErr/ascii-64  | 11.05 |      0.78 |         13.74 |      0.97 |      - |     - |    10.55 |      4.25 |
| ValidateUtf16beErr/ascii-256 | 37.00 |      1.03 |         38.78 |      1.08 |      - |     - |    33.06 |      4.16 |
| ValidateUtf32/ascii-16       |  6.62 |      0.97 |         11.69 |      1.70 |      - |     - |     6.61 |      1.28 |
| ValidateUtf32/ascii-64       | 24.08 |      1.00 |         35.18 |      1.46 |      - |     - |    24.22 |      1.46 |
| ValidateUtf32/ascii-256      | 72.36 |      1.08 |         77.02 |      1.15 |      - |     - |    41.06 |      1.23 |
| ValidateUtf32Err/ascii-16    |  6.84 |      0.62 |         12.31 |      1.12 |      - |     - |     6.83 |      1.39 |
| ValidateUtf32Err/ascii-64    |  9.32 |      0.34 |         12.27 |      0.45 |      - |     - |    13.60 |      1.06 |
| ValidateUtf32Err/ascii-256   | 75.57 |      1.13 |         84.90 |      1.28 |      - |     - |    50.61 |      2.95 |

Geomeans: as committed 1.22 of `icelake` (every operation's short rows under simdutf), one word 1.32, AVX2 2.38 of `haswell`. With one word, every ASCII and UTF-8 row leads Rust (1.20–1.99) but ASCII with an error at 256 bytes (0.96); std, which the one-word edit also helps, still leads UTF-8 at 64 bytes (0.94) and UTF-8 with an error at 16 (0.90); UTF-8 on ASCII leads `icelake` at 16 and 64 bytes (1.07, 1.09). What is left under `icelake` at 16–256 bytes: ASCII with an error at 64 bytes (0.88), UTF-16LE at 256 units (0.90) and UTF-16 with an error at 64 units (0.91–0.97). `ValidateUtf32Err/ascii-64` read 0.45 in this run and 0.88 (23.8 against 27.1 GB/s) in the A/B below, run alone; the harness's short rows still spread by that much.

Taking the UTF-8 path from one block up out of line, so the 16-byte path saves no registers (A/B `hab-split`, harness arm with one word, 5 rounds): +14% at 16 bytes, −7% at 64, −16% at 256. Not taken.

## What sets the short rows

Three costs outside the kernels decide the harness's rows under 256 bytes. Two are copies of a 16-byte result that stall store-to-load forwarding: two narrow stores, then one 16-byte load of the same bytes, about 12–15 cycles.

1. **`dispatch.call`, for `Result`** (owner: dispatch). In a build that does not dispatch, `call` returns `@call(.always_inline, f, args)`; the inlined kernel's `Result` lands in a stack slot by field and is copied to the caller's result with one 16-byte move (`vmovups`). In a dispatching build the same happens after the call to the tier's object. Every `WithErrors` function pays it on every call: `asciiWithErrors` on 16 valid bytes went from 5.6 to 1.9 GB/s when it moved behind `dispatch.call` (A/B `asc`), and `@call(.auto, ...)` in the `.off` branch restores the field stores (5.4 GB/s, A/B `sent`, column `x3`). The dispatch orb's "utf8WithErrors on 8 bytes takes 13 ns against 5 for utf8" is this.
2. **The harness's `doNotOptimizeAway(f(in, out))`** (owner: harness). `Utf.wrap`'s `run` returns the 16-byte `Out` union by fields, and the row reads it back whole: about 6 ns per call on every Zig row whose function is not inlined into the row. `ValidateUtf8/ascii-16` goes from 1.60 to 2.86 GB/s with one word passed instead (native against native, harness fixed). Rows whose function inlines into the row (`ValidateAscii`) do not pay it.
3. **testingx's `B.loop()`**: a call per iteration, 2.8 ns at 16 bytes, where the C++ and Rust loops are inline.

## Harness: native against `icelake`

GB/s, median of 6. Column 1 is as committed; column 2 has the two local harness edits above. `rust` is `simdutf8` (UTF-8), `is_ascii` (ASCII), or `encoding_rs` (UTF-16LE), from run 1.

| Row                              |    utf | simdutf |    ÷ | utf, fixed | simdutf |    ÷ |   rust |
| -------------------------------- | -----: | ------: | ---: | ---------: | ------: | ---: | -----: |
| ValidateAscii/ascii-16           |   4.74 |    2.34 | 2.03 |       5.73 |    2.47 | 2.32 |   6.30 |
| ValidateAscii/ascii-64           |  17.50 |    9.06 | 1.93 |      17.47 |    9.32 | 1.87 |  21.94 |
| ValidateAscii/ascii-256          |  36.91 |   30.47 | 1.21 |      41.77 |   32.82 | 1.27 |  52.42 |
| ValidateAscii/ascii-4096         | 175.28 |  150.68 | 1.16 |     177.18 |  152.06 | 1.17 |  93.63 |
| ValidateAscii/ascii-65536        | 142.33 |  136.73 | 1.04 |     146.99 |  139.23 | 1.06 |  53.91 |
| ValidateAscii/latin              | 143.21 |  129.36 | 1.11 |     146.26 |  145.37 | 1.01 |  51.33 |
| ValidateAscii/ascii-1048576      | 120.77 |  105.93 | 1.14 |      85.84 |   91.36 | 0.94 |  51.73 |
| ValidateAsciiErr/ascii-16        |   3.73 |    1.84 | 2.03 |       4.38 |    2.27 | 1.93 |   8.55 |
| ValidateAsciiErr/ascii-64        |  12.18 |   10.64 | 1.14 |      13.14 |   12.09 | 1.09 |  27.94 |
| ValidateAsciiErr/ascii-256       |  26.27 |   23.88 | 1.10 |      28.38 |   27.49 | 1.03 |  48.40 |
| ValidateAsciiErr/ascii-4096      | 176.96 |  167.43 | 1.06 |     173.49 |  180.50 | 0.96 |  79.98 |
| ValidateAsciiErr/ascii-65536     | 144.09 |  144.30 | 1.00 |     145.09 |  145.87 | 0.99 |  51.12 |
| ValidateAsciiErr/latin           | 143.45 |  144.83 | 0.99 |     143.07 |  146.59 | 0.98 |  52.71 |
| ValidateAsciiErr/ascii-1048576   | 123.87 |  125.60 | 0.99 |     106.44 |   97.05 | 1.10 |  48.90 |
| ValidateUtf8/ascii-16            |   1.60 |    2.67 | 0.60 |       2.86 |    2.68 | 1.07 |   2.62 |
| ValidateUtf8/ascii-64            |   6.12 |    8.70 | 0.70 |       9.77 |    8.80 | 1.11 |  14.08 |
| ValidateUtf8/ascii-256           |  22.76 |   20.92 | 1.09 |      31.25 |   21.70 | 1.44 |  38.42 |
| ValidateUtf8/ascii-4096          | 136.32 |   57.45 | 2.37 |     156.28 |   58.10 | 2.69 |  96.13 |
| ValidateUtf8/ascii-65536         | 144.09 |   61.42 | 2.35 |     145.33 |   64.64 | 2.25 | 101.50 |
| ValidateUtf8/emoji               |  19.79 |   16.46 | 1.20 |      19.88 |   16.39 | 1.21 |  13.06 |
| ValidateUtf8/hebrew              |  19.81 |   16.32 | 1.21 |      19.71 |   16.39 | 1.20 |  13.04 |
| ValidateUtf8/korean              |  19.64 |   16.36 | 1.20 |      19.95 |   16.46 | 1.21 |  13.55 |
| ValidateUtf8/japanese            |  19.89 |   15.92 | 1.25 |      19.83 |   16.54 | 1.20 |  13.13 |
| ValidateUtf8/chinese             |  19.88 |   15.86 | 1.25 |      19.74 |   16.52 | 1.19 |  12.12 |
| ValidateUtf8/arabic              |  19.96 |   15.85 | 1.26 |      19.58 |   16.46 | 1.19 |  13.30 |
| ValidateUtf8/latin               | 145.13 |   43.68 | 3.32 |     145.53 |   44.55 | 3.27 |  98.62 |
| ValidateUtf8/hindi               |  19.94 |   15.83 | 1.26 |      19.69 |   16.46 | 1.20 |  13.64 |
| ValidateUtf8/russian             |  19.58 |   15.92 | 1.23 |      19.53 |   16.52 | 1.18 |  13.33 |
| ValidateUtf8/ascii-1048576       | 123.42 |   57.00 | 2.17 |      93.18 |   61.56 | 1.51 |  82.46 |
| ValidateUtf8Err/ascii-16         |   1.14 |    0.81 | 1.42 |       1.39 |    0.83 | 1.66 |   1.34 |
| ValidateUtf8Err/ascii-64         |   3.68 |    2.69 | 1.37 |       5.08 |    2.68 | 1.89 |   3.98 |
| ValidateUtf8Err/ascii-256        |  15.63 |    6.69 | 2.34 |      17.82 |    6.66 | 2.68 |  13.82 |
| ValidateUtf8Err/ascii-4096       | 121.98 |   37.76 | 3.23 |     131.68 |   37.97 | 3.47 |  77.84 |
| ValidateUtf8Err/ascii-65536      | 140.81 |   54.93 | 2.56 |     140.06 |   55.58 | 2.52 |  95.95 |
| ValidateUtf8Err/emoji            |  19.46 |   14.04 | 1.39 |      18.95 |   14.33 | 1.32 |  13.20 |
| ValidateUtf8Err/hebrew           |  19.92 |   13.88 | 1.44 |      19.31 |   13.96 | 1.38 |  13.10 |
| ValidateUtf8Err/korean           |  19.81 |   15.20 | 1.30 |      19.71 |   15.77 | 1.25 |  13.19 |
| ValidateUtf8Err/japanese         |  18.77 |   14.79 | 1.27 |      19.35 |   15.09 | 1.28 |  12.55 |
| ValidateUtf8Err/chinese          |  19.18 |   14.97 | 1.28 |      19.12 |   15.13 | 1.26 |  13.22 |
| ValidateUtf8Err/arabic           |  19.48 |   14.81 | 1.32 |      19.59 |   14.89 | 1.32 |  13.23 |
| ValidateUtf8Err/latin            | 138.53 |   39.17 | 3.54 |     143.34 |   39.22 | 3.65 |  90.67 |
| ValidateUtf8Err/hindi            |  19.51 |   13.68 | 1.43 |      19.80 |   14.64 | 1.35 |  12.50 |
| ValidateUtf8Err/russian          |  19.61 |   14.92 | 1.31 |      19.89 |   14.97 | 1.33 |  13.35 |
| ValidateUtf8Err/ascii-1048576    | 120.93 |   49.66 | 2.44 |     106.64 |   53.42 | 2.00 |  75.18 |
| ValidateUtf16le/ascii-16         |   3.19 |    4.31 | 0.74 |       5.65 |    4.26 | 1.33 |   3.92 |
| ValidateUtf16le/ascii-64         |  12.79 |   14.18 | 0.90 |      22.94 |   14.09 | 1.63 |   5.44 |
| ValidateUtf16le/ascii-256        |  37.74 |   45.68 | 0.83 |      40.49 |   45.40 | 0.89 |   5.98 |
| ValidateUtf16le/ascii-4096       | 158.03 |  132.04 | 1.20 |     157.06 |  131.24 | 1.20 |   6.16 |
| ValidateUtf16le/japanese         | 181.86 |  148.95 | 1.22 |     177.69 |  149.15 | 1.19 |   6.19 |
| ValidateUtf16le/chinese          | 179.99 |  149.97 | 1.20 |     175.74 |  149.04 | 1.18 |   6.20 |
| ValidateUtf16le/korean           | 141.63 |  142.28 | 1.00 |     136.69 |  142.09 | 0.96 |   6.19 |
| ValidateUtf16le/hindi            | 142.28 |  140.88 | 1.01 |     142.29 |  138.65 | 1.03 |   6.20 |
| ValidateUtf16le/emoji            |  54.77 |   31.81 | 1.72 |      54.20 |   31.66 | 1.71 |   3.69 |
| ValidateUtf16le/hebrew           | 140.97 |  142.00 | 0.99 |     139.87 |  139.18 | 1.00 |   6.21 |
| ValidateUtf16le/arabic           | 143.16 |  143.28 | 1.00 |     137.77 |  142.48 | 0.97 |   6.18 |
| ValidateUtf16le/russian          | 142.96 |  141.43 | 1.01 |     138.43 |  140.64 | 0.98 |   6.20 |
| ValidateUtf16le/ascii-65536      | 143.75 |  142.09 | 1.01 |     142.67 |  139.30 | 1.02 |   6.20 |
| ValidateUtf16le/latin            | 144.11 |  142.95 | 1.01 |     141.02 |  139.83 | 1.01 |   6.18 |
| ValidateUtf16le/ascii-1048576    |  34.93 |   36.11 | 0.97 |      34.10 |   34.99 | 0.97 |   6.10 |
| ValidateUtf16leErr/ascii-16      |   3.09 |    4.51 | 0.69 |       4.95 |    4.39 | 1.13 |   2.38 |
| ValidateUtf16leErr/ascii-64      |  11.01 |   14.89 | 0.74 |      14.32 |   14.69 | 0.97 |   4.63 |
| ValidateUtf16leErr/ascii-256     |  37.73 |   37.80 | 1.00 |      39.99 |   36.69 | 1.09 |   5.63 |
| ValidateUtf16leErr/ascii-4096    | 158.89 |   86.87 | 1.83 |     158.18 |   85.96 | 1.84 |   6.15 |
| ValidateUtf16leErr/japanese      | 181.88 |   91.47 | 1.99 |     173.07 |   91.32 | 1.90 |   6.20 |
| ValidateUtf16leErr/chinese       | 178.77 |   93.03 | 1.92 |     178.75 |   91.81 | 1.95 |   6.20 |
| ValidateUtf16leErr/korean        | 141.08 |   87.56 | 1.61 |     138.41 |   85.32 | 1.62 |   6.20 |
| ValidateUtf16leErr/hindi         | 141.61 |   88.05 | 1.61 |     139.40 |   86.79 | 1.61 |   6.19 |
| ValidateUtf16leErr/emoji         |  54.60 |   37.18 | 1.47 |      54.86 |   36.66 | 1.50 |   3.75 |
| ValidateUtf16leErr/hebrew        | 141.04 |   88.73 | 1.59 |     141.26 |   86.14 | 1.64 |   6.20 |
| ValidateUtf16leErr/arabic        | 143.44 |   88.83 | 1.61 |     143.33 |   88.12 | 1.63 |   6.20 |
| ValidateUtf16leErr/russian       | 143.05 |   89.17 | 1.60 |     142.39 |   88.78 | 1.60 |   6.19 |
| ValidateUtf16leErr/ascii-65536   | 143.95 |   88.89 | 1.62 |     142.98 |   87.24 | 1.64 |   6.21 |
| ValidateUtf16leErr/latin         | 144.23 |   89.32 | 1.61 |     142.39 |   85.85 | 1.66 |   6.20 |
| ValidateUtf16leErr/ascii-1048576 |  34.53 |   34.85 | 0.99 |      34.13 |   33.69 | 1.01 |   6.11 |
| ValidateUtf16be/ascii-16         |   3.19 |    4.95 | 0.64 |       5.84 |    4.90 | 1.19 |      - |
| ValidateUtf16be/ascii-64         |  12.77 |   16.53 | 0.77 |      21.59 |   16.32 | 1.32 |      - |
| ValidateUtf16be/ascii-256        |  36.03 |   33.02 | 1.09 |      37.20 |   33.09 | 1.12 |      - |
| ValidateUtf16be/ascii-4096       | 144.07 |   86.48 | 1.67 |     137.61 |   86.38 | 1.59 |      - |
| ValidateUtf16be/japanese         | 166.10 |   94.40 | 1.76 |     166.57 |   94.36 | 1.77 |      - |
| ValidateUtf16be/chinese          | 164.74 |   94.89 | 1.74 |     165.76 |   93.75 | 1.77 |      - |
| ValidateUtf16be/korean           | 140.10 |   88.73 | 1.58 |     139.71 |   87.89 | 1.59 |      - |
| ValidateUtf16be/hindi            | 142.43 |   89.28 | 1.60 |     140.16 |   89.13 | 1.57 |      - |
| ValidateUtf16be/emoji            |  43.52 |   34.21 | 1.27 |      43.64 |   34.10 | 1.28 |      - |
| ValidateUtf16be/hebrew           | 141.31 |   92.11 | 1.53 |     140.82 |   88.52 | 1.59 |      - |
| ValidateUtf16be/arabic           | 142.71 |   92.24 | 1.55 |     141.81 |   91.47 | 1.55 |      - |
| ValidateUtf16be/russian          | 142.58 |   92.62 | 1.54 |     138.93 |   91.91 | 1.51 |      - |
| ValidateUtf16be/ascii-65536      | 142.55 |   91.32 | 1.56 |     138.30 |   90.66 | 1.53 |      - |
| ValidateUtf16be/latin            | 143.94 |   91.88 | 1.57 |     143.36 |   91.13 | 1.57 |      - |
| ValidateUtf16be/ascii-1048576    |  33.42 |   33.24 | 1.01 |      34.20 |   33.45 | 1.02 |      - |
| ValidateUtf16beErr/ascii-16      |   3.09 |    4.50 | 0.69 |       4.15 |    4.48 | 0.93 |      - |
| ValidateUtf16beErr/ascii-64      |  10.99 |   14.41 | 0.76 |      13.82 |   14.39 | 0.96 |      - |
| ValidateUtf16beErr/ascii-256     |  34.82 |   35.71 | 0.98 |      36.56 |   35.45 | 1.03 |      - |
| ValidateUtf16beErr/ascii-4096    | 146.62 |   87.39 | 1.68 |     143.17 |   86.81 | 1.65 |      - |
| ValidateUtf16beErr/japanese      | 166.26 |   93.75 | 1.77 |     168.74 |   93.03 | 1.81 |      - |
| ValidateUtf16beErr/chinese       | 164.63 |   94.19 | 1.75 |     162.78 |   92.56 | 1.76 |      - |
| ValidateUtf16beErr/korean        | 139.71 |   89.35 | 1.56 |     140.14 |   88.71 | 1.58 |      - |
| ValidateUtf16beErr/hindi         | 141.00 |   89.99 | 1.57 |     139.54 |   88.66 | 1.57 |      - |
| ValidateUtf16beErr/emoji         |  43.71 |   34.17 | 1.28 |      43.57 |   34.18 | 1.27 |      - |
| ValidateUtf16beErr/hebrew        | 140.43 |   89.96 | 1.56 |     137.06 |   89.21 | 1.54 |      - |
| ValidateUtf16beErr/arabic        | 143.27 |   90.68 | 1.58 |     139.11 |   90.07 | 1.54 |      - |
| ValidateUtf16beErr/russian       | 143.02 |   90.79 | 1.58 |     141.03 |   90.29 | 1.56 |      - |
| ValidateUtf16beErr/ascii-65536   | 143.17 |   91.74 | 1.56 |     141.31 |   91.28 | 1.55 |      - |
| ValidateUtf16beErr/latin         | 144.21 |   92.13 | 1.57 |     143.07 |   91.39 | 1.57 |      - |
| ValidateUtf16beErr/ascii-1048576 |  32.81 |   33.60 | 0.98 |      34.25 |   32.15 | 1.07 |      - |
| ValidateUtf32/ascii-16           |   6.49 |    7.91 | 0.82 |      11.60 |    7.90 | 1.47 |      - |
| ValidateUtf32/ascii-64           |  23.66 |   23.67 | 1.00 |      32.69 |   23.87 | 1.37 |      - |
| ValidateUtf32/ascii-256          |  71.94 |   65.94 | 1.09 |      77.01 |   66.22 | 1.16 |      - |
| ValidateUtf32/ascii-4096         | 118.13 |   97.10 | 1.22 |     116.05 |   97.00 | 1.20 |      - |
| ValidateUtf32/emoji              | 118.50 |   97.49 | 1.22 |     118.32 |   97.73 | 1.21 |      - |
| ValidateUtf32/japanese           | 119.50 |   98.18 | 1.22 |     119.47 |   97.46 | 1.23 |      - |
| ValidateUtf32/chinese            | 118.31 |   97.96 | 1.21 |     119.20 |   97.86 | 1.22 |      - |
| ValidateUtf32/korean             | 119.21 |   98.52 | 1.21 |     120.12 |   98.22 | 1.22 |      - |
| ValidateUtf32/hindi              | 120.12 |   98.35 | 1.22 |     120.40 |   97.22 | 1.24 |      - |
| ValidateUtf32/hebrew             | 120.33 |   98.70 | 1.22 |     120.31 |   98.11 | 1.23 |      - |
| ValidateUtf32/arabic             | 118.63 |   98.75 | 1.20 |     121.03 |   98.36 | 1.23 |      - |
| ValidateUtf32/russian            | 119.50 |   98.88 | 1.21 |     121.14 |   98.23 | 1.23 |      - |
| ValidateUtf32/ascii-65536        | 120.78 |   98.89 | 1.22 |     120.27 |   96.55 | 1.25 |      - |
| ValidateUtf32/latin              | 120.45 |   98.99 | 1.22 |     120.02 |   97.98 | 1.23 |      - |
| ValidateUtf32/ascii-1048576      |  33.11 |   32.66 | 1.01 |      32.83 |   32.66 | 1.01 |      - |
| ValidateUtf32Err/ascii-16        |  12.40 |   10.99 | 1.13 |      14.95 |   11.00 | 1.36 |      - |
| ValidateUtf32Err/ascii-64        |  25.95 |   27.05 | 0.96 |      27.07 |   27.16 | 1.00 |      - |
| ValidateUtf32Err/ascii-256       |  89.38 |   66.42 | 1.35 |      93.28 |   66.16 | 1.41 |      - |
| ValidateUtf32Err/ascii-4096      | 119.55 |  111.40 | 1.07 |     120.12 |  111.40 | 1.08 |      - |
| ValidateUtf32Err/emoji           | 118.71 |  110.74 | 1.07 |     119.15 |  110.71 | 1.08 |      - |
| ValidateUtf32Err/japanese        | 118.71 |  111.58 | 1.06 |     119.77 |  111.51 | 1.07 |      - |
| ValidateUtf32Err/chinese         | 119.52 |  111.66 | 1.07 |     120.27 |  111.46 | 1.08 |      - |
| ValidateUtf32Err/korean          | 118.79 |  111.31 | 1.07 |     119.11 |  109.95 | 1.08 |      - |
| ValidateUtf32Err/hindi           | 120.01 |  111.43 | 1.08 |     120.88 |  110.85 | 1.09 |      - |
| ValidateUtf32Err/hebrew          | 120.72 |  112.04 | 1.08 |     120.92 |  112.13 | 1.08 |      - |
| ValidateUtf32Err/arabic          | 121.08 |  111.31 | 1.09 |     120.79 |  111.46 | 1.08 |      - |
| ValidateUtf32Err/russian         | 120.78 |  112.19 | 1.08 |     121.04 |  112.44 | 1.08 |      - |
| ValidateUtf32Err/ascii-65536     | 120.69 |  111.85 | 1.08 |     120.84 |  112.70 | 1.07 |      - |
| ValidateUtf32Err/latin           | 121.33 |  112.30 | 1.08 |     120.35 |  112.35 | 1.07 |      - |
| ValidateUtf32Err/ascii-1048576   |  32.94 |   33.87 | 0.97 |      32.72 |   32.74 | 1.00 |      - |

Geomean of utf ÷ simdutf per operation, as committed: ValidateAscii 1.33, ValidateAsciiErr 1.15, ValidateUtf8 1.36, ValidateUtf8Err 1.72, ValidateUtf16le 1.03, ValidateUtf16leErr 1.39, ValidateUtf16be 1.34, ValidateUtf16beErr 1.34, ValidateUtf32 1.15, ValidateUtf32Err 1.08; all 1.28; fixed: ValidateAscii 1.30, ValidateAsciiErr 1.12, ValidateUtf8 1.43, ValidateUtf8Err 1.76, ValidateUtf16le 1.12, ValidateUtf16leErr 1.48, ValidateUtf16be 1.45, ValidateUtf16beErr 1.39, ValidateUtf32 1.23, ValidateUtf32Err 1.10; all 1.34.

The as-committed short rows move with the harness: `ValidateUtf32/ascii-16` read 11.3 GB/s before the last UTF-32 change and 6.5 after, while the same change measured 1.47× at 64 bytes in the suite (A/B `exk`) and 11.6 GB/s in the fixed harness. The kernel did not lose; LLVM stopped inlining it into the row, so the row now pays the result copy.

## Harness: AVX2 against `haswell`

GB/s, median of 6.

| Row                              |    utf | haswell |    ÷ |
| -------------------------------- | -----: | ------: | ---: |
| ValidateAscii/ascii-16           |   4.75 |    1.27 | 3.75 |
| ValidateAscii/ascii-64           |  17.45 |    8.81 | 1.98 |
| ValidateAscii/ascii-256          |  45.43 |   27.03 | 1.68 |
| ValidateAscii/ascii-4096         | 139.69 |  113.47 | 1.23 |
| ValidateAscii/ascii-65536        | 102.79 |   96.92 | 1.06 |
| ValidateAscii/latin              | 103.19 |  102.47 | 1.01 |
| ValidateAscii/ascii-1048576      |  92.80 |   78.28 | 1.19 |
| ValidateAsciiErr/ascii-16        |   3.75 |    0.90 | 4.18 |
| ValidateAsciiErr/ascii-64        |  13.14 |    3.74 | 3.52 |
| ValidateAsciiErr/ascii-256       |  28.67 |   13.69 | 2.09 |
| ValidateAsciiErr/ascii-4096      | 139.22 |   78.65 | 1.77 |
| ValidateAsciiErr/ascii-65536     | 102.02 |   84.41 | 1.21 |
| ValidateAsciiErr/latin           | 103.46 |   96.00 | 1.08 |
| ValidateAsciiErr/ascii-1048576   |  82.48 |   83.25 | 0.99 |
| ValidateUtf8/ascii-16            |   1.63 |    1.18 | 1.39 |
| ValidateUtf8/ascii-64            |   6.55 |    7.09 | 0.92 |
| ValidateUtf8/ascii-256           |  24.58 |   23.00 | 1.07 |
| ValidateUtf8/ascii-4096          | 125.60 |   65.02 | 1.93 |
| ValidateUtf8/ascii-65536         | 100.56 |   50.82 | 1.98 |
| ValidateUtf8/emoji               |  15.36 |   12.26 | 1.25 |
| ValidateUtf8/hebrew              |  15.51 |   13.19 | 1.18 |
| ValidateUtf8/korean              |  15.10 |   13.36 | 1.13 |
| ValidateUtf8/japanese            |  15.15 |   13.00 | 1.17 |
| ValidateUtf8/chinese             |  15.38 |   13.37 | 1.15 |
| ValidateUtf8/arabic              |  15.40 |   13.48 | 1.14 |
| ValidateUtf8/latin               | 101.82 |   50.85 | 2.00 |
| ValidateUtf8/hindi               |  15.53 |   13.23 | 1.17 |
| ValidateUtf8/russian             |  15.51 |   13.66 | 1.14 |
| ValidateUtf8/ascii-1048576       |  83.37 |   49.81 | 1.67 |
| ValidateUtf8Err/ascii-16         |   1.16 |    0.60 | 1.94 |
| ValidateUtf8Err/ascii-64         |   4.45 |    2.51 | 1.77 |
| ValidateUtf8Err/ascii-256        |  16.52 |   10.23 | 1.62 |
| ValidateUtf8Err/ascii-4096       | 102.69 |   55.88 | 1.84 |
| ValidateUtf8Err/ascii-65536      | 100.88 |   64.36 | 1.57 |
| ValidateUtf8Err/emoji            |  15.32 |   12.30 | 1.25 |
| ValidateUtf8Err/hebrew           |  15.57 |   12.33 | 1.26 |
| ValidateUtf8Err/korean           |  15.51 |   12.17 | 1.27 |
| ValidateUtf8Err/japanese         |  15.14 |   12.17 | 1.24 |
| ValidateUtf8Err/chinese          |  15.31 |   12.23 | 1.25 |
| ValidateUtf8Err/arabic           |  15.53 |   12.47 | 1.25 |
| ValidateUtf8Err/latin            | 101.45 |   51.53 | 1.97 |
| ValidateUtf8Err/hindi            |  15.56 |   12.17 | 1.28 |
| ValidateUtf8Err/russian          |  15.55 |   12.63 | 1.23 |
| ValidateUtf8Err/ascii-1048576    |  84.52 |   55.97 | 1.51 |
| ValidateUtf16le/ascii-16         |   3.20 |    2.15 | 1.49 |
| ValidateUtf16le/ascii-64         |  13.22 |    2.90 | 4.56 |
| ValidateUtf16le/ascii-256        |  35.94 |    8.34 | 4.31 |
| ValidateUtf16le/ascii-4096       |  96.47 |   19.03 | 5.07 |
| ValidateUtf16le/japanese         | 108.42 |   20.72 | 5.23 |
| ValidateUtf16le/chinese          | 106.04 |   20.76 | 5.11 |
| ValidateUtf16le/korean           |  85.22 |   20.54 | 4.15 |
| ValidateUtf16le/hindi            |  85.36 |   20.84 | 4.10 |
| ValidateUtf16le/emoji            |  34.45 |   10.52 | 3.27 |
| ValidateUtf16le/hebrew           |  84.75 |   20.78 | 4.08 |
| ValidateUtf16le/arabic           |  85.73 |   20.85 | 4.11 |
| ValidateUtf16le/russian          |  85.22 |   20.89 | 4.08 |
| ValidateUtf16le/ascii-65536      |  85.62 |   20.84 | 4.11 |
| ValidateUtf16le/latin            |  85.03 |   20.92 | 4.06 |
| ValidateUtf16le/ascii-1048576    |  34.32 |   19.98 | 1.72 |
| ValidateUtf16leErr/ascii-16      |   3.02 |    2.12 | 1.42 |
| ValidateUtf16leErr/ascii-64      |  10.83 |    2.75 | 3.94 |
| ValidateUtf16leErr/ascii-256     |  34.87 |    8.69 | 4.01 |
| ValidateUtf16leErr/ascii-4096    |  97.19 |   19.05 | 5.10 |
| ValidateUtf16leErr/japanese      | 109.87 |   20.71 | 5.31 |
| ValidateUtf16leErr/chinese       | 107.02 |   20.74 | 5.16 |
| ValidateUtf16leErr/korean        |  84.99 |   20.77 | 4.09 |
| ValidateUtf16leErr/hindi         |  85.15 |   20.77 | 4.10 |
| ValidateUtf16leErr/emoji         |  34.39 |   10.70 | 3.21 |
| ValidateUtf16leErr/hebrew        |  84.54 |   20.65 | 4.09 |
| ValidateUtf16leErr/arabic        |  85.61 |   20.78 | 4.12 |
| ValidateUtf16leErr/russian       |  85.04 |   20.95 | 4.06 |
| ValidateUtf16leErr/ascii-65536   |  85.83 |   20.99 | 4.09 |
| ValidateUtf16leErr/latin         |  85.14 |   20.79 | 4.09 |
| ValidateUtf16leErr/ascii-1048576 |  34.23 |   19.79 | 1.73 |
| ValidateUtf16be/ascii-16         |   3.20 |    2.13 | 1.51 |
| ValidateUtf16be/ascii-64         |  13.23 |    2.91 | 4.54 |
| ValidateUtf16be/ascii-256        |  33.78 |    7.43 | 4.55 |
| ValidateUtf16be/ascii-4096       |  84.60 |   18.88 | 4.48 |
| ValidateUtf16be/japanese         |  92.21 |   20.45 | 4.51 |
| ValidateUtf16be/chinese          |  90.82 |   20.78 | 4.37 |
| ValidateUtf16be/korean           |  80.88 |   20.77 | 3.89 |
| ValidateUtf16be/hindi            |  81.42 |   20.62 | 3.95 |
| ValidateUtf16be/emoji            |  27.85 |   10.74 | 2.59 |
| ValidateUtf16be/hebrew           |  80.86 |   20.86 | 3.88 |
| ValidateUtf16be/arabic           |  81.79 |   20.94 | 3.91 |
| ValidateUtf16be/russian          |  81.42 |   20.94 | 3.89 |
| ValidateUtf16be/ascii-65536      |  81.56 |   20.86 | 3.91 |
| ValidateUtf16be/latin            |  81.10 |   20.95 | 3.87 |
| ValidateUtf16be/ascii-1048576    |  33.21 |   19.84 | 1.67 |
| ValidateUtf16beErr/ascii-16      |   2.94 |    2.11 | 1.39 |
| ValidateUtf16beErr/ascii-64      |  10.56 |    2.44 | 4.32 |
| ValidateUtf16beErr/ascii-256     |  31.15 |    8.07 | 3.86 |
| ValidateUtf16beErr/ascii-4096    |  81.32 |   18.80 | 4.32 |
| ValidateUtf16beErr/japanese      |  92.24 |   20.60 | 4.48 |
| ValidateUtf16beErr/chinese       |  92.12 |   20.69 | 4.45 |
| ValidateUtf16beErr/korean        |  80.93 |   20.60 | 3.93 |
| ValidateUtf16beErr/hindi         |  81.18 |   20.64 | 3.93 |
| ValidateUtf16beErr/emoji         |  27.84 |   10.67 | 2.61 |
| ValidateUtf16beErr/hebrew        |  80.68 |   20.78 | 3.88 |
| ValidateUtf16beErr/arabic        |  81.32 |   20.84 | 3.90 |
| ValidateUtf16beErr/russian       |  80.79 |   20.81 | 3.88 |
| ValidateUtf16beErr/ascii-65536   |  81.46 |   20.86 | 3.91 |
| ValidateUtf16beErr/latin         |  81.56 |   20.97 | 3.89 |
| ValidateUtf16beErr/ascii-1048576 |  34.09 |   19.93 | 1.71 |
| ValidateUtf32/ascii-16           |   6.60 |    5.14 | 1.28 |
| ValidateUtf32/ascii-64           |  24.16 |   16.89 | 1.43 |
| ValidateUtf32/ascii-256          |  40.69 |   33.49 | 1.21 |
| ValidateUtf32/ascii-4096         |  81.04 |   45.30 | 1.79 |
| ValidateUtf32/emoji              |  75.70 |   40.52 | 1.87 |
| ValidateUtf32/japanese           |  75.33 |   44.26 | 1.70 |
| ValidateUtf32/chinese            |  75.90 |   40.70 | 1.86 |
| ValidateUtf32/korean             |  76.40 |   44.31 | 1.72 |
| ValidateUtf32/hindi              |  76.58 |   40.78 | 1.88 |
| ValidateUtf32/hebrew             |  76.56 |   40.71 | 1.88 |
| ValidateUtf32/arabic             |  76.75 |   40.72 | 1.88 |
| ValidateUtf32/russian            |  76.74 |   40.67 | 1.89 |
| ValidateUtf32/ascii-65536        |  76.71 |   40.74 | 1.88 |
| ValidateUtf32/latin              |  76.80 |   40.73 | 1.89 |
| ValidateUtf32/ascii-1048576      |  33.01 |   31.84 | 1.04 |
| ValidateUtf32Err/ascii-16        |   6.77 |    4.91 | 1.38 |
| ValidateUtf32Err/ascii-64        |  18.41 |   12.81 | 1.44 |
| ValidateUtf32Err/ascii-256       |  43.70 |   17.08 | 2.56 |
| ValidateUtf32Err/ascii-4096      |  82.42 |   17.41 | 4.73 |
| ValidateUtf32Err/emoji           |  75.76 |   17.56 | 4.31 |
| ValidateUtf32Err/japanese        |  76.34 |   17.55 | 4.35 |
| ValidateUtf32Err/chinese         |  76.36 |   17.57 | 4.35 |
| ValidateUtf32Err/korean          |  75.80 |   17.58 | 4.31 |
| ValidateUtf32Err/hindi           |  76.62 |   17.54 | 4.37 |
| ValidateUtf32Err/hebrew          |  76.65 |   17.59 | 4.36 |
| ValidateUtf32Err/arabic          |  76.76 |   17.50 | 4.39 |
| ValidateUtf32Err/russian         |  76.99 |   17.54 | 4.39 |
| ValidateUtf32Err/ascii-65536     |  76.80 |   17.49 | 4.39 |
| ValidateUtf32Err/latin           |  77.06 |   17.56 | 4.39 |
| ValidateUtf32Err/ascii-1048576   |  33.83 |   17.27 | 1.96 |

Geomean per operation: ValidateAscii 1.53, ValidateAsciiErr 1.84, ValidateUtf8 1.31, ValidateUtf8Err 1.46, ValidateUtf16le 3.77, ValidateUtf16leErr 3.70, ValidateUtf16be 3.53, ValidateUtf16beErr 3.46, ValidateUtf32 1.65, ValidateUtf32Err 3.45; all 2.45.

## Scratch suite: final against wave 1 and simdutf

`head` (`7d7cb56`) against this branch (with `dispatch.call`'s `.auto` edit, so the `WithErrors` rows show the kernels) and simdutf's C++ driver on the same inputs, 4 rounds of every row, interleaved on CPU 3. Geomean per operation and size band; the last column is the slowest row against simdutf. The `head` binaries predate the UTF-8 rows on ASCII text, hence no ratio there. Taken before the last change to UTF-32 at one and two blocks (A/B `exk` below: those rows gain 7–23% more). Full tables in `ab/final-native/` and `ab/final-v3/`.

Native (AVX-512) against `icelake`:

```
op                           bucket        new GB/s  ÷head ÷simdutf  min÷simdutf
ValidateAscii                long(>=4K)      146.80   2.40     1.09   0.99 text=ascii/size=65536
ValidateAscii                mid(128-1K)      60.65   1.20     1.22   1.03 text=ascii/size=1024
ValidateAscii                short(<=64)       9.65   1.07     1.42   1.14 text=ascii/size=7
ValidateAsciiErr             long(>=4K)      154.37   2.50     1.06   0.89 text=ascii/size=4096
ValidateAsciiErr             mid(128-1K)      41.08   1.21     0.79   0.72 text=ascii/size=1024
ValidateAsciiErr             short(<=64)       6.37   1.47     0.91   0.53 text=ascii/size=64
ValidateAsciiWithErrors      long(>=4K)      154.18   2.43     1.06   0.89 text=ascii/size=4096
ValidateAsciiWithErrors      mid(128-1K)      58.38   1.22     1.00   0.78 text=ascii/size=1024
ValidateAsciiWithErrors      short(<=64)       8.28   1.07     1.09   1.02 text=ascii/size=32
ValidateUtf16be              long(>=4K)       94.97   2.28     1.48   1.12 text=latin/size=1048576
ValidateUtf16be              mid(128-1K)      40.54   1.43     1.44   1.20 text=latin/size=256
ValidateUtf16be              short(<=64)       7.25   1.68     1.24   0.89 text=emoji/size=32
ValidateUtf16beErr           long(>=4K)       93.53   2.52     1.46   1.07 text=emoji/size=4096
ValidateUtf16beErr           mid(128-1K)      26.39   3.11     1.04   0.88 text=emoji/size=128
ValidateUtf16beErr           short(<=64)       3.59   3.26     0.78   0.75 text=latin/size=23
ValidateUtf16beWithErrors    long(>=4K)       96.23   2.34     1.46   1.07 text=emoji/size=4096
ValidateUtf16beWithErrors    mid(128-1K)      39.60   1.54     1.17   0.96 text=emoji/size=128
ValidateUtf16beWithErrors    short(<=64)       6.61   1.76     1.07   0.82 text=emoji/size=64
ValidateUtf16le              long(>=4K)      110.35   2.61     1.29   1.00 text=latin/size=65536
ValidateUtf16le              mid(128-1K)      40.37   1.40     1.35   0.98 text=latin/size=256
ValidateUtf16le              short(<=64)       7.32   1.63     1.50   1.10 text=emoji/size=64
ValidateUtf16leErr           long(>=4K)       97.98   2.53     1.46   1.15 text=emoji/size=4096
ValidateUtf16leErr           mid(128-1K)      27.37   3.00     0.96   0.80 text=emoji/size=128
ValidateUtf16leErr           short(<=64)       3.60   2.83     0.76   0.66 text=chinese/size=7
ValidateUtf16leWithErrors    long(>=4K)      106.62   2.53     1.57   1.15 text=chinese/size=1048576
ValidateUtf16leWithErrors    mid(128-1K)      40.31   1.55     1.13   0.85 text=emoji/size=128
ValidateUtf16leWithErrors    short(<=64)       6.53   1.69     1.05   0.85 text=emoji/size=64
ValidateUtf32                long(>=4K)      114.23   2.05     1.24   1.13 text=latin/size=1048576
ValidateUtf32                mid(128-1K)      48.24   1.05     1.32   1.20 text=latin/size=1024
ValidateUtf32                short(<=64)       6.39   1.12     1.64   1.38 text=arabic/size=64
ValidateUtf32Err             long(>=4K)      113.68   2.17     1.08   0.93 text=arabic/size=4096
ValidateUtf32Err             mid(128-1K)      35.98   2.07     0.94   0.84 text=arabic/size=256
ValidateUtf32Err             short(<=64)       4.92   2.07     0.95   0.72 text=chinese/size=64
ValidateUtf32WithErrors      long(>=4K)      115.21   2.07     1.09   0.97 text=emoji/size=4096
ValidateUtf32WithErrors      mid(128-1K)      47.49   1.15     1.05   0.96 text=emoji/size=1024
ValidateUtf32WithErrors      short(<=64)       6.19   1.35     1.13   1.00 text=emoji/size=64
ValidateUtf8                 long(>=4K)       29.06    nan     1.35   1.18 text=emoji/size=1048576
ValidateUtf8                 mid(128-1K)      20.52    nan     1.18   0.97 text=chinese/size=128
ValidateUtf8                 short(<=64)       4.11    nan     0.88   0.81 text=chinese/size=45
ValidateUtf8Err              long(>=4K)       28.03    nan     1.93   1.18 text=latin/size=1048576
ValidateUtf8Err              mid(128-1K)      11.52    nan     5.30   1.62 text=latin/size=1024
ValidateUtf8Err              short(<=64)       0.98    nan     1.15   0.56 text=latin/size=45
ValidateUtf8WithErrors       long(>=4K)       29.28    nan     1.40   1.20 text=chinese/size=1048576
ValidateUtf8WithErrors       mid(128-1K)      19.64    nan     1.21   1.04 text=chinese/size=128
ValidateUtf8WithErrors       short(<=64)       3.74    nan     0.99   0.83 text=emoji/size=23
```

AVX2 (`x86_64_v3`) against `haswell`:

```
op                           bucket        new GB/s  ÷head ÷simdutf  min÷simdutf
ValidateAscii                long(>=4K)      113.12   1.43     1.20   1.05 text=ascii/size=65536
ValidateAscii                mid(128-1K)      64.55   1.04     1.57   1.21 text=ascii/size=1024
ValidateAscii                short(<=64)       9.86   1.03     3.56   2.27 text=ascii/size=64
ValidateAsciiErr             long(>=4K)      112.94   1.45     1.40   1.07 text=ascii/size=65536
ValidateAsciiErr             mid(128-1K)      40.37   1.06     2.30   1.94 text=ascii/size=256
ValidateAsciiErr             short(<=64)       4.72   1.07     2.77   2.39 text=ascii/size=7
ValidateAsciiWithErrors      long(>=4K)      107.61   1.34     1.18   0.98 text=ascii/size=1048576
ValidateAsciiWithErrors      mid(128-1K)      65.32   1.05     1.94   1.37 text=ascii/size=1024
ValidateAsciiWithErrors      short(<=64)       9.23   1.04     3.70   2.69 text=ascii/size=64
ValidateUtf16be              long(>=4K)       60.17   1.87     3.67   2.63 text=emoji/size=1048576
ValidateUtf16be              mid(128-1K)      33.36   1.36     6.10   2.64 text=emoji/size=1024
ValidateUtf16be              short(<=64)       4.90   1.21     2.45   0.98 text=emoji/size=7
ValidateUtf16beErr           long(>=4K)       59.22   1.98     3.62   2.64 text=emoji/size=65536
ValidateUtf16beErr           mid(128-1K)      18.52   2.26     3.38   2.49 text=emoji/size=1024
ValidateUtf16beErr           short(<=64)       2.14   1.93     1.04   0.44 text=emoji/size=7
ValidateUtf16beWithErrors    long(>=4K)       61.00   1.90     3.73   2.64 text=emoji/size=1048576
ValidateUtf16beWithErrors    mid(128-1K)      31.02   1.38     5.70   2.60 text=emoji/size=1024
ValidateUtf16beWithErrors    short(<=64)       4.48   1.28     2.30   0.89 text=emoji/size=7
ValidateUtf16le              long(>=4K)       69.64   2.15     4.19   3.14 text=emoji/size=1048576
ValidateUtf16le              mid(128-1K)      34.27   1.34     6.40   2.95 text=emoji/size=1024
ValidateUtf16le              short(<=64)       4.77   1.08     2.37   1.24 text=arabic/size=7
ValidateUtf16leErr           long(>=4K)       68.49   2.23     4.13   3.17 text=emoji/size=1048576
ValidateUtf16leErr           mid(128-1K)      19.87   2.21     3.99   2.75 text=emoji/size=1024
ValidateUtf16leErr           short(<=64)       2.25   1.76     1.23   0.48 text=arabic/size=7
ValidateUtf16leWithErrors    long(>=4K)       69.40   2.14     4.19   3.17 text=emoji/size=1048576
ValidateUtf16leWithErrors    mid(128-1K)      33.68   1.42     6.64   2.96 text=emoji/size=1024
ValidateUtf16leWithErrors    short(<=64)       4.60   1.23     2.38   1.15 text=emoji/size=7
ValidateUtf32                long(>=4K)       74.67   2.45     1.80   1.67 text=latin/size=4096
ValidateUtf32                mid(128-1K)      37.40   1.33     1.96   1.37 text=emoji/size=1024
ValidateUtf32                short(<=64)       4.55   0.96     1.61   1.11 text=emoji/size=7
ValidateUtf32Err             long(>=4K)       72.73   2.48     4.17   3.87 text=arabic/size=4096
ValidateUtf32Err             mid(128-1K)      23.22   1.62     1.71   1.19 text=chinese/size=256
ValidateUtf32Err             short(<=64)       2.75   1.20     0.90   0.56 text=chinese/size=7
ValidateUtf32WithErrors      long(>=4K)       74.60   2.45     4.27   4.15 text=latin/size=4096
ValidateUtf32WithErrors      mid(128-1K)      36.34   1.29     2.73   2.43 text=latin/size=128
ValidateUtf32WithErrors      short(<=64)       4.01   0.96     1.46   0.92 text=latin/size=7
ValidateUtf8                 long(>=4K)       22.70    nan     1.29   1.14 text=arabic/size=4096
ValidateUtf8                 mid(128-1K)      15.72    nan     1.23   1.11 text=emoji/size=128
ValidateUtf8                 short(<=64)       3.49    nan     2.05   1.17 text=arabic/size=64
ValidateUtf8Err              long(>=4K)       21.97    nan     1.44   1.26 text=emoji/size=1048576
ValidateUtf8Err              mid(128-1K)      10.57    nan     2.42   1.09 text=emoji/size=1024
ValidateUtf8Err              short(<=64)       0.95    nan     1.37   0.86 text=latin/size=45
ValidateUtf8WithErrors       long(>=4K)       22.87    nan     1.41   1.23 text=latin/size=4096
ValidateUtf8WithErrors       mid(128-1K)      15.69    nan     1.29   1.16 text=emoji/size=128
ValidateUtf8WithErrors       short(<=64)       3.44    nan     2.13   1.26 text=emoji/size=64
```

The rows still under simdutf in the suite: UTF-8 on non-ASCII text at 7–64 bytes (0.82–0.88 of `icelake`, from 0.61–0.74 in wave 1); inputs that end in an error at 7–256 bytes for ASCII (0.53 at 64), UTF-16 (0.75–0.91), and UTF-32 (0.72–0.85), where the error path runs after a block fails; and ASCII with an error at 1 KiB (0.72). From 1 KiB everything else is level or ahead.

## Choices, and the A/B behind each

Each A/B's raw output and benchstat are in `ab/<name>/`; `ab1`–`ab7` are this pass's earlier A/Bs, in the order run (alignment and the ASCII prefix, masked loads and error masks for ASCII and UTF-16, the UTF-32 forms, the groups, the UTF-8 realignment). Medians from `cmp.py`, native unless named.

- **Aligned blocks for long inputs** The ASCII loop on input 16 bytes past a 64-byte boundary ran at 92 GB/s at 4 KiB and 52 at 64 KiB; from the boundary, 192 and 146. Every long loop now checks its first block unaligned and continues from the next boundary: ASCII past four blocks, UTF-16 and UTF-32 from eight, UTF-8 from 4 KiB when its first block is not ASCII (+11–12% from 64 KiB; it cost 5–7% at 1 KiB, hence the threshold). The block at the boundary takes its context from the bytes before it, or carries the first block's state when the boundary is exactly one block in.
- **One test per group of blocks** (`ex2`–`ex4` for eight). ASCII and UTF-32 test four blocks at once (OR, and the maximum of a key), UTF-16 eight and then four (the minimum of a key). Groups of four took UTF-16 and UTF-32 +14–38% at 256 bytes; a group with a surrogate checks its blocks' masks directly (emoji at 64 KiB 27 to 51 GB/s). Eight blocks per test added 5–19% to UTF-16 from 4 KiB over four (`ex3`, `ex4`).
- **The UTF-16 group key** (`ex`, `ex2`). In native order `v -% 0xD800 < 0x800` replaces `(v & 0xF800) ^ 0xD800 == 0`: LLVM made the AND and XOR one ternary op that overwrites a copy of a constant, a move per block; the subtraction takes its block from memory. +4–9% from 4 KiB.
- **Short UTF-16 and UTF-32**. At one and two blocks the loops' setup dominated: UTF-16 now tests both overlapping blocks for a surrogate at once (`exh`: 64–128 bytes 1.35–2.0×, emoji at 64 bytes 0.93×, 1 KiB 0.92–0.96× from code layout); UTF-32 tests one block once, or two at once (`exk`: 1.07–1.23× wave 1 at 64–256 bytes, where the first try, loading the one block twice, lost 23%, `exij`). Four overlapping blocks for UTF-16 (`exg`) gained 35% more at 256 bytes but cost emoji and the error rows 10–20%.
- **Masked loads under one block on AVX-512**: `llvm.masked.load` of the input into a zeroed block, 1.2–1.9× `simd.loadPartial` on UTF-8, UTF-16, and UTF-32 at 7–45 bytes; slower than the overlapping loads for ASCII, which keeps them, now up to 64 bytes (`ex`: +15% at 64). LLVM backend only; the self-hosted x86 backend and other ISAs keep `loadPartial`.
- **Error positions from lane masks**: ASCII, UTF-16, and UTF-32 find the first error in the failing block from its masks instead of rerunning the scalar validator from there: `Err` rows 2–6×. UTF-16's first error is the first lone low surrogate or unfollowed high one, with a high one pending from the block before.
- **Indices, not optionals, from the block scans** (`sent`). The `BadBlock` functions returned `?usize` from inline functions, which went through memory: a byte stored to the stack or picked from a constant and loaded back. A plain index with `maxInt(usize)` for none: ASCII at 16–32 bytes +13%, UTF-16 at 128 bytes +20%, UTF-16 `WithErrors` at 7–32 bytes +7–13%, UTF-32 at 64–256 bytes up to +17%.
- **ASCII prefix of UTF-8 per block**: one OR over the whole of an input up to 256 bytes is right for ASCII validation but cost UTF-8 on non-ASCII text 26% at 128 bytes, so UTF-8 tests its blocks in turn and stops at the first that is not ASCII.
- **UTF-32, one block**: two compares (`> 0x10FFFF`, surrogate range) beat the one-key form (XOR, subtract, compare) by 7–25% on a single block; the groups use the key, where one maximum covers four blocks.
- **Decision 2, 32 against 64 bytes per block on AVX2** (`d2`, `x86_64_v3`): 64 wins by 14% on UTF-8 at 4 KiB and 4–5% at 64 KiB, 12–49% on UTF-16, 16% on ASCII at 4 KiB; 32 wins only below one block (22–43% at 16 bytes), and on UTF-32 inputs that end in an error at short sizes. Kept 64.
- **Rejected**: an inline ASCII prefix with the rest of UTF-8 out of line (slower), the long UTF-16 path out of line (`ex4`, `exf`: `WithErrors` lost 15–20% under 1 KiB), masked loads for ASCII.

## Correctness

- Differential tests through the public functions, once per tier the CPU has (`dispatch.forEachLevel`): every error kind at every position, inputs at every offset from a 64-byte boundary and long enough to reach every aligned loop and group, a high byte at every position of every length up to 136 bytes, mutated random text, and a UTF-8 sequence cut short before ASCII at every offset of the realigned loop. Pass in Debug on native, in ReleaseSafe on native, `x86_64_v3`, `x86_64_v2`, and baseline, and under qemu in Debug and ReleaseSafe on aarch64 and ReleaseSafe on aarch64_be. On aarch64_be two tests of `convert.zig` and `length.zig` fail, as they do on `origin/main` (`fcdef96`) without this change.
- Seven mutations of this pass's new code (the UTF-16 key and its bound, the UTF-32 two-block path, the short ASCII bound, the group's pending surrogate) each fail the tests.
- `just oracle`: 1,638,976 UTF-8 and 250,000 UTF-16LE inputs, under `icelake` and again under `fallback`: 0 mismatches for `validate.utf8`, `validate.utf8WithErrors`, and `validate.utf16leWithErrors`. The oracle has no UTF-16BE, UTF-32, or ASCII checks yet.

## Files

- `suite/`: the scratch suite (`build.zig`, `bench.zig`, `inputs.zig`, `dump.zig`, `simdutf.cpp`, `ab.sh`, `cmp.py`).
- `ab/<name>/`: each A/B's raw testingx output and benchstat; `ab/final-*/summary.txt` is the table above.
- `harness/<run>/`: `just bench-compare` output (raw per arm, benchstat, summary, config, RSS) for `fin-native`, `fin-hp` (harness fixed), and `fin-avx2`, and the UTF-16 and UTF-32 reruns `u16-*` and `u32-*`. `harness/fixed.diff` is the two local edits.
