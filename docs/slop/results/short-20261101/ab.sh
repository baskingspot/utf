#!/usr/bin/env bash
# ab.sh NAME ROUNDS "OPS..." ARM...: the harness's paired rounds with any arms.
# Each ARM is a name of a build in out/h-<name>/bin/bench-utf, or
# simdutf:<kernel> for simdutf's arm with that kernel. Every arm is a server
# pinned to CPU 3; each row is timed on every arm back to back, in an order
# that rotates from row to row and round to round; each round starts fresh
# processes; round 0 sizes the loops and is discarded. Writes raw/NAME/<arm>.txt
# (GB/s per round) and summary.txt from bench/summary.awk with the first arm
# first. Run from anywhere; the arms run from the repository root.
set -euo pipefail
source ~/.nix-profile/etc/profile.d/nix.sh
ab=/home/user/ab
repo=/home/user/workspace/repo
name=$1; rounds=$2; ops=($3); shift 3
arms=("$@")
out=$ab/raw/$name
rm -rf "$out" && mkdir -p "$out"
export BENCHTIME_MS="${BENCHTIME_MS:-50}"
cd "$repo"
bin() {
    if [[ $1 == simdutf:* ]]; then echo "$ab/bench-simdutf"; else echo "$ab/out/h-$1/bin/bench-utf"; fi
}
envof() {
    if [[ $1 == simdutf:* ]]; then echo "SIMDUTF_FORCE_IMPLEMENTATION=${1#simdutf:}"; else echo "X=1"; fi
}
fname() { echo "${1/:/-}"; }
# Rows from the first simdutf arm's (or first arm's) check output.
"$(bin "${arms[0]}")" check "${ops[@]}" | grep -v '^#' | cut -f1 | grep -E "${ROWS:-.}" > "$out/rows"
declare -A arg_of iters to from
while IFS=$'\t' read -r arg row _; do arg_of[$row]=$arg; done < <(grep -v '^#' bench/ops.tsv)
mapfile -t rows < "$out/rows"
fifos=$(mktemp -d)
trap 'rm -rf "$fifos"' EXIT
taskset -cp 0 $$ > /dev/null
start() {
    for a in "${arms[@]}"; do
        f=$(fname "$a")
        mkfifo "$fifos/$f.in" "$fifos/$f.out"
        env $(envof "$a") taskset -c 3 "$(bin "$a")" serve < "$fifos/$f.in" > "$fifos/$f.out" 2>> "$out/stderr-$f.txt" &
        exec {fd}> "$fifos/$f.in"; to[$a]=$fd
        exec {fd}< "$fifos/$f.out"; from[$a]=$fd
    done
}
stop() {
    for a in "${arms[@]}"; do eval "exec ${to[$a]}>&-"; done
    wait
    for a in "${arms[@]}"; do eval "exec ${from[$a]}<&-"; done
    rm -f "$fifos"/*
}
sample() {
    printf '%s %s %s\n' "$2" "$3" "$4" >&"${to[$1]}"
    if ! IFS= read -r line <&"${from[$1]}" || [[ $line != Benchmark* ]]; then
        echo "$1 failed on $2 $3: $line"; exit 1
    fi
}
for round in $(seq 0 "$rounds"); do
    start
    j=0
    for row in "${rows[@]}"; do
        arg=${arg_of[${row%%/*}]}
        input=${row#*/}
        for i in "${!arms[@]}"; do
            a=${arms[$(( (round + j + i) % ${#arms[@]} ))]}
            if [ "$round" = 0 ]; then
                sample "$a" "$arg" "$input" 0
                IFS=$'\t' read -r _ n _ <<< "$line"
                iters[$a/$row]=$n
            else
                sample "$a" "$arg" "$input" "${iters[$a/$row]}"
                echo "$line" >> "$out/raw-$(fname "$a").txt"
            fi
        done
        j=$(( j + 1 ))
    done
    stop
done
files=()
for a in "${arms[@]}"; do
    f=$(fname "$a")
    awk '/^Benchmark/ { for (i = 3; i < NF; i += 2) if ($(i + 1) == "MB/s") printf "%s\t%s\t%.4f GB/s\n", $1, $2, $i / 1000 }' \
        "$out/raw-$f.txt" > "$out/$f.txt"
    files+=("$out/$f.txt")
done
: > "$out/rows.txt"
awk -v rows="$out/rows.txt" -f bench/summary.awk "${files[@]}" > "$out/summary.txt"
cat "$out/summary.txt"
