# Harness wave 3: `Out` from scalars, 2026-10-31

**`Out` from scalars.** `bench/zig/arm.zig`'s `written()` turned a checked call's `Result` into the `Out` union by choosing one of two variants, `.len` or `.valid = false`. LLVM wrote the chosen one's fields with narrow stores and copied it out with one wide load, which cannot forward from them, the stall `38ac25a` removed from `convert.zig`'s `tail` and `0c14f7b` from the timing loop's read-back. The convert orb modelled it at 9.0 ns against 4.9 for `latin1ToUtf16le` on 16 bytes ([harness-written-ab.zig](convert-20261031/harness-written-ab.zig)). `Out` is now a struct of two computed fields, `n` and `kind` (`Out.checked(kind, ok, n)`), in both Zig arms, std's error unions included, and the timing loop keeps `n` alone.

- Machine: Amp orb, KVM guest, Intel Xeon @ 2.60GHz (Ice Lake server, model 106, AVX-512 with VBMI2), 4 vCPUs, pinned to CPU 3. Package at `6f0a81a`. simdutf 9.2.1, Zig 0.16.0 ReleaseFast.
- Method: `bench-utf` built from `6f0a81a` (old) and with this change (new), native and `x86_64_v3` with `dispatch=false`. [ab.sh](harness-wave3-20261031/ab.sh) ran old and new of each build back to back, alternating which went first and rotating the builds, 6 rounds of the 25 checked conversions and validators with errors, the 5 base64 decodes, and three controls that return no `Result` (`validate-utf8`, `valid-latin1-to-utf16le`, `valid-utf8-to-utf16le`) at `BENCHTIME_MS=100`. [rows.py](harness-wave3-20261031/rows.py) gives each row's median ns per call, from the GB/s, into [rows-native.txt](harness-wave3-20261031/rows-native.txt) and [rows-v3.txt](harness-wave3-20261031/rows-v3.txt); [summary.txt](harness-wave3-20261031/summary.txt) groups them; [benchstat-native.txt](harness-wave3-20261031/benchstat-native.txt) and [benchstat-v3.txt](harness-wave3-20261031/benchstat-v3.txt) are benchstat over the raw GB/s in `old-*.txt` and `new-*.txt`.
- Equivalence: `check` prints the same bytes old and new: `bench-utf` native and `x86_64_v3`, 877 rows each, and `bench-std`, 208. On inputs with errors ([errcheck.sh](harness-wave3-20261031/errcheck.sh): every checked conversion on its form's `-err` directory, every base64 decode on text it rejects) the same: 885 rows with 331 `valid=false` for `bench-utf`, 208 with 69 for `bench-std`. `just bench-compare` matches simdutf's checksums on every row.

## What moved

Median ns per call, new against old; "16–64" is the `-16` and `-64` inputs of each directory.

| Rows                                    | native: Δ ns (median, range) | new ÷ old | `x86_64_v3`: Δ ns (median, range) | new ÷ old |
| --------------------------------------- | ---------------------------- | --------: | --------------------------------- | --------: |
| checked conversions, 16–64 (56 rows)    | −2.4 (−7.7 to −0.5)          |      0.81 | −2.5 (−3.9 to +3.7)               |      0.78 |
| checked conversions, 256                | −1.1 (−7.9 to +0.9)          |      0.91 | −1.2 (−4.8 to −0.1)               |      0.92 |
| checked conversions, 4 KiB up and texts | within noise                 |      1.00 | within noise                      |      1.00 |
| base64 decodes, 16–64 (10 rows)         | −6.6 (−8.0 to −5.3)          |      0.76 | −4.9 (−6.9 to −3.7)               |      0.82 |
| base64 decodes, 256                     | −7.2                         |      0.84 | −5.4                              |      0.88 |
| validators with errors, 16–64 (10 rows) | −0.2 (−0.5 to +0.8)          |      0.98 | −0.5 (−1.0 to +0.4)               |      0.95 |
| controls, 16–64 (8 rows)                | −0.2 (−2.9 to −0.2)          |      0.93 | −0.4 (−1.2 to −0.3)               |      0.93 |

- **Checked conversions: 2–3.5 ns a call faster at 16–64 bytes.** `latin1ToUtf16le` on 16 bytes: 10.79 to 8.77 ns native, 10.32 to 7.27 AVX2, against its valid form's 7.71 and 6.37: the checked form now costs about 1 ns over the valid one, where it cost 3–4. `utf8ToUtf16le` on 16 bytes: 15.62 to 13.85 native, 11.00 to 8.50 AVX2. benchstat calls 42 of the 56 native rows and 48 of the AVX2 ones faster; the rest are within this guest's spread (up to ±30% for a few rounds). The model's 4 ns was a tight loop; the harness's loop costs more per call here (the valid form is 7.7 ns, the model's 3.3), and the stall overlaps some of it.
- **Base64 decoding: 4–8 ns faster up to 256 bytes**, which the model did not cover: `decode` returns a `Result` and took the same path.
- **Validators with errors did not move** (±1 ns): they already built one variant, `.valid = r.err == .none`.
- **Controls.** `validate-utf8` and `valid-latin1-to-utf16le` moved 0.1–0.4 ns. `valid-utf8-to-utf16le` moved −2.4 to −2.9 ns native (AVX2 −0.4 to −0.7), though its `Out` was one variant before too; unexplained, likely code placement in the new binary.
- **One row slower: AVX2 `utf16beToLatin1` on 16 code units, 16.4 to 20.0 ns** (both inputs; `utf16leToLatin1` did not move, and 64 code units of either got 2–3.5 ns faster). Both 16-unit rows are slow in old and new alike, 15.7–20 ns where 64 units take 7.3–10.8, so the cost is in the AVX2 UTF-16 to Latin-1 kernel at 16 code units, not in the harness. That is `src/convert.zig`'s; the plan's "16-byte UTF-16-to-Latin-1 (0.44–0.50 of `haswell`)" gap is this row.

simdutf's arm did not change, so each `utf ÷ simdutf` ratio of these rows rises by old ÷ new: about 1.2× for the checked 16–64-byte rows and 1.3× for the short base64 decodes, and nothing from 4 KiB.
