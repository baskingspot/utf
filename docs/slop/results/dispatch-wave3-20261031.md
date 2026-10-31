# The `Result` copy in `dispatch.call`, 2026-10-31

Every checked and `WithErrors` function returns a 16-byte `Result` (`count` at offset 0, `err` at 8). `dispatch.call` copied it out with one 16-byte load right after the two narrower stores that wrote it. A load cannot forward from two stores, so it waits for them to reach the cache, about 12–15 cycles. This happened in both roles:

- **`.main`** (a dispatching build): each tier's call wrote its words into a stack slot of its own (`mov [rbp-0x20], rdx; mov [rbp-0x18], al`), the paths joined on a pointer to the chosen slot, and `movups xmm0, [r14]; movups [rbx], xmm0` copied it to the caller. The in-place path did the same through its own `Result`.
- **`.off`** (a native or named CPU, aarch64): `@call(.always_inline, f, args)` put each `return` of the kernel into a slot of its own, and the joined result was copied the same way. `@call(.auto, ...)`, the validation orb's fix, removes it only where LLVM inlines the kernel: `base64.decode` on `x86_64_v3` called `decodeKernel` out of line into a temporary and copied that.

The fix, in `src/dispatch.zig`:

- Two words travel as one `u128` (`Words`) instead of an `extern struct`. Under the C calling convention it comes back in `rax:rdx` as before, but LLVM keeps it in registers, so every path of `call` yields a scalar and the `Result` is built from it once, after the paths join: two stores straight into the caller's result.
- The in-place path and the first call (`Init`) return words too: the in-place path calls the same `Entry` wrapper the tier objects export, and `Init` takes the argument words, so the wrapper keeps nothing on the stack (frame 0x70 to 0x8 bytes).
- `.off` returns `fromWords(toResult(@call(.always_inline, f, args)))`: the kernel's result is read field by field and rebuilt from scalars, whatever its paths are. This also covers any kernel that chooses between two built results, which is what transcoding's `tail` did (`38ac25a`).

Checked: the code of every public function returning `Result` (`audit.zig`, `scan.sh`, which flags a 16-byte load stored straight back) has no such copy in a dispatching baseline build or in non-dispatching builds for `native`, `x86_64_v3`, `x86_64_v2`, and `baseline`; before, every one of them had it in the baseline build (and in `dispatch.Init`, 26 places), and `asciiWithErrors`, `utf32WithErrors`, `utf8WithErrors`, and `base64.decode` had it in the native one.

- Machine: Amp orb, KVM guest, Intel Xeon @ 2.60GHz (Ice Lake server, family 6 model 106, AVX-512 with VBMI2 and GFNI), 2 cores × 2 threads; every timed process pinned to CPU 3, builds on CPUs 0–1.
- Zig 0.16.0, ReleaseFast, testingx 0.2.0. `stall.zig` calls each function with `@call(.never_inline, ...)` and reads the result field by field, so only the callee's own copy can stall. Inputs 16 bytes past a 64-byte boundary: French-ish Latin text for UTF-8 and the conversions from UTF-8, ASCII for `asciiWithErrors`, Latin text as UTF-16LE and UTF-32 for those rows, base64 of ASCII for `b64decode`; every row's result is checked to be `.none`.
- Arms: `old` is `origin/main` (`6f0a81a`), `new` this change. `-d` is `-Dcpu=baseline`, dispatching to the AVX-512 object; `-n` is `-Dcpu=native`, no dispatch. `run.sh` rotates the four arms run by run, eight rounds, `--benchtime=100ms`; benchstat over GB/s, n=8. Raw output `raw-<arm>.txt`; `benchstat.txt` against `old-d`, `benchstat-native.txt` and `benchstat-dispatch.txt` new against old.

## Takeaways

