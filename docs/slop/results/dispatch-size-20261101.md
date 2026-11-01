# Size of dispatching builds, 2026-11-01

A program built for a generic x86-64 CPU carried every dispatched function's AVX-512, AVX2, and SSE kernels, and in ReleaseFast and ReleaseSmall the whole panic handler, whatever it called. Ghostty saw `libghostty-vt.so` grow from 2.37 MB with simdutf to 2.86 MB with utf on `zig-0.17` (`1f69e90`), calling four functions. Two causes, two fixes:

- **The tier objects were one section each.** build.zig compiles each tier's object with every public function exported (`dispatch.zig` references them all), and the objects were built without function or data sections, so the linker could only keep an object's `.text` and `.rodata` whole. Now they are built with `-ffunction-sections -fdata-sections` (`link_function_sections`, `link_data_sections` on the object's `Compile`), and a linker that collects garbage sections keeps only the exports the main build references, which are the slots of the functions the program calls, and what they reach. Zig links with `--gc-sections` in every mode but Debug.
- **The main build always exported the panic entry the tier objects forward safety panics to** (`<prefix>_panic`), so every dispatching program linked `std.lang.panic.call`: the default panic handler, with std's stack-trace, DWARF, and ELF code, 167 KB of a stripped shared library that had no panic handler of its own. Only modes with runtime safety have such panics: no ReleaseFast or ReleaseSmall tier object has an undefined reference to it (`nm -u`, every object built here), so the entry is now exported only where `std.debug.runtime_safety`. Should a tier's code ever panic in an unsafe mode, the link fails on the undefined symbol rather than misbehaving.

The kernels' machine code is unchanged: the 69 tier exports of the per-call benchmark are instruction for instruction the same before and after, and so are 410 of its 414 other functions (the four that differ are std's: `debug.defaultPanic` and three `Io.Threaded` functions, none on a call's path).

## Headline

A consumer calling `convert.utf8ToUtf32`, `length.countUtf8`, `base64.decode`, and `base64.maxDecodedLen` (`dispatch-size-20261101/consumer/`), Zig 0.17.0, LLD 22.1.8, stripped, `-Dcpu=baseline`, ReleaseFast: **the shared library is 358,480 bytes, from 942,496 (−62%); the executable 590,464, from 1,007,520 (−41%)**. The executable already links the panic handler through `std.start`, so it gains only from the sections.

What is left over the same build without dispatch (62,504 bytes) is what dispatching these functions costs: their kernels for three more tiers and the generic one compiled out of line, where a native build inlines them and folds the call's constant options. `base64.decode` is 199 KB of the 296: its tier entries take the alphabet, last-chunk rule, and whitespace handling at run time, so each tier carries every specialization.

## Setup

- Machine: Amp orb, KVM guest, Intel Xeon @ 2.60GHz (Ice Lake server, family 6 model 106, AVX-512 with VBMI2 and GFNI), 4 vCPUs, TSC at 2.6 GHz.
- Zig 0.17.0 from the flake; LLD 22.1.8 is Zig's linker for these outputs (`.comment`).
- `before` is `zig-0.17` at `1f69e90`; `after` is that plus this change.
- Sizes: `consumer/sizes.sh before=<checkout> after=<checkout>` builds `consumer/` (an executable and a shared library, `src/main.zig` and `src/lib.zig`, both stripped) against each checkout. Output: `sizes-zig-0.17.txt`, and `sizes-zig-0.16.txt` for the port to `main`.
- Per call: the `calls` benchmark of [calls-20261031.md](calls-20261031.md), ported to Zig 0.17 (`calls-baseline/calls/`), built with `-Dutf-cpu=baseline` against each checkout, so it dispatches to the AVX-512 object; `calls-20261031/calls.sh` ran the two binaries in turn, pinned to CPU 3, 10 rounds. `rounds/` holds every run; `table-d10.txt` each case's minimum; `benchstat10.txt` compares the per-round minimums (ns, 2.6 ticks a ns). `samecode.py OLD NEW` compares the binaries' instructions.

## Sizes, Zig 0.17.0 (`sizes-zig-0.17.txt`)

Bytes, stripped.

```
arm      optimize     build                             exe        lib
before   ReleaseFast  baseline                      1007520     942496
before   ReleaseSmall baseline                      1076856    1063408
before   ReleaseSafe  baseline                      1256912    1114928
before   Debug        baseline                     34744248   32019256
before   ReleaseFast  baseline, no dispatch          294952      62504
before   ReleaseFast  native                         260184      26760
after    ReleaseFast  baseline                       590464     358480
after    ReleaseSmall baseline                       587816     442856
after    ReleaseSafe  baseline                       741456     599520
after    Debug        baseline                     34744248   32019256
after    ReleaseFast  baseline, no dispatch          294952      62504
after    ReleaseFast  native                         260184      26760
```

- The sections alone (panic entry still exported) gave the ReleaseFast library 525,504 bytes and the executable 590,528; the panic entry's condition takes the library to 358,480.
- ReleaseSafe gains from the sections only: it exports the entry, and a program with safety checks links the handler anyway. Its library is 599,520 bytes, from 1,114,928.
- Debug is unchanged: Zig does not collect garbage sections in Debug builds.
- Builds without dispatch, native or baseline, are byte for byte the size they were.
- In the after library the tier symbols are the nine of the three dispatched functions, `utf_<prefix>_{avx512,avx2,sse}_{base64_decode,convert_utf8ToUtf32,length_countUtf8}`; before, each object's 66 exports were all linked.

## Per call (`calls-baseline/`)

Dispatched from baseline into the AVX-512 object, 69 cases (23 functions at 0, 16, and 64 bytes), minimum TSC ticks per call over 10 rounds of 15 loops of 2 million calls: the median difference new − old is −0.01 ticks, the geomean ratio 0.974. benchstat over the per-round minimums: geomean −2.52%, 22 cases unchanged (the three `empty` among them), 32 faster, 18 slower, every move within 1.7 ticks (0.65 ns) either way, in steps of about 0.8 ticks, as [calls-20261031.md](calls-20261031.md) found the same code moving by about a tick with where it lands. With the instructions identical, these are placement, not the change.

```
case                               old-d       new-d
empty/0                             3.89        3.89
ascii/16                            7.03        5.47
utf8/16                             8.31        7.47
utf8WithErrors/16                   9.15        7.47
countUtf8/16                        7.47        6.65
countUtf16le/16                     7.49        9.13
latin1ToUtf32/64                   10.87       12.51
b64decode/16                       22.81       23.32
b64decode/64                       24.96       24.55
```

(Excerpt; `table-d10.txt` has every case.)

## Port to `main` (Zig 0.16.0, `sizes-zig-0.16.txt`)

The same two changes apply to `main` (`db5728c`) unchanged, and its tests pass at `-Dcpu=baseline` in Debug, ReleaseSafe, and ReleaseFast. The consumer against `main` before and after, Zig 0.16.0:

```
arm      optimize     build                             exe        lib
before   ReleaseFast  baseline                      1004896     936824
before   ReleaseSmall baseline                       860088     846536
before   ReleaseSafe  baseline                      1226680    1102808
before   Debug        baseline                     32401272   30140450
before   ReleaseFast  baseline, no dispatch          296568      61432
before   ReleaseFast  native                         255096      26872
after    ReleaseFast  baseline                       585648     351024
after    ReleaseSmall baseline                       482656     340168
after    ReleaseSafe  baseline                       711272     587352
after    Debug        baseline                     32401272   30140450
after    ReleaseFast  baseline, no dispatch          296568      61432
after    ReleaseFast  native                         255096      26872
```
