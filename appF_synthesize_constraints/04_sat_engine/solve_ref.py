#!/usr/bin/env python3
"""04_sat_engine POC(1) reference: enumerate the exact legal set so we can cross-check
the RTL engine's soundness (every emitted sample must be in this set) and coverage
(over many seeds it should reach all of it).

Constraint: v0..v4 in [1,9], all-different, sum==25, v0<v1.
"""
from itertools import permutations

sols = set()
for p in permutations(range(1, 10), 5):
    if sum(p) == 25 and len(set(p)) == 5 and p[0] < p[1]:
        sols.add(p)

print(f"exact legal solutions (all-different, sum==25, v0<v1): {len(sols)}")
# the underlying unordered 5-subsets summing to 25 (the 'combinations' before v0<v1 / perm)
subsets = set(tuple(sorted(s)) for s in sols)
print(f"underlying distinct 5-subsets of [1,9] summing to 25: {len(subsets)}")
codes = sorted(((((a*10+b)*10+c)*10+d)*10+e) for (a, b, c, d, e) in sols)
print(f"min code={codes[0]}  max code={codes[-1]}")
