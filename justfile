# utf: SIMD UTF-8, UTF-16, and UTF-32 validation and transcoding, and base64, in Zig. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

markdown := "README.md AGENTS.md CHANGELOG.md bench/README.md docs/slop docs/content docs/config.toml .github .oxfmtrc.jsonc"

# How `just bench-compare` builds the arms, and which simdutf kernel its arm
# runs (empty: simdutf's runtime pick). Set them on the command line:
# `just cpu=baseline dispatch=false kernel=fallback bench-compare`. cpu builds
# this package's, std's, Rust's, and Go's arms for one CPU; optimize and
# dispatch apply to this package's alone. dispatch empty is the package's
# default: runtime dispatch for a generic x86-64 CPU (baseline or an x86-64
# level), none for native. base, a Git revision, adds an arm `base`: that
# revision's `bench-utf`, built the same way, for an A/B in one run.
optimize := "ReleaseFast"
cpu := "native"
dispatch := ""
kernel := ""
base := ""
bench_flags := "-Dcpu=" + cpu + " -Dutf-optimize=" + optimize + " -Dutf-cpu=" + cpu + if dispatch == "" { "" } else { " -Dutf-dispatch=" + dispatch }
bench_zig := "zig build -p ../zig-out " + bench_flags

# cpu in Rust's and Go's terms. Go has no native: the highest level the host has.
# simdutf8 and base64-simd detect AVX2 at run time, as a distribution's build
# does; for an x86-64 level or a named CPU they take the ISA cpu names.
rust_cpu := if cpu == "baseline" { "x86-64" } else { replace(cpu, "_", "-") }
rust_detect := if cpu == "baseline" { "detect" } else if cpu == "native" { "detect" } else { "none" }
goamd64 := if cpu == "baseline" { "v1" } else if cpu == "x86_64_v2" { "v2" } else if cpu == "x86_64_v3" { "v3" } else if cpu == "x86_64_v4" { "v4" } else if cpu == "native" { shell("if grep -qw avx512vl /proc/cpuinfo; then echo v4; elif grep -qw avx2 /proc/cpuinfo; then echo v3; else echo v2; fi") } else { "v1" }

[private]
default:
    @just --list

[doc("Unit tests and the guide's examples, in Debug and ReleaseSafe, one line per test binary via testingx")]
[group("test")]
test:
    zig build test --summary all
    zig build test -Doptimize=ReleaseSafe --summary all

