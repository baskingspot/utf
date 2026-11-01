#!/usr/bin/env bash
# Paired A/B over any arms, as `just bench-compare` times its rows: every arm
# a `serve` process pinned to the last core, each row timed on every arm back
# to back in an order that rotates by row and round, fresh processes every
# round, round 0 sizing the loops and discarded.
#
#   ab.sh OUT ROUNDS ROWREGEX "OPS..." NAME=BIN...
#
# Run from the repository root (bench/ops.tsv and the corpus). ROWREGEX picks
# rows by name (for example '-(16|64)$'). The first arm names the row list
# (its `check` output). Writes OUT/<name>.txt (GB/s, one line a round) and
# OUT/raw-<name>.txt.
set -euo pipefail
out=$1 rounds=$2 rowre=$3 ops=$4
shift 4
names=() bins=()
for a in "$@"; do names+=("${a%%=*}"); bins+=("${a#*=}"); done
mkdir -p "$out"
export BENCHTIME_MS="${BENCHTIME_MS:-50}"
core=$(( $(nproc) - 1 ))
declare -A arg_of has iters to from
while IFS=$'\t' read -r arg row _; do arg_of[$row]=$arg; done < <(grep -v '^#' bench/ops.tsv)
for i in "${!names[@]}"; do
    # shellcheck disable=SC2086
    "${bins[$i]}" check $ops > "$out/check-${names[$i]}.txt" 2>/dev/null
    while IFS=$'\t' read -r row _; do has[${names[$i]}/$row]=1; done < <(grep -v '^#' "$out/check-${names[$i]}.txt")
    : > "$out/raw-${names[$i]}.txt"
done
mapfile -t rows < <(grep -v '^#' "$out/check-${names[0]}.txt" | cut -f1 | grep -E -- "$rowre")
fifos=$(mktemp -d)
trap 'rm -rf "$fifos"' EXIT
start() {
    for i in "${!names[@]}"; do
        n=${names[$i]}
        mkfifo "$fifos/$n.in" "$fifos/$n.out"
        taskset -c "$core" "${bins[$i]}" serve < "$fifos/$n.in" > "$fifos/$n.out" 2>> "$out/stderr-$n.txt" &
        exec {fd}> "$fifos/$n.in"; to[$n]=$fd
        exec {fd}< "$fifos/$n.out"; from[$n]=$fd
    done
}
stop() {
    for n in "${names[@]}"; do eval "exec ${to[$n]}>&-"; done
    wait
    for n in "${names[@]}"; do eval "exec ${from[$n]}<&-"; done
    rm -f "$fifos"/*
}
sample() {
    printf '%s %s %s\n' "$2" "$3" "$4" >&"${to[$1]}"
    if ! IFS= read -r line <&"${from[$1]}" || [[ $line != Benchmark* ]]; then
        echo "$1 failed on $2 $3: $line"; exit 1
    fi
}
taskset -cp 0 $$ > /dev/null
for round in $(seq 0 "$rounds"); do
    start
    j=0
    for row in "${rows[@]}"; do
        arg=${arg_of[${row%%/*}]}
        input=${row#*/}
        present=()
        for n in "${names[@]}"; do [ -n "${has[$n/$row]:-}" ] && present+=("$n"); done
        for i in "${!present[@]}"; do
            n=${present[$(( (round + j + i) % ${#present[@]} ))]}
            if [ "$round" = 0 ]; then
                sample "$n" "$arg" "$input" 0
                IFS=$'\t' read -r _ it _ <<< "$line"
                iters[$n/$row]=$it
            else
                sample "$n" "$arg" "$input" "${iters[$n/$row]}"
                echo "$line" >> "$out/raw-$n.txt"
            fi
        done
        j=$(( j + 1 ))
    done
    stop
    echo "round $round of $rounds done at $(date +%T)" >&2
done
for n in "${names[@]}"; do
    awk '/^Benchmark/ { for (i = 3; i < NF; i += 2) if ($(i + 1) == "MB/s") printf "%s\t%s\t%.4f GB/s\n", $1, $2, $i / 1000 }' \
        "$out/raw-$n.txt" > "$out/$n.txt"
done
