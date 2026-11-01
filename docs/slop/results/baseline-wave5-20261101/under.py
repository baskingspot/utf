"""under.py: the tables of operations under simdutf at each level, with the
reason for each, from this directory and baseline-final-20261031/."""
import re
from pathlib import Path
R=str(Path(__file__).resolve().parent.parent)+'/'
O,N=R+'baseline-final-20261031/',R+'baseline-wave5-20261101/'
LEN={'Utf16FromUtf8','Utf16FromUtf32','Utf8FromUtf16le','Utf8FromUtf16be','Utf8FromUtf32','Utf8FromLatin1','CountUtf8','CountUtf16le','CountUtf16be'}
def summ(p):
    d={}
    for l in open(p).read().splitlines()[1:]:
        f=l.split()
        if f and f[0]!='all' and f[3]!='-': d[f[0]]=float(f[3])
    return d
def rows(p):
    d={}
    for l in open(p):
        f=l.split()
        if len(f)>=8 and f[1]=='simdutf' and f[7]=='<':
            op,row=f[0].split('/'); d.setdefault(op,[]).append((row,float(f[4])))
    return d
SHORT=re.compile(r'-(16|64|256)$')
host='host: same loop as `66fa49c`, which reads the same here'
reasons={
 'native':{
  **{k:host for k in LEN},
  'ValidUtf16leToUtf16be':'short rows; code as `39088d1`; unexplained (harness loop suspected)',
  'ValidUtf16beToUtf16le':'short rows; code as `39088d1`; unexplained (harness loop suspected)',
  'Latin1ToUtf16le':'short rows: harness loop (measured, 3 ns a call)',
  'ValidLatin1ToUtf16le':'short rows; harness loop suspected (measured on the checked form)',
  'Latin1ToUtf16be':'short rows; harness loop suspected (measured on UTF-16LE)',
  'ValidLatin1ToUtf16be':'short rows; harness loop suspected (measured on UTF-16LE)',
  'Latin1ToUtf32':'short rows; harness loop suspected; host (0.99 of `icelake` in `host/len2`, where `66fa49c` reads the same)',
  'ValidLatin1ToUtf32':'short rows; harness loop suspected; long rows 0.96–0.99',
  'Utf16leToLatin1':'layout and noise: code as `39088d1`, 1.01 of `icelake` in `host/len2`',
 },
 'westmere':{'Utf8FromLatin1':'three 64-byte rows; unexplained (harness loop suspected)'},
 'baseline':{
  **{k:host+' (the tier object runs it)' for k in LEN},
  'Utf16FromUtf32':'layout and host: its loop is instruction for instruction `66fa49c`\'s, which reads 1.09× here (`host/len4`); native 1.02',
  'ValidateAsciiErr':'unexplained: unchanged since `baseline-final` (0.87), `ascii-4096` 0.76',
  'Latin1ToUtf8':'no row under beyond its interval',
  'Base64Encode':'no row under beyond its interval',
  'ValidLatin1ToUtf16be':'short rows: dispatched call plus harness loop; long rows 0.99',
  'Latin1ToUtf32':'short rows: dispatched call plus harness loop; long row 0.98',
  'ValidLatin1ToUtf32':'short rows: dispatched call plus harness loop; long row 0.96',
  'Base64EncodeUrl':'short rows: dispatched call plus harness loop; `random-1048576` 0.97',
 },
}
SHORTDISP='short rows only: dispatched call plus harness loop (measured on Latin-1 to UTF-8 and UTF-16LE)'
for lv in ['native','westmere','baseline','safe']:
    o,n,r=summ(O+lv+'/summary.txt'),summ(N+lv+'/summary.txt'),rows(N+lv+'/rows.txt')
    nat=summ(N+'native/summary.txt')
    under=sorted([k for k in n if n[k]<1],key=n.get)
    print(f'\n### {lv}: {len(under)}\n')
    if lv=='safe':
        print('| op | wave 5 | baseline-final | native ReleaseFast | rows under (short, long) | reason |')
        print('| --- | ---: | ---: | ---: | ---: | --- |')
    else:
        print('| op | wave 5 | baseline-final | rows under (short, long) | slowest | reason |')
        print('| --- | ---: | ---: | ---: | --- | --- |')
    for k in under:
        rs=r.get(k,[]); s=sum(1 for x,_ in rs if SHORT.search(x)); l=len(rs)-s
        slow=min(rs,key=lambda x:x[1]) if rs else None
        if lv=='safe':
            why='safety checks (decision 5)'+('; host, as native' if k in LEN and nat[k]<1 else '; also under in native' if nat[k]<1 else '')
            print(f'| {k} | {n[k]:.2f} | {o.get(k,0):.2f} | {nat[k]:.2f} | {s}, {l} | {why} |')
        else:
            why=reasons[lv].get(k) or (SHORTDISP if l==0 else '?')
            sl=f'`{slow[0]}` {slow[1]:.2f}' if slow else '-'
            print(f'| {k} | {n[k]:.2f} | {o.get(k,0):.2f} | {s}, {l} | {sl} | {why} |')
