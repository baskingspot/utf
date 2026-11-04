#!/usr/bin/env python3
"""samecode.py A B: compares the tier kernels (utf_<hash>_<isa>_*) of two
binaries, matched by name without the hash, by their disassembly with
addresses masked (placement aside): how many match, and the first that does not."""
import subprocess, sys, re
def syms(b):
    out = subprocess.run(['nm', '-S', b], capture_output=True, text=True).stdout
    r = {}
    for l in out.splitlines():
        f = l.split()
        if len(f) == 4 and f[2] in 'tT' and re.match(r'utf_[0-9a-f]+_(avx512|avx2|sse)_', f[3]):
            r[re.sub(r'^utf_[0-9a-f]+_', '', f[3])] = (int(f[0], 16), int(f[1], 16))
    return r
def code(b, a, s):
    d = subprocess.run(['objdump', '-d', '--no-show-raw-insn', f'--start-address={a}', f'--stop-address={a + s}', b], capture_output=True, text=True).stdout
    return [re.sub(r'0x[0-9a-f]+|\b[0-9a-f]{5,}\b', 'X', re.sub(r'<[^>]*>', '', l.split('\t', 1)[-1].split('#')[0])) for l in d.splitlines() if l.startswith(' ')]
A, B = syms(sys.argv[1]), syms(sys.argv[2])
same = diff = 0
for n in sorted(set(A) & set(B)):
    if A[n][1] == B[n][1] and code(sys.argv[1], *A[n]) == code(sys.argv[2], *B[n]): same += 1
    else:
        diff += 1
        if diff <= 3: print('differs:', n, A[n][1], B[n][1], hex(A[n][0] % 64), hex(B[n][0] % 64))
print(f'{same} same, {diff} differ, {len(set(A) ^ set(B))} in one only')
