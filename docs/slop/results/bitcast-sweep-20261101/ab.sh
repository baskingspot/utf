#!/usr/bin/env bash
# Interleaved A/B over every row the arms have, the harness's method: each
# arm a `serve` process on the last core, each row timed on every arm back to
# back in an order that rotates by row and round, fresh processes each round,
# round 0 sizing the loops and discarded. Run from the repository root.
#   BIN=dir ARMS="a b c" OUT=dir ab.sh [OP...]
set -euo pipefail
rounds=${ROUNDS:-6}
bin=${BIN:?directory holding bench-<arm>}
read -ra arms <<<"${ARMS:?arm names}"
out=${OUT:?output directory}
rm -rf "$out" && mkdir -p "$out"
export BENCHTIME_MS=${BENCHTIME_MS:-20}
core=$(($(nproc) - 1))
declare -A to from iters arg_of
while IFS=$'\t' read -r arg row _; do arg_of[$row]=$arg; done < <(grep -v '^#' bench/ops.tsv)
"$bin/bench-${arms[0]}" check "$@" >"$out/check.txt"
mapfile -t rows < <(grep -v '^#' "$out/check.txt" | cut -f1)
for arm in "${arms[@]:1}"; do
	"$bin/bench-$arm" check "$@" | grep -v '^#' | diff -q - <(grep -v '^#' "$out/check.txt") >/dev/null ||
		{ echo "checksums differ: $arm"; exit 1; }
done
fifos=$(mktemp -d)
start() {
	for arm in "${arms[@]}"; do
		mkfifo "$fifos/$arm.in" "$fifos/$arm.out"
		taskset -c "$core" "$bin/bench-$arm" serve <"$fifos/$arm.in" >"$fifos/$arm.out" 2>>"$out/stderr-$arm.txt" &
		exec {fd}>"$fifos/$arm.in"
		to[$arm]=$fd
		exec {fd}<"$fifos/$arm.out"
		from[$arm]=$fd
	done
}
stop() {
	for arm in "${arms[@]}"; do eval "exec ${to[$arm]}>&-"; done
	wait
	for arm in "${arms[@]}"; do eval "exec ${from[$arm]}<&-"; done
	rm -f "$fifos"/*
}
for round in $(seq 0 "$rounds"); do
	start
	j=0
	for row in "${rows[@]}"; do
		arg=${arg_of[${row%%/*}]}
		input=${row#*/}
		for i in "${!arms[@]}"; do
			arm=${arms[$(((round + j + i) % ${#arms[@]}))]}
			printf '%s %s %s\n' "$arg" "$input" "${iters[$arm/$row]:-0}" >&"${to[$arm]}"
			IFS= read -r line <&"${from[$arm]}"
			if [ "$round" = 0 ]; then
				IFS=$'\t' read -r _ n _ <<<"$line"
				iters[$arm/$row]=$n
			else
				echo "$line" >>"$out/raw-$arm.txt"
			fi
		done
		j=$((j + 1))
	done
	stop
	echo "round $round done $(date +%T)"
done
rm -rf "$fifos"
for arm in "${arms[@]}"; do
	awk '/^Benchmark/ { printf "%s\t%s\t%s ns/op\n", $1, $2, $3 }' "$out/raw-$arm.txt" >"$out/$arm.txt"
done
