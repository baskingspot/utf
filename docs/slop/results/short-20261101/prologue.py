#!/usr/bin/env python3
"""prologue.py BINARY [PATTERN]: for each exported tier kernel (utf_*_<tier>_*)
and each native kernel symbol matching PATTERN, the callee-saved pushes and
stack adjustments before the first branch, from objdump -d."""
import re
import subprocess
import sys

binary = sys.argv[1]
pat = re.compile(sys.argv[2] if len(sys.argv) > 2 else r"^utf_[0-9a-f]+_(avx512|avx2|sse)_")
out = subprocess.run(["objdump", "-d", "--no-show-raw-insn", binary], capture_output=True, text=True).stdout
rows = []
for m in re.finditer(r"^[0-9a-f]+ <([^>]+)>:\n((?:\s+[0-9a-f]+:.*\n)+)", out, re.M):
    name, body = m.group(1), m.group(2)
    if not pat.search(name):
        continue
    pushes = []
    sub = ""
    first = ""
    n = 0
    for line in body.splitlines():
        ins = line.split(":", 1)[1].strip()
        op = ins.split()[0] if ins else ""
        if op.startswith("j") or op.startswith("ret") or op.startswith("call"):
            first = ins
            break
        n += 1
        if op == "push":
            pushes.append(ins.split()[1])
        if op == "sub" and "%rsp" in ins:
            sub = ins
    rows.append((name, len(pushes), " ".join(pushes), sub, n))
for name, k, regs, sub, n in sorted(rows):
    short = re.sub(r"^utf_[0-9a-f]+_", "", name)
    print(f"{short:60s} {k} {regs:40s} {sub} (+{n} before branch)")
