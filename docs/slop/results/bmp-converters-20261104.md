# BMP converters from encoding, and utf#1, 2026-11-04

baskingspot/encoding's single-byte codecs stage text as UTF-16 that holds only BMP code points, and its wave 5 gave it converters of its own for that (`bmpToUtf8`, `utf8ToBmp` in encoding's `src/codec.zig` at `c45639d`). They move here as `convert.bmpToUtf8` and `convert.utf8ToBmp`, under utf's dispatch, so a binary has one dispatcher. This records their size and speed against encoding's copies, two changes made while measuring them, and baskingspot/utf#1.

## Takeaways

- **Same speed as encoding's copies, or faster.** UTF-16 to UTF-8 is encoding's code, plus one path: geomean 1.00× encoding's copy native and at baseline, 1.07× with AVX2, 1.04× with SSSE3. On Thai, 1.26× with AVX2 and 1.17× with SSSE3. UTF-8 to UTF-16 has a complete contract and a zero-padded last window built in registers: 1.63× native, 1.41× AVX2, 1.15× SSSE3, 1.05× baseline. Most of the gain is at 16–64 bytes, where encoding's copy left the input to its caller one character at a time; at 64 KiB it is 1.05×, 1.16×, 0.97×, and 1.01×.
- **Dispatch on baseline gives a generic x86-64 build the AVX-512 kernels for 70.9 KB.** That build runs at 0.92× native from UTF-16 (0.86× at 16 units) and 0.95× from UTF-8, where without dispatch it gets the store-a-character path (UTF-16 to UTF-8 on Latin text 3.9 GB/s against 27.0). Of the 70.9 KB, 26.4 KB is the AVX-512 tier object's single `.rodata` section, which the linker keeps whole, and 25.6 KB is the shuffle tables, once in the SSE tier and once in the AVX2 one. The kernels are about 10.6 KB of code and `dispatch.init` 2.6 KB.
- **Without dispatch, the sizes match encoding's code.** UTF-16 to UTF-8 is within 1 byte of encoding's natively and at baseline, and 196–215 bytes over with AVX2, SSSE3, and NEON, for the three-byte path. UTF-8 to UTF-16 is 55 bytes under natively and 1.0–1.6 KB over elsewhere, for the complete contract and the last window.
- **Thai, against the general converters.** UTF-16 to UTF-8 on Thai was 0.77× `validUtf16leToUtf8` with AVX2 and 0.74× with SSSE3, called in the same stages. With a fixed shuffle for 16 three-byte characters (`blockToUtf8`) it is 0.95× and 0.86× in the final run; across all texts it is 0.98× and 0.95×. UTF-8 to UTF-16 on Thai is 0.73× and 0.67× `utf8ToUtf16le`. That converter is called on the whole input, not in stages of 256 units, and has a 16-character three-byte path that the BMP decoder lacks. That gap is left open.
- **utf#1 does not reproduce at its size, but its cause is real and found.** The issue's command on this machine gives native 9.5 ns, v3 9.2 ns, and baseline 8.8 ns as the median 16-byte UTF-8-to-UTF-16 call, against the issue's 20.6, 21.1, and 13.6 ns. Native is slower than baseline only on the ASCII rows, by 7–8% (0.7 ns), and faster on non-ASCII (−6–9%) and invalid input (−31%). The cause: with the tier fixed at compile time, the AVX-512 kernel is inlined into encoding's caller whole, long path and all, so the caller saves six registers on every call. The dispatched build's tier object puts the long path out of line (`longPath`). Out of line in native builds too, encoding's ASCII 16-byte rows are 19% faster than inline and 12% faster than baseline. Its non-ASCII 16–64-byte rows are 6% slower and its invalid rows 21–32% slower, and utf's own harness loses 6–18% at 16 and 256 bytes. The change is a trade, not a fix, so it is not made. The same trade is why native builds keep kernels whole ([short-20261101.md](short-20261101.md)).

## Setup

