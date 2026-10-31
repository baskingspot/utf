#!/usr/bin/env bash
# Prints functions where a 16-byte load from memory is stored straight back:
# the Result copy.
objdump -d --no-show-raw-insn -M intel "$1" | awk '
/^[0-9a-f]+ <.*>:$/ { fn = $2; prev = ""; next }
{
  line = $0
  if (match(line, /v?movups +xmm[0-9]+,XMMWORD PTR \[/) || match(line, /v?movdqu +xmm[0-9]+,XMMWORD PTR \[r[bs]p/)) { prev = line; pc = 0; next }
  if (prev != "" && match(line, /v?mov(ups|dqu|aps) +XMMWORD PTR \[[a-z0-9]+\],xmm/)) { print fn; print "   " prev; print "   " line; prev = "" }
  if (++pc > 3) prev = ""
}'
