# gdb -batch -x trace.py --args BIN ARGS... ; env SYM=<symbol regex>
# Steps one call of the first function matching SYM to its return and
# prints each executed instruction (function+offset and text) to stdout.
import os
import gdb

sym = os.environ["SYM"]
gdb.execute("set pagination off")
gdb.execute("set confirm off")
gdb.execute(f"break *{sym}")
gdb.execute("run")
frame = gdb.selected_frame()
sp0 = int(gdb.parse_and_eval("$sp"))
out = []
n = 0
while True:
    pc = int(gdb.parse_and_eval("$pc"))
    ins = gdb.execute(f"x/i {pc}", to_string=True).strip()
    ins = ins.replace("=> ", "")
    out.append(ins)
    n += 1
    if ins.split(":", 1)[-1].split() and ins.split(":", 1)[-1].split()[0] == "ret" and int(gdb.parse_and_eval("$sp")) == sp0:
        break
    gdb.execute("stepi", to_string=True)
    if n > 20000:
        break
print("\n".join(out))
print(f"TOTAL {n}")
gdb.execute("kill")