- **Dispatched (`-d`)**: geomean +31.5% over every row. `WithErrors` validation at 16–64 bytes 2.0–2.2× (`asciiWithErrors` 16 B 12.4 to 5.6 ns, `utf16leWithErrors` 12.2 to 5.6, `utf32WithErrors` 11.9 to 5.8, `utf8WithErrors` 13.8 to 8.6), checked conversions 1.2–1.8× at 16–64 bytes (`latin1ToUtf16le` 14.4 to 8.6 ns, `utf16leToUtf8` 16.1 to 11.6, `utf32ToUtf16le` 14.8 to 10.3), `base64.decode` 17.9 to 14.8 ns at 16 B and 17.4 to 12.5 at 64 B; level from 1–4 KiB.
- **Native (`-n`)**: geomean +15.6%. `asciiWithErrors`, `utf32WithErrors`, and `utf8WithErrors`, which paid the copy, 1.7–2.4× at 16–64 bytes (`asciiWithErrors` 12.0 to 5.0 ns, `utf32WithErrors` 12.0 to 5.1, `utf8WithErrors` 13.0 to 7.5); the conversions, `utf16leWithErrors`, and `decode`, which did not, level (every row within noise).
- **Dispatch now costs 0.1–3 ns over native** on these rows (it was 0.4–7 ns): `latin1ToUtf16le` 8.6 against 7.1 ns at 16 B, `asciiWithErrors` 5.6 against 5.0, `decode` 14.8 against 11.6.
- **Memory**: no allocation either way; text of the stall suite 1,273,505 to 1,270,097 bytes dispatched, 681,426 to 681,394 native.

## Per call, ns (size ÷ median GB/s)

```
row                            old-d   new-d   old-n   new-n
utf8/size=16                   13.81    8.57   12.95    7.45
utf8/size=64                   14.16    9.44   13.06    8.21
utf8/size=256                  19.10   16.16   17.42   14.58
ascii/size=16                  12.36    5.59   12.02    5.00
ascii/size=64                  12.00    5.35   12.12    5.22
ascii/size=256                 12.03    6.17   12.14    5.15
utf16le/size=16                12.17    5.62    5.26    5.39
utf16le/size=64                12.01    5.79    5.37    5.45
utf16le/size=256               12.96    9.36    7.91    8.85
utf32/size=16                  11.85    5.78   12.01    5.06
utf32/size=64                  11.73    5.98   11.95    5.02
utf32/size=256                 12.42    7.79   12.10    6.18
utf8ToUtf16le/size=16          17.89   14.63   13.61   13.37
utf8ToUtf16le/size=64          19.63   17.58   16.12   16.04
utf8ToUtf16le/size=256         52.72   48.76   47.77   47.37
latin1ToUtf16le/size=16        14.42    8.59    7.10    7.14
latin1ToUtf16le/size=64        15.25    8.71    8.16    8.18
latin1ToUtf16le/size=256       18.99   12.45   11.66   11.87
utf16leToUtf8/size=16          16.13   11.60   10.60   10.49
utf16leToUtf8/size=64          16.67   11.62   10.42   10.28
utf16leToUtf8/size=256         22.00   20.52   18.88   18.87
utf32ToUtf16le/size=16         14.77   10.34    9.36    9.20
utf32ToUtf16le/size=64         14.69   10.07    9.22    9.44
utf32ToUtf16le/size=256        15.39   11.21    9.73   10.56
b64decode/size=16              17.86   14.80   12.03   11.56
b64decode/size=64              17.41   12.52   10.25    9.80
b64decode/size=256             18.96   14.96   12.67   12.92
```

## benchstat, against `old-d`

benchstat writes a row with any value under 1 GB/s in thousandths: `894.5m` is 0.89 GB/s. The ±40% spreads in `new-n` come from rounds when another guest loaded the host; the medians agree with `new-d` and with single runs.

