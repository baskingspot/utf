#!/usr/bin/env bash
# `check` on inputs with errors, old harness against new: every checked
# conversion reads its form's -err directory (to-Latin-1 ones the non-Latin-1
# text), and each base64 decode reads text it rejects, through a copy of
# bench/ops.tsv in a scratch root that links the corpus. Usage, from the
# repository root: errcheck.sh OLD_BIN NEW_BIN (bench-utf or bench-std builds).
set -euo pipefail
root=$(mktemp -d); mkdir -p "$root/bench"
ln -s "$PWD/bench/corpus-gen" "$root/bench/corpus-gen"
awk -F'\t' 'BEGIN { OFS = "\t" } /^#/ { print; next } { d = $3 }
$1 ~ /-to-/ && $1 !~ /^(latin1|valid)-/ { sub(/^latin1-as-/, "", d); if (d !~ /-err$/) d = d "-err" }
$1 == "base64-decode" || $1 == "base64-decode-mime" { d = "base64url" }
$1 == "base64-decode-url" { d = "base64" }
$1 == "base64-decode-strict" { d = "base64-unpadded" }
$1 == "base64-decode-partial" { d = "base64-mime" }
{ $3 = d; print }' bench/ops.tsv > "$root/bench/ops.tsv"
old=$(realpath "$1"); new=$(realpath "$2")
(cd "$root" && "$old" check > old.txt && "$new" check > new.txt)
cmp "$root/old.txt" "$root/new.txt"
echo "identical: $(wc -l < "$root/new.txt") rows, $(grep -c valid=false "$root/new.txt") of them valid=false"
