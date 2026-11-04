import subprocess, sys
def sections(path):
    out = subprocess.run(['readelf','-SW',path],capture_output=True,text=True).stdout
    res=[]
    for line in out.splitlines():
        if not line.strip().startswith('[') or ']' not in line: continue
        parts=line.split(']',1)[1].split()
        try: res.append((parts[0],int(parts[3],16),int(parts[4],16)))
        except (ValueError,IndexError): pass
    return res
binp=sys.argv[1]; objs=sys.argv[2:]
data=open(binp,'rb').read()
ro=[s for s in sections(binp) if s[0]=='.rodata'][0]
rod=data[ro[1]:ro[1]+ro[2]]
covered=bytearray(len(rod)); tot={}
for f in objs:
    od=open(f,'rb').read()
    for name,off,size in sorted(sections(f),key=lambda s:-s[2]):
        if 'rodata' not in name or size<128: continue
        blob=od[off:off+size]; i=rod.find(blob)
        while i>=0 and any(covered[i:i+size]): i=rod.find(blob,i+1)
        if i>=0:
            covered[i:i+size]=b'\1'*size; tot[f.split('/')[-1]]=tot.get(f.split('/')[-1],0)+size
            print(f.split('/')[-1],name,size)
print(tot,'covered',sum(covered),'of',len(rod))
