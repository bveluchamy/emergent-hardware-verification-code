#!/usr/bin/env python3
"""04_sat_engine POC(3) reference: legal set WITH the nonlinear product constraint.
v0..v4 in [1,9], all-different, sum==25, v0<v1, v2*v3 < PLIMIT."""
import sys
from itertools import permutations

PLIMIT = int(sys.argv[1]) if len(sys.argv) > 1 else 20
sols = set()
for p in permutations(range(1, 10), 5):
    if (sum(p) == 25 and len(set(p)) == 5 and p[0] < p[1] and p[2]*p[3] < PLIMIT):
        sols.add(p)
print(f"PLIMIT={PLIMIT}: legal solutions (sum25, v0<v1, v2*v3<PLIMIT) = {len(sols)}")
# how many the product constraint removed vs POC(1)'s 720
base = sum(1 for p in permutations(range(1,10),5) if sum(p)==25 and len(set(p))==5 and p[0]<p[1])
print(f"  (POC(1) without product: {base}; product removed {base-len(sols)})")