- Machine: Amp orb, KVM guest, Intel Xeon @ 2.60GHz (Ice Lake server, family 6 model 106, AVX-512 with VBMI2), 4 vCPUs, TSC at 2.6 GHz. Every timed process was pinned to CPU 3 with `taskset`, and nothing was built while anything was timed.
- Zig 0.16.0, ReleaseFast for speed, ReleaseSmall for size. Encoding's copies are its `src/codec.zig` at `c45639d`, renamed into one file (`bmpb/enc_codec.zig`).
- Harness: [bmpb/](bmp-converters-20261104/bmpb/), built from `/tmp/bmpb` against this checkout by path. `bmpb serve utf|enc|gen` answers `OP FILE N` with N calls timed in TSC ticks, in the Go benchmark format. MB/s is input bytes: UTF-16 for `to8`, UTF-8 for `from8`. Each arm converts the whole file in stages of 256 units, as encoding's single-byte codecs do. `enc` gets a char-at-a-time step for what its `utf8ToBmp` leaves, inline as encoding's `codec.read` decodes, and `utf`'s step is the same. `gen` is `validUtf16leToUtf8` in the same stages for `to8`, and `utf8ToUtf16le` on the whole input for `from8`. Inputs are encoding's corpus, the `.utf8` decodes of `bench/corpus-gen/<encoding>/<shape>-<size>.bin`: windows-1252 web and nonascii, windows-1251 mixed and nonascii, windows-874 (Thai) mixed and nonascii, and x-user-defined nonascii, at 16 to 65,536 bytes of the source encoding ([rows-bmp.txt](bmp-converters-20261104/rows-bmp.txt)).
- Rounds: [serve-ab.py](bmp-converters-20261104/serve-ab.py), `just bench-compare`'s method. Every arm is a server on CPU 3, and each row is timed on every arm back to back, in an order that rotates by row and round. Each round starts fresh processes; round 0 sizes the loops and is discarded. Then 10 rounds. `summary.py DIR NUM/DEN` gives each row's median per-round ratio and their geomean by operation, text, and size; above 1, NUM is faster.
- Arms: `nat` is `-Dcpu=native`. `v3`, `v2`, and `bnd` are `-Dcpu=x86_64_v3`, `x86_64_v2`, and `baseline` with `-Dutf-dispatch=false`. `bd` is `-Dcpu=baseline` with dispatch, which picks the AVX-512 tier here.
- Sizes: `bmpb/sizes.sh` builds `size-*` programs that read stdin, convert it with one set of converters, and write it, ReleaseSmall and stripped. It reports `.rodata` plus `.text` net of `size-none`, which only copies.

## API

```zig
pub const BmpResult = struct { read: usize, written: usize };
pub fn bmpToUtf8(src: []const u16, dst: []u8) BmpResult // in convert
pub fn utf8ToBmp(src: []const u8, dst: []u16) BmpResult // in convert
```

Both use UTF-16 in the machine's byte order. `bmpToUtf8` trusts that `src` holds no surrogate, as encoding's does. It writes as many whole characters as fit, all of them when `dst` has three bytes a unit, and turns a surrogate into the three bytes it would take as a code point. `utf8ToBmp` converts while each character is ASCII or a well-formed two- or three-byte sequence. It stops at the first four-byte sequence, at the first ill-formed one (a truncated one included), or where `dst` is full. `read` always ends on a character boundary, where the caller decodes what stopped it its own way. Encoding's copy could also stop short of the input's end, wherever its last window began (any of the last `window + 2` bytes), and leave the rest to its caller. utf's goes to the end. Encoding's call sites (`single_byte.zig`, `x_user_defined.zig`) keep their char-at-a-time fallback for what stops it, and go on from `read` as they do now.

Kernels (`src/bmp.zig`): `pack` is `compress` with AVX-512 VBMI2 (`vpcompressb`, `vpcompressw`), `shuffle` with SSSE3, AVX2, AVX-512 without VBMI2, and NEON (256-entry tables: `pack_narrow` and `pack_quads`, 8,448 bytes, for `bmpToUtf8`, and `pack_units`, 4,096, for `utf8ToBmp`), and `store` elsewhere. Each tier object gets its own through `dispatch.call`.

## Sizes ([sizes.txt](bmp-converters-20261104/sizes.txt))

Bytes of `.rodata` plus `.text`, ReleaseSmall, stripped, net of the copy program; `nd` is `-Dutf-dispatch=false`.