[doc("Lint Zig, Go, Nix, Markdown, the workflows, and this justfile: ziglint, zig fmt, gofmt, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint-0-16
    zig fmt --check src build docs/examples build.zig build.zig.zon bench/build.zig bench/build.zig.zon bench/compat.zig bench/zig bench/oracle
    test -z "$(gofmt -l bench/go)"
    nix fmt -- --ci
    oxfmt --check {{ markdown }}
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src build docs/examples build.zig build.zig.zon bench/build.zig bench/build.zig.zon bench/compat.zig bench/zig bench/oracle
    gofmt -w bench/go
    nix fmt
    oxfmt {{ markdown }}
    just --fmt

[doc("Compile-only check for one target this host cannot run, such as `just check-target x86_64-windows-gnu`: the unit tests, the guide's examples, and the kernel objects they link, built but not run")]
[group("test")]
check-target TARGET:
    zig build check -Dtarget={{ TARGET }}

[doc("Compile-only gate for Windows on x86-64 and aarch64: its C calling convention differs from Linux's and macOS's, and the kernels' LLVM intrinsics break when it changes how they take vectors")]
[group("test")]
check-windows:
    just check-target x86_64-windows-gnu
    just check-target x86_64-windows-msvc
    just check-target aarch64-windows-gnu

[doc("Gate for 32-bit targets, where `usize` is narrower than the `u64` sums and masks the kernels use: the x86 tests run on an x86-64 Linux host and compile elsewhere, and the arm ones compile")]
[group("test")]
check-32:
    just check-target arm-linux-gnueabihf
    just check-target arm-linux-androideabi
    {{ if os() + "-" + arch() == "linux-x86_64" { "zig build test -Dtarget=x86-linux --summary all" } else { "just check-target x86-linux" } }}

[doc("Runtime dispatch on x86-64: the tests and the guide's examples built for the baseline CPU, so every wired call crosses into each kernel tier this CPU has, and the oracle against simdutf through the same build")]
[group("test")]
check-dispatch:
    zig build test -Dcpu=baseline --summary all
    zig build test -Dcpu=baseline -Doptimize=ReleaseSafe --summary all
    just cpu=baseline oracle

[doc("Link gate: a program that calls one function, built for a generic x86-64 CPU so it links every tier object, for macOS (Zig's own Mach-O linker on a Linux host), Windows (MinGW and MSVC), and Linux, in Debug, which keeps every tier kernel, and in ReleaseSmall")]
[group("test")]
check-link:
    zig build link -Dtarget=x86_64-macos
    zig build link -Dtarget=x86_64-macos -Doptimize=ReleaseSmall
    zig build link -Dtarget=x86_64-windows-gnu
    zig build link -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSmall
    zig build link -Dtarget=x86_64-windows-msvc
    zig build link -Dtarget=x86_64-linux
    zig build link -Dtarget=x86_64-linux -Doptimize=ReleaseSmall

[doc("The per-version gate: the unit tests and the guide's examples, the Windows and 32-bit compile gates, and the link gate")]
[group("ci")]
check: test check-windows check-32 check-link

[doc("Everything CI runs: the gate, lint, and the docs build")]
[group("ci")]
ci: check lint doc

[doc("Build the site into zig-out/site/utf/: the guide (Zola, from docs/) and the API reference (docgen JSON, rendered by the theme's api.html) under api/. The router in baskingspot/site serves /utf/... from it")]
[group("docs")]
doc: api
    baskingspot-docs build utf

[doc("Edit the guide with live reload (http://127.0.0.1:1111), API reference included")]
[group("docs")]
guide: api
    baskingspot-docs serve utf

# The API reference data. docgen comes from the baskingspot flake's docs shell,
# so this is not a Zig build dependency.
[private]
api:
    docgen --root src/root.zig --title utf --repo-url https://github.com/baskingspot/utf --rev main --format json --out docs/data

[doc("Deploy the rendered docs to Cloudflare as an assets-only Worker (config in wrangler.jsonc). Needs CLOUDFLARE_API_TOKEN in the environment, plus CLOUDFLARE_ACCOUNT_ID if the token can see more than one account")]
[group("docs")]
doc-deploy: doc
    wrangler deploy

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

# Every arm, into zig-out/bin/bench-<arm>, built for cpu.
[private]
bench-build:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p zig-out/bin
    (cd bench && {{ bench_zig }})
    c++ -O3 -std=c++20 -o zig-out/bin/bench-simdutf bench/simdutf/main.cpp \
        $(pkg-config --cflags --libs simdutf) -Wl,-rpath,"$(pkg-config --variable=libdir simdutf)"
    GOAMD64={{ goamd64 }} go build -C bench/go -o ../../zig-out/bin/bench-go .
    RUSTFLAGS="-C target-cpu={{ rust_cpu }}" CARGO_TARGET_DIR=bench/rust/target/{{ rust_cpu }} \
        cargo build --quiet --release --locked --manifest-path bench/rust/Cargo.toml \
        {{ if rust_detect == "none" { "--no-default-features" } else { "" } }}
    cp bench/rust/target/{{ rust_cpu }}/release/bench-rust zig-out/bin/
    if [ -n "{{ base }}" ]; then
        rm -rf zig-out/base && mkdir -p zig-out/base/tree
        git archive "{{ base }}" | tar -x -C zig-out/base/tree
        (cd zig-out/base/tree/bench && zig build -p ../../out {{ bench_flags }})
        cp zig-out/base/out/bin/bench-utf zig-out/bin/bench-base
    fi

[doc("Compare with simdutf, Rust, Go, and Zig's std on this machine: checksums, peak RSS, then rounds on one core that time the arms on each row back to back, benchstat against simdutf, and a summary per operation with each row's noise. OPS picks operations from bench/ops.tsv (default all); the variables optimize, cpu, dispatch, and kernel pick the builds, and base adds another revision's utf arm. The numbers are not claims")]
[group("bench")]
bench-compare ROUNDS="10" *OPS: bench-corpus bench-build
    #!/usr/bin/env bash
    set -euo pipefail
    out=zig-out/bench-compare
    rm -rf "$out" && mkdir -p "$out"
    arms=(simdutf utf {{ if base == "" { "" } else { "base " } }}std rust go)
    ops=({{ OPS }})
    if [ -n "{{ kernel }}" ]; then export SIMDUTF_FORCE_IMPLEMENTATION="{{ kernel }}"; fi
    # Each sample's timed loop: short, so the arms' samples of a row are close
    # in time.
    export BENCHTIME_MS="${BENCHTIME_MS:-50}"
    # The outputs must match before the timings mean anything: every arm's
    # checksums against simdutf's, on the rows both have.
    for arm in "${arms[@]}"; do
        zig-out/bin/bench-$arm check "${ops[@]}" > "$out/check-$arm.txt" 2> "$out/stderr-$arm.txt" ||
            { cat "$out/stderr-$arm.txt"; exit 1; }
    done
    {
        echo "utf: {{ optimize }}, cpu {{ cpu }}, dispatch {{ if dispatch == "" { "default" } else { dispatch } }}, $(git describe --always --dirty)"
        if [ -n "{{ base }}" ]; then echo "base: {{ base }} ($(git rev-parse --short "{{ base }}")), built as utf"; fi
        echo "std: ReleaseFast, cpu {{ cpu }}; rust: target-cpu={{ rust_cpu }}, run-time detection {{ rust_detect }}; go: GOAMD64={{ goamd64 }}"
        echo "buffers: input ${BENCH_IN_OFFSET:-0} bytes past a page, output ${BENCH_OUT_OFFSET:-2048}; ${BENCHTIME_MS} ms a sample, {{ ROUNDS }} rounds"
        cat "$out/stderr-simdutf.txt"
    } | tee "$out/config.txt"
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
    # The rounds. Each arm runs as a server (`bench-<arm> serve`) pinned to
    # the last core, and each row is timed by every arm that has it back to
    # back, in an order that rotates from row to row and round to round, so
    # the arms' samples of a row see the same machine: on a shared host the
    # throughput of every arm steps by up to half for seconds at a time.
    # Every round starts the servers afresh, so each round is a separate
    # process per arm. Round 0 sizes each row's loop to BENCHTIME_MS and is
    # not counted; the rounds after it run that many iterations.
    core=$(( $(nproc) - 1 ))
    taskset -cp 0 $$ > /dev/null
    declare -A arg_of has iters to from
    while IFS=$'\t' read -r arg row _; do arg_of[$row]=$arg; done < <(grep -v '^#' bench/ops.tsv)
    mapfile -t rows < <(grep -v '^#' "$out/check-simdutf.txt" | cut -f1)
    for arm in "${arms[@]}"; do
        while IFS=$'\t' read -r row _; do has[$arm/$row]=1; done < <(grep -v '^#' "$out/check-$arm.txt")
    done
    fifos=$(mktemp -d)
    trap 'rm -rf "$fifos"' EXIT
    start() {
        for arm in "${arms[@]}"; do
            mkfifo "$fifos/$arm.in" "$fifos/$arm.out"
            taskset -c "$core" zig-out/bin/bench-$arm serve < "$fifos/$arm.in" > "$fifos/$arm.out" 2>> "$out/stderr-$arm.txt" &
            exec {fd}> "$fifos/$arm.in"
            to[$arm]=$fd
            exec {fd}< "$fifos/$arm.out"
            from[$arm]=$fd
        done
    }
    stop() {
        for arm in "${arms[@]}"; do eval "exec ${to[$arm]}>&-"; done
        wait
        for arm in "${arms[@]}"; do eval "exec ${from[$arm]}<&-"; done
        rm -f "$fifos"/*
    }
    # One row on one arm, N iterations (0: BENCHTIME_MS), into $line.
    sample() {
        printf '%s %s %s\n' "$2" "$3" "$4" >&"${to[$1]}"
        if ! IFS= read -r line <&"${from[$1]}" || [[ $line != Benchmark* ]]; then
            echo "bench-$1 failed on $2 $3: $line"
            cat "$out/stderr-$1.txt"
            exit 1
        fi
    }
    for round in $(seq 0 {{ ROUNDS }}); do
        start
        j=0
        for row in "${rows[@]}"; do
            arg=${arg_of[${row%%/*}]}
            input=${row#*/}
            present=()
            for arm in "${arms[@]}"; do [ -n "${has[$arm/$row]:-}" ] && present+=("$arm"); done
            for i in "${!present[@]}"; do
                arm=${present[$(( (round + j + i) % ${#present[@]} ))]}
                if [ "$round" = 0 ]; then
                    sample "$arm" "$arg" "$input" 0
                    IFS=$'\t' read -r _ n _ <<< "$line"
                    iters[$arm/$row]=$n
                else
                    sample "$arm" "$arg" "$input" "${iters[$arm/$row]}"
                    echo "$line" >> "$out/raw-$arm.txt"
                fi
            done
            j=$(( j + 1 ))
        done
        stop
        echo "round $round of {{ ROUNDS }} done at $(date +%T)"
    done
    # Only the rows, and of each row only its throughput, in GB/s, for
    # benchstat. An arm with no rows yet is left out.
    files=()
    for arm in "${arms[@]}"; do
        [ -s "$out/raw-$arm.txt" ] || continue
        awk '/^Benchmark/ { for (i = 3; i < NF; i += 2) if ($(i + 1) == "MB/s") printf "%s\t%s\t%.4f GB/s\n", $1, $2, $i / 1000 }' \
            "$out/raw-$arm.txt" > "$out/$arm.txt"
        files+=("$arm=$out/$arm.txt")
    done
    benchstat "${files[@]}" > "$out/benchstat.txt"
    echo "benchstat: $out/benchstat.txt"
    echo
    just bench-summary "$out" | tee "$out/summary.txt"

[doc("Summarize a bench-compare run in DIR: per operation, utf's geomean throughput against each arm's, and each row's ratio with its interval into DIR/rows.txt")]
[group("bench")]
bench-summary DIR="zig-out/bench-compare":
    #!/usr/bin/env bash
    set -euo pipefail
    files=()
    for arm in utf simdutf base std rust go; do
        [ -s "{{ DIR }}/$arm.txt" ] && files+=("{{ DIR }}/$arm.txt")
    done
    : > "{{ DIR }}/rows.txt"
    awk -v rows="{{ DIR }}/rows.txt" -f bench/summary.awk "${files[@]}"

[doc("Build the simdutf oracle, zig-out/bin/utf-oracle, which tests and fuzzers drive through bench/oracle/Oracle.zig")]
[group("bench")]
oracle-build:
    mkdir -p zig-out/bin
    c++ -O2 -std=c++20 -o zig-out/bin/utf-oracle bench/oracle/oracle.cpp \
        $(pkg-config --cflags --libs simdutf) -Wl,-rpath,"$(pkg-config --variable=libdir simdutf)"

[doc("Compare this package's results with simdutf's on N random and adversarial inputs (default 1000000), under simdutf's best kernel and its scalar fallback, with this package built for cpu: `just cpu=baseline oracle` checks the dispatched build")]
[group("bench")]
oracle N="1000000" SEED="1": oracle-build
    cd bench && zig build -p ../zig-out -Dcpu={{ cpu }}
    zig-out/bin/oracle-compare {{ N }} {{ SEED }}
    SIMDUTF_FORCE_IMPLEMENTATION=fallback zig-out/bin/oracle-compare {{ N }} {{ SEED }}
