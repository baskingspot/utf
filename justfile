# utf: SIMD UTF-8, UTF-16, and UTF-32 validation and transcoding, and base64, in Zig. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

markdown := "README.md AGENTS.md CHANGELOG.md bench/README.md docs/slop .github"

# How `just bench-compare` builds this package's arm, and which simdutf kernel
# its arm runs (empty: simdutf's runtime pick). Set them on the command line:
# `just cpu=baseline dispatch=false kernel=fallback bench-compare`. dispatch
# empty is the package's default: runtime dispatch for a generic x86-64 CPU
# (baseline or an x86-64 level), none for native.
optimize := "ReleaseFast"
cpu := "native"
dispatch := ""
kernel := ""
bench_zig := "zig build -p ../zig-out -Dutf-optimize=" + optimize + " -Dutf-cpu=" + cpu + if dispatch == "" { "" } else { " -Dutf-dispatch=" + dispatch }

[private]
default:
    @just --list

[doc("Unit tests, in Debug and ReleaseSafe")]
[group("test")]
test:
    zig build test --summary all
    zig build test -Doptimize=ReleaseSafe --summary all

[doc("Lint Zig, Go, Nix, Markdown, the workflows, and this justfile: ziglint, zig fmt, gofmt, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint
    zig fmt --check src build.zig build.zig.zon bench/build.zig bench/build.zig.zon bench/zig bench/oracle
    test -z "$(gofmt -l bench/go)"
    nix fmt -- --ci
    oxfmt --check {{ markdown }}
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src build.zig build.zig.zon bench/build.zig bench/build.zig.zon bench/zig bench/oracle
    gofmt -w bench/go
    nix fmt
    oxfmt {{ markdown }}
    just --fmt

[doc("Everything CI runs")]
[group("ci")]
ci: test lint

[doc("Fetch and generate the benchmark corpus in bench/corpus-gen/, and verify it against bench/corpus/SHA256SUMS")]
[group("bench")]
bench-corpus:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p bench/corpus-gen/lipsum
    grep -v '^#' bench/corpus/sources.tsv | while IFS=$'\t' read -r name url; do
        [ -f "bench/corpus-gen/lipsum/$name" ] || curl -sSfL -o "bench/corpus-gen/lipsum/$name" "$url"
    done
    (cd bench && {{ bench_zig }})
    zig-out/bin/bench-corpus
    cd bench/corpus-gen && sha256sum --quiet --check ../corpus/SHA256SUMS

# Every arm, into zig-out/bin/bench-<arm>.
[private]
bench-build:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p zig-out/bin
    (cd bench && {{ bench_zig }})
    c++ -O3 -std=c++20 -o zig-out/bin/bench-simdutf bench/simdutf/main.cpp \
        $(pkg-config --cflags --libs simdutf) -Wl,-rpath,"$(pkg-config --variable=libdir simdutf)"
    go build -C bench/go -o ../../zig-out/bin/bench-go .
    RUSTFLAGS="-C target-cpu=native" cargo build --quiet --release --locked --manifest-path bench/rust/Cargo.toml
    cp bench/rust/target/release/bench-rust zig-out/bin/

[doc("Compare with simdutf, Rust, Go, and Zig's std on this machine: checksums, peak RSS, then interleaved rounds on one core, benchstat against simdutf, and a summary per operation. OPS picks operations from bench/ops.tsv (default all); the variables optimize, cpu, dispatch, and kernel pick the builds. The numbers are not claims")]
[group("bench")]
bench-compare ROUNDS="6" *OPS: bench-corpus bench-build
    #!/usr/bin/env bash
    set -euo pipefail
    out=zig-out/bench-compare
    rm -rf "$out" && mkdir -p "$out"
    arms=(simdutf utf std rust go)
    ops=({{ OPS }})
    if [ -n "{{ kernel }}" ]; then export SIMDUTF_FORCE_IMPLEMENTATION="{{ kernel }}"; fi
    # The outputs must match before the timings mean anything: every arm's
    # checksums against simdutf's, on the rows both have.
    for arm in "${arms[@]}"; do
        zig-out/bin/bench-$arm check "${ops[@]}" > "$out/check-$arm.txt" 2> "$out/stderr-$arm.txt" ||
            { cat "$out/stderr-$arm.txt"; exit 1; }
    done
    { echo "utf: {{ optimize }}, cpu {{ cpu }}, dispatch {{ if dispatch == "" { "default" } else { dispatch } }}"; cat "$out/stderr-simdutf.txt"; } | tee "$out/config.txt"
    status=0
    for arm in "${arms[@]:1}"; do
        join -t $'\t' <(grep -v '^#' "$out/check-simdutf.txt" | sort) <(grep -v '^#' "$out/check-$arm.txt" | sort) |
            awk -F'\t' '$2 != $3' > "$out/check-diff-$arm.txt"
        if [ -s "$out/check-diff-$arm.txt" ]; then
            echo "checksums differ between simdutf and $arm (row, simdutf, $arm):"
            cat "$out/check-diff-$arm.txt"
            status=1
        fi
        printf '%-8s %4d rows match simdutf, %d operations skipped\n' "$arm" \
            "$(grep -vc '^#' "$out/check-$arm.txt" || true)" "$(grep -c '^# SKIP' "$out/check-$arm.txt" || true)"
    done
    grep -h '^# SKIP' "$out"/check-utf.txt || true
    [ "$status" = 0 ] || exit 1
    # Peak RSS of one pass over each operation's inputs: the inputs and
    # output buffers, which every arm holds alike, plus the arm's runtime.
    echo
    {
        printf '%-26s' "peak RSS (MiB)"; printf '%9s' "${arms[@]}"; echo
        for op in ${ops[@]:-$(grep -v '^#' bench/ops.tsv | cut -f1)}; do
            printf '%-26s' "$op"
            for arm in "${arms[@]}"; do
                command time -f %M -o "$out/rss-run.txt" zig-out/bin/bench-$arm check "$op" > "$out/rss-check.txt" 2> /dev/null
                if grep -q '^# SKIP' "$out/rss-check.txt"; then printf '%9s' -; continue; fi
                awk '{ printf "%9.1f", $1 / 1024 }' "$out/rss-run.txt"
            done
            echo
        done
    } | tee "$out/rss.txt"
    echo
    # The last core, and one round of each arm at a time in a rotating order,
    # so drift on the machine lands on every arm alike.
    core=$(( $(nproc) - 1 ))
    for round in $(seq 0 $(( {{ ROUNDS }} - 1 ))); do
        for i in "${!arms[@]}"; do
            arm=${arms[$(( (round + i) % ${#arms[@]} ))]}
            taskset -c "$core" zig-out/bin/bench-$arm bench "${ops[@]}" >> "$out/raw-$arm.txt"
        done
    done
    # Only the rows, and of each row only its throughput, in GB/s: testingx's
    # header lines, which the other arms lack, would put the Zig arms in
    # tables of their own, and it rounds ns/op to whole nanoseconds, which
    # blurs the short inputs. An arm with no rows yet is left out.
    files=()
    for arm in "${arms[@]}"; do
        awk '/^Benchmark/ { for (i = 3; i < NF; i += 2) if ($(i + 1) == "MB/s") printf "%s\t%s\t%.4f GB/s\n", $1, $2, $i / 1000 }' \
            "$out/raw-$arm.txt" > "$out/$arm.txt"
        [ -s "$out/$arm.txt" ] && files+=("$arm=$out/$arm.txt")
    done
    benchstat "${files[@]}" > "$out/benchstat.txt"
    echo "benchstat: $out/benchstat.txt"
    echo
    just bench-summary "$out" | tee "$out/summary.txt"

[doc("Summarize a bench-compare run in DIR: per operation, utf's geomean throughput against each arm's")]
[group("bench")]
bench-summary DIR="zig-out/bench-compare":
    #!/usr/bin/env bash
    set -euo pipefail
    files=()
    for arm in utf simdutf std rust go; do
        [ -s "{{ DIR }}/$arm.txt" ] && files+=("{{ DIR }}/$arm.txt")
    done
    awk -f bench/summary.awk "${files[@]}"

[doc("Build the simdutf oracle, zig-out/bin/utf-oracle, which tests and fuzzers drive through bench/oracle/Oracle.zig")]
[group("bench")]
oracle-build:
    mkdir -p zig-out/bin
    c++ -O2 -std=c++20 -o zig-out/bin/utf-oracle bench/oracle/oracle.cpp \
        $(pkg-config --cflags --libs simdutf) -Wl,-rpath,"$(pkg-config --variable=libdir simdutf)"

[doc("Compare this package's results with simdutf's on N random and adversarial inputs (default 1000000), under simdutf's best kernel and its scalar fallback")]
[group("bench")]
oracle N="1000000" SEED="1": oracle-build
    cd bench && zig build -p ../zig-out
    zig-out/bin/oracle-compare {{ N }} {{ SEED }}
    SIMDUTF_FORCE_IMPLEMENTATION=fallback zig-out/bin/oracle-compare {{ N }} {{ SEED }}