| build                  | utf, both | encoding, both | utf, to UTF-8 | encoding | utf, from UTF-8 | encoding |
| ---------------------- | --------: | -------------: | ------------: | -------: | --------------: | -------: |
| native (AVX-512 VBMI2) |     3,272 |          3,396 |           721 |      720 |           2,602 |    2,657 |
| x86-64-v3, nd          |    16,160 |         14,855 |        10,195 |    9,980 |           6,027 |    4,934 |
| x86-64-v2, nd          |    17,958 |         16,161 |        10,810 |   10,595 |           7,210 |    5,564 |
| baseline, nd           |     7,346 |          6,289 |         3,500 |    3,499 |           3,832 |    2,726 |
| aarch64 (NEON)         |    16,624 |         15,400 |        10,120 |    9,924 |           6,560 |    5,520 |
| x86-64-v3, dispatch    |    52,158 |                |        44,056 |          |          41,146 |          |
| x86-64-v2, dispatch    |    71,001 |                |        55,708 |          |          49,195 |          |
| baseline, dispatch     |    78,197 |                |        59,266 |          |          53,018 |          |

Dispatch on baseline costs 70,851 bytes over the same build without it. Matching the tier objects' sections against the linked program (`.rodata` 58,030 bytes unstripped):

- 26,434: the AVX-512 object's `.rodata`, one section of constant pools for every AVX-512 kernel in utf, kept whole once a kernel uses any of it. Every dispatching program that calls an AVX-512 kernel carries it today; it is not the BMP kernels' own.
- 12,800 and 13,314: the SSE and AVX2 objects' shuffle tables, `pack_narrow`, `pack_quads`, and `pack_units`, the same bytes twice.
- About 10.6 KB of tier kernels (AVX-512 0.7 + 1.9 KB, AVX2 1.4 + 1.8, SSE 1.9 + 2.9), `dispatch.init` 2.6 KB, and the two slots.

## Speed ([run/](bmp-converters-20261104/run/))

Geomeans of each row's median per-round ratio over 10 rounds; above 1, utf is faster. Raw files, `benchstat.txt`, `summary.txt`, and `rows-median.txt` (each row's median ns, and GB/s at 64 KiB) are in `run/`.

utf against encoding's copy at the same level:

| level        | to UTF-8 | Thai | 16 B | 64 KiB | from UTF-8 | Thai | 16 B | 64 KiB |
| ------------ | -------: | ---: | ---: | -----: | ---------: | ---: | ---: | -----: |
| native       |    1.003 | 1.00 | 1.01 |   1.00 |      1.629 | 1.73 | 2.75 |   1.05 |
| x86-64-v3    |    1.068 | 1.26 | 1.05 |   1.08 |      1.412 | 1.30 | 1.93 |   1.16 |
| x86-64-v2    |    1.042 | 1.17 | 1.03 |   1.06 |      1.148 | 1.06 | 1.59 |   0.97 |
| baseline, nd |    1.004 | 1.00 | 1.00 |   1.00 |      1.048 | 0.99 | 1.07 |   1.01 |

Thai is windows-874/nonascii, all sizes. Rows below 0.9, all from UTF-8: with SSSE3, windows-1251 at 256 bytes (0.80 and 0.87) and windows-1252/web at 4 KiB and 64 KiB (0.88); at baseline, Thai and x-user-defined at 16 bytes (0.77 and 0.76, 39.5 ns against 30.6), where utf decodes a 32-byte window with SSE2 for the last 16 bytes and encoding's caller reads five characters; native, windows-1251/mixed-256 (0.87, 65 ns against 58).

Baseline with dispatch against native: 0.915 to UTF-8 (0.86 at 16 units, 0.88 at 64, 0.93–0.97 above) and 0.950 from UTF-8 (0.91 at 16 bytes, 0.95–0.98 above). That is the dispatch slot's call, where native inlines the kernel. At 64 KiB of Latin text it does 27.0 GB/s to UTF-8 against native's 28.6, and baseline without dispatch does 3.9.

utf against its general converters (`gen`), Thai and all texts:

| level     | to UTF-8, Thai |  all | from UTF-8, Thai |  all |
| --------- | -------------: | ---: | ---------------: | ---: |
| native    |           1.14 | 1.24 |             0.95 | 0.78 |
| x86-64-v3 |           0.95 | 0.98 |             0.73 | 0.76 |
| x86-64-v2 |           0.86 | 0.95 |             0.67 | 0.67 |