```
                          │    old-d     │                 new-d                 │                 old-n                 │                 new-n                 │
                          │     GB/s     │     GB/s       vs base                │     GB/s       vs base                │     GB/s       vs base                │
utf8/size=16                 1.159 ± 27%     1.866 ± 25%   +61.08% (p=0.000 n=8)     1.235 ±  2%    +6.62% (p=0.000 n=8)     2.148 ±  9%   +85.43% (p=0.000 n=8)
utf8/size=64                 4.519 ±  9%     6.781 ± 22%   +50.06% (p=0.000 n=8)     4.902 ±  4%    +8.49% (p=0.001 n=8)     7.791 ± 10%   +72.42% (p=0.000 n=8)
utf8/size=256                13.40 ± 18%     15.84 ± 27%         ~ (p=0.065 n=8)     14.70 ±  8%    +9.66% (p=0.010 n=8)     17.55 ± 12%   +30.98% (p=0.000 n=8)
utf8/size=1024               19.36 ± 35%     19.81 ± 13%         ~ (p=0.279 n=8)     19.85 ± 11%         ~ (p=0.161 n=8)     20.30 ±  9%    +4.87% (p=0.021 n=8)
utf8/size=4096               20.86 ± 33%     21.14 ±  8%         ~ (p=0.130 n=8)     20.76 ± 22%         ~ (p=0.574 n=8)     21.04 ±  5%         ~ (p=0.195 n=8)
ascii/size=16                1.294 ±  7%     2.864 ± 10%  +121.27% (p=0.000 n=8)     1.332 ±  5%         ~ (p=0.574 n=8)     3.198 ± 39%  +147.09% (p=0.000 n=8)
ascii/size=64                5.334 ± 10%    11.953 ± 11%  +124.10% (p=0.000 n=8)     5.279 ±  8%         ~ (p=0.645 n=8)    12.255 ± 41%  +129.76% (p=0.000 n=8)
ascii/size=256               21.28 ± 16%     41.50 ±  3%   +95.04% (p=0.000 n=8)     21.09 ±  7%         ~ (p=0.442 n=8)     49.70 ± 44%  +133.58% (p=0.000 n=8)
ascii/size=1024              71.57 ± 29%     78.12 ±  6%    +9.15% (p=0.000 n=8)     75.61 ± 14%    +5.65% (p=0.010 n=8)     91.97 ± 32%   +28.51% (p=0.028 n=8)
ascii/size=4096              176.7 ± 21%     179.5 ± 18%         ~ (p=0.574 n=8)     193.0 ± 11%    +9.24% (p=0.038 n=8)     204.9 ± 41%   +15.97% (p=0.010 n=8)
utf16le/size=16              1.315 ± 20%     2.848 ±  8%  +116.62% (p=0.000 n=8)     3.039 ± 13%  +131.12% (p=0.000 n=8)     2.966 ± 38%  +125.59% (p=0.000 n=8)
utf16le/size=64              5.327 ± 17%    11.059 ±  8%  +107.61% (p=0.000 n=8)    11.910 ±  9%  +123.58% (p=0.000 n=8)    11.733 ± 40%  +120.26% (p=0.000 n=8)
utf16le/size=256             19.76 ± 16%     27.35 ±  4%   +38.40% (p=0.000 n=8)     32.38 ± 17%   +63.86% (p=0.000 n=8)     28.91 ± 35%   +46.32% (p=0.003 n=8)
utf16le/size=1024            59.24 ± 24%     66.81 ± 21%   +12.78% (p=0.015 n=8)     72.38 ±  6%   +22.19% (p=0.000 n=8)     70.53 ± 36%   +19.06% (p=0.007 n=8)
utf16le/size=4096            129.9 ± 29%     134.2 ± 20%         ~ (p=0.130 n=8)     140.6 ± 16%    +8.22% (p=0.005 n=8)     138.0 ± 38%         ~ (p=0.130 n=8)
utf32/size=16                1.350 ± 13%     2.766 ± 18%  +104.92% (p=0.000 n=8)     1.333 ±  8%         ~ (p=0.382 n=8)     3.164 ± 46%  +134.44% (p=0.000 n=8)
utf32/size=64                5.456 ±  8%    10.708 ± 13%   +96.24% (p=0.000 n=8)     5.354 ±  8%         ~ (p=0.195 n=8)    12.745 ± 16%  +133.59% (p=0.000 n=8)
utf32/size=256               20.60 ±  4%     32.88 ± 18%   +59.58% (p=0.000 n=8)     21.15 ±  5%         ~ (p=0.505 n=8)     41.45 ± 29%  +101.18% (p=0.000 n=8)
utf32/size=1024              61.91 ±  8%     71.96 ± 26%         ~ (p=0.083 n=8)     65.67 ±  5%    +6.08% (p=0.003 n=8)     80.94 ±  5%   +30.75% (p=0.000 n=8)
utf32/size=4096              105.0 ±  3%     113.6 ±  5%    +8.19% (p=0.001 n=8)     109.2 ±  4%    +3.98% (p=0.007 n=8)     113.2 ±  3%    +7.75% (p=0.000 n=8)
utf8ToUtf16le/size=16       894.5m ±  6%   1093.8m ±  7%   +22.28% (p=0.000 n=8)   1175.9m ± 22%   +31.45% (p=0.000 n=8)   1196.6m ±  8%   +33.77% (p=0.000 n=8)
utf8ToUtf16le/size=64        3.261 ±  9%     3.641 ± 11%   +11.66% (p=0.003 n=8)     3.971 ± 10%   +21.79% (p=0.000 n=8)     3.990 ±  5%   +22.36% (p=0.000 n=8)
utf8ToUtf16le/size=256       4.856 ± 17%     5.251 ±  4%    +8.12% (p=0.007 n=8)     5.359 ± 20%   +10.35% (p=0.021 n=8)     5.404 ±  6%   +11.28% (p=0.003 n=8)
utf8ToUtf16le/size=1024      5.563 ± 15%     5.754 ±  2%         ~ (p=0.130 n=8)     5.820 ±  2%         ~ (p=0.083 n=8)     5.828 ±  6%         ~ (p=0.130 n=8)
utf8ToUtf16le/size=4096      5.751 ±  3%     5.765 ±  7%         ~ (p=0.721 n=8)     5.771 ±  5%         ~ (p=0.328 n=8)     5.879 ±  4%    +2.23% (p=0.050 n=8)
latin1ToUtf16le/size=16      1.110 ±  3%     1.863 ± 15%   +67.91% (p=0.000 n=8)     2.253 ±  7%  +103.09% (p=0.000 n=8)     2.240 ±  8%  +101.93% (p=0.000 n=8)
latin1ToUtf16le/size=64      4.197 ±  3%     7.347 ±  3%   +75.05% (p=0.000 n=8)     7.844 ±  4%   +86.90% (p=0.000 n=8)     7.826 ± 13%   +86.46% (p=0.000 n=8)
latin1ToUtf16le/size=256     13.48 ±  5%     20.56 ± 19%   +52.55% (p=0.000 n=8)     21.95 ± 11%   +62.86% (p=0.000 n=8)     21.56 ±  8%   +59.95% (p=0.000 n=8)
latin1ToUtf16le/size=1024    40.65 ±  5%     46.05 ± 19%   +13.26% (p=0.050 n=8)     48.32 ±  2%   +18.86% (p=0.000 n=8)     48.02 ±  6%   +18.11% (p=0.000 n=8)
latin1ToUtf16le/size=4096    67.21 ±  9%     73.18 ±  4%    +8.87% (p=0.000 n=8)     76.29 ± 36%   +13.50% (p=0.010 n=8)     74.89 ±  4%   +11.42% (p=0.000 n=8)
utf16leToUtf8/size=16       992.1m ± 14%   1379.4m ± 14%   +39.03% (p=0.000 n=8)   1510.0m ±  5%   +52.20% (p=0.000 n=8)   1525.0m ±  5%   +53.71% (p=0.000 n=8)
utf16leToUtf8/size=64        3.838 ± 25%     5.508 ± 10%   +43.51% (p=0.000 n=8)     6.145 ±  5%   +60.08% (p=0.000 n=8)     6.229 ±  6%   +62.27% (p=0.000 n=8)
utf16leToUtf8/size=256       11.64 ± 25%     12.48 ± 12%         ~ (p=0.065 n=8)     13.56 ± 15%   +16.52% (p=0.002 n=8)     13.57 ± 15%   +16.56% (p=0.010 n=8)
utf16leToUtf8/size=1024      15.82 ± 15%     15.81 ±  2%         ~ (p=0.798 n=8)     15.91 ±  4%         ~ (p=0.442 n=8)     16.35 ±  5%    +3.36% (p=0.050 n=8)
utf16leToUtf8/size=4096      17.12 ±  9%     17.17 ±  9%         ~ (p=0.878 n=8)     16.97 ±  3%         ~ (p=0.878 n=8)     17.23 ±  5%         ~ (p=0.328 n=8)
utf32ToUtf16le/size=16       1.083 ±  3%     1.548 ± 12%   +42.86% (p=0.000 n=8)     1.710 ±  8%   +57.83% (p=0.000 n=8)     1.739 ± 19%   +60.48% (p=0.000 n=8)
utf32ToUtf16le/size=64       4.357 ± 10%     6.355 ± 17%   +45.85% (p=0.000 n=8)     6.942 ±  3%   +59.32% (p=0.000 n=8)     6.778 ± 30%   +55.57% (p=0.000 n=8)
utf32ToUtf16le/size=256      16.63 ± 21%     22.84 ±  8%   +37.36% (p=0.000 n=8)     26.32 ±  6%   +58.25% (p=0.000 n=8)     24.24 ± 11%   +45.74% (p=0.000 n=8)
utf32ToUtf16le/size=1024     40.47 ±  6%     41.82 ± 20%         ~ (p=0.195 n=8)     42.86 ±  7%    +5.91% (p=0.005 n=8)     41.50 ±  4%    +2.55% (p=0.021 n=8)
utf32ToUtf16le/size=4096     42.94 ± 22%     41.53 ± 18%         ~ (p=0.234 n=8)     43.21 ±  5%         ~ (p=0.442 n=8)     43.14 ±  5%         ~ (p=0.505 n=8)
b64decode/size=16           896.0m ± 15%   1081.3m ± 18%   +20.68% (p=0.003 n=8)   1330.5m ±  4%   +48.49% (p=0.000 n=8)   1384.6m ± 22%   +54.52% (p=0.000 n=8)
b64decode/size=64            3.676 ± 17%     5.113 ±  8%   +39.09% (p=0.000 n=8)     6.244 ± 25%   +69.86% (p=0.000 n=8)     6.530 ±  9%   +77.62% (p=0.000 n=8)
b64decode/size=256           13.51 ± 24%     17.11 ± 30%   +26.68% (p=0.010 n=8)     20.21 ±  5%   +49.66% (p=0.000 n=8)     19.82 ±  4%   +46.74% (p=0.000 n=8)
b64decode/size=1024          33.29 ± 30%     36.18 ± 10%    +8.68% (p=0.007 n=8)     37.62 ± 14%   +12.99% (p=0.005 n=8)     37.99 ±  7%   +14.13% (p=0.000 n=8)
b64decode/size=4096          42.42 ± 26%     42.91 ± 18%         ~ (p=0.574 n=8)     43.62 ±  4%    +2.81% (p=0.010 n=8)     43.86 ±  2%    +3.38% (p=0.002 n=8)
geomean                      9.820           12.92         +31.51%                   12.16         +23.84%                   14.06         +43.20%
```

## Reproduce

`build.zig.zon` takes the package twice, `new` from `../repo` and `old` from `../old` (a worktree of `6f0a81a`); `-Dtree` picks one.

```
git worktree add ../old 6f0a81a
mkdir ab && cp docs/slop/results/dispatch-wave3-20261031/{stall.zig,audit.zig,scan.sh,run.sh,build.zig,build.zig.zon} ab/ && cd ab
for t in old new; do
  zig build -Dsrc=stall.zig -Dtree=$t -Dcpu=baseline -p out/$t-d
  zig build -Dsrc=stall.zig -Dtree=$t -Dcpu=native -p out/$t-n
done
./run.sh stall 8 old-d new-d old-n new-n
./scan.sh out/new-d/bin/audit   # functions that copy a 16-byte value through memory
```
