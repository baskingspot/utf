#!/usr/bin/env python3
"""Interleaved A/B over `serve` arms, the method of `just bench-compare`:
each arm a server pinned to one core (CORE, default 3), every row timed by
every arm back to back in an order that rotates by row and round, fresh
processes each round. Round 0 sizes each (arm, row) loop (request N=0) and
is discarded; later rounds run that many iterations.
usage: serve-ab.py OUTDIR ROUNDS ROWSFILE name=cmd ...
ROWSFILE: one request prefix per line; the server gets '<row> <N>'.
Writes OUTDIR/<name>.txt in the Go benchmark format, one line per round."""
import subprocess, sys, os
out, rounds, rowsfile = sys.argv[1], int(sys.argv[2]), sys.argv[3]
arms = [a.split('=', 1) for a in sys.argv[4:]]
rows = [l.strip() for l in open(rowsfile) if l.strip() and not l.startswith('#')]
os.makedirs(out, exist_ok=True)
files = {name: open(f'{out}/{name}.txt', 'w') for name, _ in arms}
core = os.environ.get('CORE', '3')
iters = {}
for r in range(rounds + 1):
    procs = {name: subprocess.Popen(['taskset', '-c', core] + cmd.split(), stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1) for name, cmd in arms}
    for j, row in enumerate(rows):
        present = list(range(len(arms)))
        for i in range(len(arms)):
            name, _ = arms[(r + j + i) % len(arms)]
            p = procs[name]
            n = iters.get((name, row), 0) if r > 0 else 0
            p.stdin.write(f'{row} {n}\n'); p.stdin.flush()
            line = p.stdout.readline()
            if not line.startswith('Benchmark'):
                sys.exit(f'{name} failed on {row}: {line!r}')
            if r == 0: iters[(name, row)] = int(line.split('\t')[1])
            else: files[name].write(line)
    for p in procs.values():
        p.stdin.close(); p.wait()
    for f in files.values(): f.flush()
    print(f'round {r} of {rounds} done', file=sys.stderr, flush=True)