From UTF-8, `gen` converts the whole input in one call and the BMP arms in stages of 256 units, so the comparison favors `gen`. It also decodes runs of three-byte characters 16 at a time with a fixed shuffle (`utf8ToUnits`), where `decodeWindow` decodes every lane and packs with a table.

## Two changes made while measuring

**A fixed shuffle for 16 three-byte characters in `blockToUtf8`** ([three-path/](bmp-converters-20261104/three-path/), 5 rounds, the 35 UTF-16-to-UTF-8 rows, against the same tree without it). When all 16 code points are U+0800 or above, the four groups take the same shuffle, a constant, instead of four table loads and four length lookups. Thai is 1.27× with AVX2 and 1.16× with SSSE3, from 0.77× and 0.74× `validUtf16leToUtf8` to 0.97× and 0.86×; other text is level with AVX2 and 0.96–0.99 with SSSE3, where the path is not taken. It costs 215 bytes with AVX2 and SSSE3 and 196 with NEON. It is the general converter's `utf8From16Three`, without the surrogate test.

**The last window of `utf8ToBmp` built in registers where there are no masked loads** ([short-tail/](bmp-converters-20261104/short-tail/), 7 rounds, the 35 UTF-8-to-UTF-16 rows). The window used to be copied into a zero-padded buffer, and its three loads waited for the copy's stores. Now it is one `simd.loadPartial` of the rest of the input, at most 33 bytes, and the window and its next two bytes are moved out of that register with shuffles (`lanesFrom`). With AVX2, 16-byte inputs are 1.78× faster and 64-byte 1.27×; with SSSE3, 1.18× and 1.09×; at baseline, 1.20× and 1.06×. From 4 KiB it is level (0.99–1.01). It costs 300–440 bytes. Reading the rest one character at a time was also tried and dropped: 16-byte inputs gained up to 1.47× on some rows and lost up to 0.76× on others, 64-byte inputs lost 13–16%, and the baseline loop lost 14% at 4 KiB.

## utf#1

