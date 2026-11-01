#!/usr/bin/env python3
"""samecode.py OLD NEW: compares two `calls` binaries function by function.

Disassembles both with objdump, drops addresses, RIP offsets, absolute
addresses, the package's symbol prefix, and the padding after each
function's last instruction, then counts the tier exports
(`utf_<prefix>_<isa>_...`) and the other functions in both whose
instructions are identical.
"""

import re
import subprocess
import sys


def funcs(path):
    out = subprocess.run(
        ["objdump", "-d", "--no-show-raw-insn", "--no-addresses", path],
        capture_output=True, text=True, check=True,
    ).stdout
    d, cur = {}, None
    for line in out.splitlines():
        m = re.match(r"^<(.*)>:", line)
        if m:
            cur = re.sub(r"utf_[0-9a-f]{8}_", "utf_P_", m.group(1))
            d[cur] = []
            continue
        line = re.sub(r"utf_[0-9a-f]{8}_", "utf_P_", line.strip())
        if cur is None or not line:
            continue
        line = re.sub(r"0x[0-9a-f]+\(%rip\)", "X(%rip)", line)
        line = re.sub(r"\$?0x[0-9a-f]{6,}", "A", line)
        line = re.sub(r"#.*", "", line).strip()
        d[cur].append(line)
    pad = ("int3", "nop", "cs nop", "data16", "xchg   %ax,%ax")
    for body in d.values():
        while body and body[-1].startswith(pad):
            body.pop()
    return d


old, new = funcs(sys.argv[1]), funcs(sys.argv[2])
both = [k for k in new if k in old]
tier = [k for k in both if re.match(r"utf_P_(avx512|avx2|sse)_", k)]
rest = [k for k in both if k not in tier]
for name, ks in (("tier exports", tier), ("other functions", rest)):
    same = sum(old[k] == new[k] for k in ks)
    print(f"{name}: {same} of {len(ks)} identical")
    for k in ks:
        if old[k] != new[k]:
            print("  differs:", k[:100])
