#!/usr/bin/env python3
"""fndiff.py BIN_A BIN_B [PATTERN]: for every symbol matching PATTERN in
both binaries, whether its instructions are the same once addresses and
symbol offsets are normalized, and each one's address mod 64."""
import re
import subprocess
import sys

pat = re.compile(sys.argv[3] if len(sys.argv) > 3 else r"^utf_[0-9a-f]+_avx512_")


def funcs(binary):
    out = subprocess.run(["objdump", "-d", "--no-show-raw-insn", binary], capture_output=True, text=True).stdout
    res = {}
    for m in re.finditer(r"^([0-9a-f]+) <([^>]+)>:\n((?:\s+[0-9a-f]+:.*\n)+)", out, re.M):
        addr, name, body = int(m.group(1), 16), m.group(2), m.group(3)
        name = re.sub(r"utf_[0-9a-f]+_", "utf_", name)
        if not pat.search(name):
            continue
        ins = []
        for line in body.splitlines():
            i = line.split(":", 1)[1].strip()
            i = re.sub(r"#.*", "", i)
            i = re.sub(r"\b[0-9a-f]{6,}\b", "A", i)
            i = re.sub(r"<[^>]*>", "", i)
            i = re.sub(r"-?0x[0-9a-f]+\(%rip\)", "R(%rip)", i)
            ins.append(i.strip())
        res[name] = (addr, ins)
    return res


a, b = funcs(sys.argv[1]), funcs(sys.argv[2])
for name in sorted(set(a) & set(b)):
    (aa, ia), (ab, ib) = a[name], b[name]
    same = "same" if ia == ib else f"DIFF {len(ia)} vs {len(ib)}"
    print(f"{name:60s} {aa % 64:3d} {ab % 64:3d} {same}")
