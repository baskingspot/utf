# The summary at the end of `just bench-compare` (bench/README.md): for each
# operation, this package's throughput against each other arm's, as the
# geometric mean over the operation's inputs of utf's median GB/s divided
# by the arm's, on the inputs both have. Above 1, utf is faster. The last
# column is utf's slowest input against the first other arm, simdutf.
#
#     awk -f bench/summary.awk DIR/utf.txt DIR/simdutf.txt DIR/std.txt ...
#
# The first file is utf's; each holds `Benchmark<Row>/<input> <n> <GB/s> GB/s`
# lines, one per round, as `just bench-compare` writes them.

FNR == 1 {
    arm = FILENAME
    sub(/.*\//, "", arm)
    sub(/\.txt$/, "", arm)
    arms[++narms] = arm
}

/^Benchmark/ {
    row = $1
    sub(/^Benchmark/, "", row)
    op = row
    sub(/\/.*/, "", op)
    if (!(op in seen)) {
        seen[op] = 1
        ops[++nops] = op
    }
    if (!((op, row) in has_row)) {
        has_row[op, row] = 1
        rows[op, ++nrows[op]] = row
    }
    k = arm SUBSEP row
    v[k, ++n[k]] = $3
}

function median(k,    i, j, t, m, a) {
    m = n[k]
    for (i = 1; i <= m; i++) a[i] = v[k, i] + 0
    for (i = 2; i <= m; i++) {
        t = a[i]
        for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]
        a[j + 1] = t
    }
    return m % 2 ? a[(m + 1) / 2] : (a[m / 2] + a[m / 2 + 1]) / 2
}

function ratio(x) {
    return x == "" ? "-" : sprintf("%.2f", x)
}

END {
    if (narms < 2) exit
    ref = arms[1]
    printf "%-24s %5s %9s", "utf/arm, geomean", "rows", "utf GB/s"
    for (a = 2; a <= narms; a++) printf " %8s", arms[a]
    printf "   %s\n", "slowest vs " arms[2]
    for (i = 1; i <= nops; i++) {
        op = ops[i]
        own = 0; nown = 0
        delete logsum; delete nshared
        worst = ""; worst_row = ""
        for (r = 1; r <= nrows[op]; r++) {
            row = rows[op, r]
            if (!((ref, row) in n)) continue
            u = median(ref SUBSEP row)
            own += log(u); nown++
            for (a = 2; a <= narms; a++) {
                k = arms[a] SUBSEP row
                if (!(k in n)) continue
                q = u / median(k)
                logsum[a] += log(q); nshared[a]++
                all_logsum[a] += log(q); all_n[a]++
                if (a == 2 && (worst == "" || q < worst)) {
                    worst = q
                    worst_row = row
                    sub(/^[^\/]*\//, "", worst_row)
                }
            }
        }
        if (nown == 0) continue
        all_own += own; all_nown += nown
        printf "%-24s %5d %9.2f", op, nown, exp(own / nown)
        for (a = 2; a <= narms; a++) printf " %8s", ratio(nshared[a] ? exp(logsum[a] / nshared[a]) : "")
        printf "   %s\n", worst == "" ? "-" : sprintf("%.2f %s", worst, worst_row)
    }
    printf "%-24s %5d %9.2f", "all", all_nown, all_nown ? exp(all_own / all_nown) : 0
    for (a = 2; a <= narms; a++) printf " %8s", ratio(all_n[a] ? exp(all_logsum[a] / all_n[a]) : "")
    printf "\n"
}
