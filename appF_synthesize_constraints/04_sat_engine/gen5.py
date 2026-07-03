#!/usr/bin/env python3
"""PLANTED 3-colouring generator for the wide engine. Assign each node a random colour,
then add M edges only between differently-coloured nodes -> the planted colouring is a
valid 3-colouring by construction (SAT guaranteed). At the right density this is hard even
with full unit propagation. Emits nbr.hex ($readmemh adjacency, N 64-bit masks), plus the
edge list and the planted colouring (the SAT certificate). LCG uses high bits."""
import sys
N = 64
M    = int(sys.argv[1]) if len(sys.argv) > 1 else 150   # edges (~density knob)
seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1

class LCG:
    def __init__(s,x): s.s = x & 0x7fffffff
    def r(s,n):
        s.s = (s.s*1103515245 + 12345) & 0x7fffffff
        return (s.s >> 10) % n

r = LCG(seed)
col = [1 + r.r(3) for _ in range(N)]            # the planted colouring (1..3)
E = set()
guard = 0
while len(E) < M and guard < M*100:
    guard += 1
    a = r.r(N); b = r.r(N)
    if a != b and col[a] != col[b]:
        E.add((min(a,b), max(a,b)))
E = sorted(E)
A = [set() for _ in range(N)]
for u,v in E: A[u].add(v); A[v].add(u)
masks = [sum(1 << j for j in A[i]) for i in range(N)]

with open("nbr.hex","w") as f:
    for i in range(N):
        f.write(f"{masks[i]:016x}\n")            # 64-bit mask, 16 hex digits

degs = sorted((len(A[i]) for i in range(N)), reverse=True)
# verify planted colouring is proper (sanity)
ok = all(col[u] != col[v] for (u,v) in E)
print(f"// PLANTED 3-col: N={N} M={len(E)} seed={seed} avgdeg={2*len(E)/N:.2f} planted-proper={ok}")
print(f"// (nbr.hex written; SAT by construction). degrees max={degs[0]} min={degs[-1]}")
print("E0='{"+",".join(str(u) for u,v in E)+"};")
print("E1='{"+",".join(str(v) for u,v in E)+"};")
print(f"NE={len(E)}")
