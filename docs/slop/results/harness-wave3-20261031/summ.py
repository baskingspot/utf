# Summarizes rows.py output by group and input size: rows-native.txt rows-v3.txt.
import sys, math, re
def load(fn):
    rows = []
    for l in open(fn).readlines()[1:]:
        t = l.split()
        rows.append((t[0], int(t[1]), float(t[2]), float(t[3])))
    return rows
groups = {
 "validate *Err": lambda r: r.startswith("Validate") and r.split("/")[0].endswith("Err"),
 "checked conversions": lambda r: re.match(r"(Utf8|Utf16le|Utf16be|Utf32|Latin1)To", r) is not None,
 "base64 decode": lambda r: r.startswith("Base64"),
 "controls (validate-utf8, valid forms)": lambda r: r.startswith("ValidateUtf8/") or (r.startswith("Valid") and not r.startswith("Validate")),
}
bands = [("16-64 B inputs", lambda n, b: n.split("/")[1].endswith("-16") or n.split("/")[1].endswith("-64")),
         ("256 B", lambda n, b: n.split("/")[1].endswith("-256")),
         ("4 KiB and up, texts", lambda n, b: not re.search(r"-(16|64|256)$", n))]
for fn in sys.argv[1:]:
    rows = load(fn)
    print(fn)
    for g, gf in groups.items():
        for bn, bf in bands:
            sel = [r for r in rows if gf(r[0]) and bf(r[0], r[1])]
            if not sel: continue
            d = [r[3] - r[2] for r in sel]; q = [r[3] / r[2] for r in sel]
            gm = math.exp(sum(map(math.log, q)) / len(q))
            print(f"  {g:40} {bn:22} n={len(sel):3d}  delta ns {min(d):+6.2f}..{max(d):+6.2f} median {sorted(d)[len(d)//2]:+6.2f}  new/old geomean {gm:.3f} range {min(q):.2f}..{max(q):.2f}")
