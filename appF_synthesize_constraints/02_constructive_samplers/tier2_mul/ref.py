#!/usr/bin/env python3
# Tier-2 CONSTRUCTIVE sampler reference for the hardest constraint class:
#
#       A * B < LIMIT      (A in [1,65535], B in [0,BMAX])
#
# The whole point: we do NOT bit-blast the multiplier and we do NOT search.
# We sample A, then DIVIDE to get B's exact upper bound, then sample B in range.
# The multiplier appears only as a *checker* (assert A*B < LIMIT) -- never in
# the solve.  Identical LFSR + arithmetic to mul_constraint_sampler.sv, so the
# software and hardware renderings emit the SAME stream bit-for-bit.
#
#   B <= floor((LIMIT-1)/A)  ==>  A*B <= A*floor((LIMIT-1)/A) <= LIMIT-1 < LIMIT
#
# That one inequality (proved algebraically, no bit-blasting) is the correctness
# argument -- see lean/MulSampler.lean for the machine-checked version.

W      = 16
LIMIT  = 1 << 24          # 16,777,216
BMAX   = 0xFFFF
TAPS_A = 0xB400
TAPS_B = 0x8016
SEED_A = 0xACE1
SEED_B = 0x1234

def step(s, taps):
    return (s >> 1) ^ (taps if (s & 1) else 0)

def run(n):
    a, b = SEED_A, SEED_B
    viol = 0
    first = []
    # coarse marginal histogram of A (8 buckets) just to show it is exercising
    buckets = [0] * 8
    for i in range(n):
        A = a
        q = (LIMIT - 1) // A                 # the divider (inverse of the mul)
        boundB = BMAX if q > BMAX else q
        B = b % (boundB + 1)                 # B in [0, boundB]
        if A * B >= LIMIT:                    # multiplier as CHECKER only
            viol += 1
        if i < 20:
            first.append((A, B))
        buckets[A >> 13] += 1
        a = step(a, TAPS_A)
        b = step(b, TAPS_B)
    return first, viol, buckets

if __name__ == "__main__":
    import sys
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 100000
    first, viol, buckets = run(n)
    for A, B in first:
        print(f"A={A:5d} B={B:5d} AB={A*B}")
    print(f"checked={n} violations={viol}")
    print("A-bucket counts:", buckets)
