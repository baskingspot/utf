import re, sys, collections

pat_dbg = re.compile(r'!dbg !(\d+)')
hits = collections.defaultdict(lambda: collections.defaultdict(int))
for path in sys.argv[1:]:
    target = path.rsplit('/', 1)[-1][:-3]
    meta = {}
    found = []
    prev = []
    with open(path) as f:
        for line in f:
            if line.startswith('!'):
                k, _, v = line.partition(' = ')
                meta[k[1:]] = v
                continue
            kind = None
            if re.search(r'= lshr i\d+ %[^,]+, %', line) and any('@llvm.assume' in p for p in prev[-3:]):
                kind = 'int loop'
            elif re.search(r'= shl nuw i(\d+) %[^,]+, %', line) and 'zext i' in prev[-1] and int(re.search(r'= shl nuw i(\d+)', line).group(1)) >= 64:
                kind = 'join loop'
            elif re.search(r'= extractelement <\d+ x [^>]+> %[^,]+, i64 %', line):
                kind = 'extract loop'
            if kind:
                d = pat_dbg.search(line)
                if d:
                    found.append((kind, d.group(1)))
            prev.append(line)
            if len(prev) > 4:
                prev.pop(0)

    def loc(i):
        v = meta.get(i, '')
        ln = re.search(r'line: (\d+)', v)
        s = re.search(r'scope: !(\d+)', v)
        s = s.group(1) if s else None
        while s:
            sv = meta.get(s, '')
            fm = re.search(r'file: !(\d+)', sv)
            if fm:
                name = re.search(r'filename: "([^"]+)"', meta.get(fm.group(1), ''))
                return (name.group(1) if name else '?') + ':' + (ln.group(1) if ln else '?')
            s = re.search(r'scope: !(\d+)', sv)
            s = s.group(1) if s else None
        return '?'

    for kind, d in found:
        hits[(loc(d), kind)][target] += 1

for (where, kind), t in sorted(hits.items()):
    if where.startswith('std/') or '/std/' in where:
        continue
    print(f'{where} [{kind}] ' + ', '.join(f'{k.removeprefix("dbg-")}' for k in sorted(t)))
