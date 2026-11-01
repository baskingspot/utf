#!/usr/bin/env bash
# Interleaved A/B: each row timed by every arm back to back, order rotating
# by row and round, all arms pinned to one core, round 0 sizes the loops.
set -euo pipefail
rounds=${ROUNDS:-10}
bin=${BIN:?directory holding bench-simdutf, bench-main, bench-before, bench-after}
out=${OUT:-ab}
rm -rf "$out" && mkdir -p "$out"
arms=(simdutf main before after)
ops=(utf8-to-utf32 valid-utf8-to-utf32 utf8-to-utf16le)
inputs=(mix-16 mix-64 mix-254 mix-4095 mix-65536 emoji chinese hindi latin ascii-64 ascii-4096)
export BENCHTIME_MS=${BENCHTIME_MS:-50}
export SIMDUTF_FORCE_IMPLEMENTATION=haswell
core=$(($(nproc) - 1))
declare -A to from iters
fifos=$(mktemp -d)
start() {
	for arm in "${arms[@]}"; do
		mkfifo "$fifos/$arm.in" "$fifos/$arm.out"
		taskset -c "$core" "$bin"/bench-$arm serve <"$fifos/$arm.in" >"$fifos/$arm.out" 2>>"$out/stderr-$arm.txt" &
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
	for op in "${ops[@]}"; do
		for input in "${inputs[@]}"; do
			for i in "${!arms[@]}"; do
				arm=${arms[$(((round + j + i) % ${#arms[@]}))]}
				n=${iters[$arm/$op/$input]:-0}
				printf '%s %s %s\n' "$op" "$input" "$n" >&"${to[$arm]}"
				IFS= read -r line <&"${from[$arm]}"
				if [ "$round" = 0 ]; then
					IFS=$'\t' read -r _ n _ <<<"$line"
					iters[$arm/$op/$input]=$n
				else
					echo "$line" >>"$out/$arm.txt"
				fi
			done
			j=$((j + 1))
		done
	done
	stop
done
rm -rf "$fifos"