[The issue](https://github.com/baskingspot/utf/issues/1) reports median 16-byte UTF-8-to-UTF-16 calls of 20.6 ns for encoding built for the host (AVX-512), 21.1 ns for x86-64-v3, and 13.6 ns for baseline. It also reports UTF-8 to UTF-8 at 18.7 and 17.5 ns, and the builds level at 64 KiB.

**Repro** ([utf1/repro/](bmp-converters-20261104/utf1/repro/)): the issue's command in encoding at `c45639d` with utf v0.1.0, `just arms="rust zig zigv3 zigbase" bench-compare 10 '^Decode(Utf8|Utf16)/UTF-8/.*-16$'`, on this machine while idle. Medians of the rows' medians:

| encoding built for | to UTF-16, 16 B | to UTF-8, 16 B |
| ------------------ | --------------: | -------------: |
| host (AVX-512)     |          9.5 ns |         9.9 ns |
| x86-64-v3          |          9.2 ns |        10.4 ns |
| baseline           |          8.8 ns |        10.5 ns |
| encoding_rs        |         11.4 ns |        10.0 ns |

Per row, the host build is slower than baseline only on the ASCII rows to UTF-16 (ascii, csv, mail, subtitles, web: 1.68–1.70 GB/s against 1.82–1.83, 7–8%). It is faster on nonascii (+9%), mixed (+7%), and invalid (+45%) rows, and on every row to UTF-8. Encoding's README run that the issue quotes had absolute times 2–3× these, encoding_rs's included, which points to a loaded machine, though that is not verified. The pattern was the same at encoding `093e12b` ([utf1/repro-093e12b/](bmp-converters-20261104/utf1/repro-093e12b/), 5 rounds: host 9.9–10.1 ns on the ASCII rows against baseline's 8.8–9.2) and with an integer busy loop on CPU 2, CPU 3's sibling ([utf1/repro-busy-sibling/](bmp-converters-20261104/utf1/repro-busy-sibling/)); there v3 sits between the two.

**Cause.** utf's AVX-512 `utf8ToUnits` takes up to 64 ASCII bytes before its long path. In a tier object (`dispatch.exported`), `longPath` calls the long path out of line, so a short ASCII call saves no registers. In a build whose tier is fixed at compile time, the kernel is inlined into its caller whole, and LLVM saves the registers the long path needs on the caller's entry, before any test: in encoding, `decodeBody` pushes six and sets up a frame on every call. To test it, utf v0.1.0 was patched to call the long path out of line in every build ([split.diff](bmp-converters-20261104/utf1/split-encoding/split.diff)). Encoding's bench arm was built native with and without the patch (`zig build --fork`) and at baseline, and the three ran in 10 interleaved rounds over the 16-, 64-, and 256-byte rows ([utf1/split-encoding/](bmp-converters-20261104/utf1/split-encoding/)):

| row (to UTF-16) | native, inline | native, out of line | baseline |
| --------------- | -------------: | ------------------: | -------: |
| ascii-16        |        9.65 ns |             7.78 ns |  8.95 ns |
| web-16          |        9.46 ns |             7.79 ns |  8.77 ns |
| nonascii-16     |       16.02 ns |            17.07 ns | 17.11 ns |
| mixed-16        |       15.98 ns |            16.93 ns | 17.20 ns |
| invalid-16      |        63.3 ns |             79.5 ns |  92.0 ns |
| ascii-64        |       10.13 ns |             8.44 ns |  8.97 ns |
| nonascii-64     |       16.12 ns |            17.15 ns | 17.40 ns |
| invalid-256     |         896 ns |             1089 ns |  1280 ns |

The ASCII rows gain 17–19% out of line and pass baseline, so this is the cause. The decodes to UTF-8 do not change, because `validate.utf8` has its own short path. Rows that reach the long path pay the call and the pushes there: nonascii and mixed at 16–64 bytes lose 6%, invalid input loses 21–32%, and 256-byte rows are level. The geomean time over all 48 rows is 1.4% lower than inline.

In utf's own harness, the same change for `utf8ToUnits` alone (native, `Utf8ToUtf16le` and `Utf8ToUtf32` rows, 10 rounds, [utf1/split-utf-harness/](bmp-converters-20261104/utf1/split-utf-harness/)) costs 6–9% on ASCII and 9–14% on other text at 16 bytes, 17–18% on ASCII at 256 bytes, and up to 4% on whole files. There the harness's loop is the caller, and it saves the registers once outside the loop.

So keeping the long path inline is the right default for utf's harness and for any caller that calls in a loop. Moving it out of line pays for a caller like encoding that converts short ASCII strings in a function of their own. Encoding cannot get that alone: a wrapper that keeps utf's call out of line still has the whole kernel, and its pushes, in one function. Not changed here; it is for the owner, with the numbers above.

## Tests

- `src/bmp.zig`, every test under `dispatch.forEachLevel`, so the baseline build checks the AVX-512, AVX2, SSE, and generic kernels. It covers every BMP code point at every lane of a block and a block pair, after text of each mix of lengths. It covers text of each mix at every length to 200, into every room from 70 below the exact size up to it, and a random one. For `utf8ToBmp` it adds every lead and second byte, with a grid of third bytes, at offsets around every window boundary and at the end of input; every error kind and four-byte character at every position; U+0000 at every lane; and surrogates in and out of a block. The references are `scalar_convert`, `std.unicode`, and the general converters (`validUtf16leToUtf8`, `utf8ToUtf16le`) where the whole input converts.
- Mutations: a wrong shuffle in the three-byte path fails the tests. Dropping AVX-512's forced keep of the last lane's lead in `packNarrow` survives, and is equivalent: that byte is zero only for U+0000, and `vpcompressb` fills with zeros.
- Oracle (`just oracle`, `just cpu=baseline oracle`, under simdutf's best kernel and its fallback): `convert.utf8ToBmp` checked against simdutf's `utf8_to_utf16le` on 1,638,976 inputs each run. Expected `read` is the smaller of simdutf's error position and the first byte F0–F4 before it. The output is simdutf's when the whole input converts, and `std.unicode`'s conversion of the part read otherwise. `convert.bmpToUtf8` against `utf16le_to_utf8` on the 59,054 inputs without surrogates. 0 mismatches.
- aarch64: `zig build test -Dtarget=aarch64-linux-musl -fqemu -Doptimize=ReleaseSafe` passes (qemu-user 11.1.2), which runs the NEON shuffle kernels with the three-byte path.
