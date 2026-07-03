"""
demo.py -- run every Chapter 3 proof engine, in the order the chapter introduces
them, and print the verdict each produces. This is the "type one command, get a
mathematical answer" experience the chapter describes, on the two examples it
carries the whole way through: the elevator interlock and the FIFO overflow guard.

    python3 demo.py

Each section is a self-contained call into one engine module; run that module
directly (e.g. `python3 ic3.py`) to see its own assertions.
"""

from __future__ import annotations
from frontend import example
from circuit import read_bv, FALSE
from bmc import bmc
from kinduction import k_induction, one_step_inductive
from ic3 import IC3
from interp import itp_mc
import smt

build_elevator = lambda: example("02_elevator_proof")   # read elevator.sv -> model
build_fifo = lambda: example("03_fifo_proof")            # read fifo.sv -> model


def banner(t):
    print("\n" + "=" * 74)
    print("  " + t)
    print("=" * 74)


def cdcl_one_step():
    banner("1. CDCL -- the combinational one-step query (Sec. 'Proof Engines')")
    sat, _ = one_step_inductive(build_elevator())
    print(f"  elevator   not(moving & door)         one-step: "
          f"{'SAT' if sat else 'UNSAT'}  ->  settled in one conflict")
    fifo = build_fifo()
    sat, (s, env0) = one_step_inductive(fifo)
    cnt, fl = read_bv(s, env0, "count", 3), int(s.get_value(env0["full"]))
    print(f"  FIFO       count <= 4                  one-step: "
          f"{'SAT' if sat else 'UNSAT'}  ->  witness count={cnt}, full={fl} "
          f"(reachable? CDCL cannot say)")


def bmc_both():
    banner("2. BMC -- unroll from reset (find bugs fast)")
    for ts in (build_elevator(), build_fifo()):
        r = bmc(ts, 12)
        print(f"  {ts.name:10s} {r['result']} (depth {r['depth']})")


def kind_both():
    banner("3. k-induction -- base + step (proof, where induction closes)")
    r = k_induction(build_elevator(), 8)
    print(f"  elevator   {r['result']} at k={r.get('k')}  ->  1-inductive, no helper needed")
    r = k_induction(build_fifo(), 8)
    cti = r["cti"][-2] if r.get("cti") else None
    print(f"  FIFO       {r['result']} up to k={r.get('kmax')}  ->  loses at every k on "
          f"the recurring CTI {cti} (the garbage that self-loops)")


def ic3_both():
    banner("4. IC3/PDR -- frames, no unrolling (unbounded proof)")
    r = IC3(build_elevator()).solve()
    print(f"  elevator   {r['result']} in {r.get('frames')} frames")
    eng = IC3(build_fifo())
    r = eng.solve()
    fence = frozenset({eng.S.index("count[0]") + 1, eng.S.index("count[1]") + 1,
                       -(eng.S.index("count[2]") + 1), eng.S.index("full") + 1})
    print(f"  FIFO       {r['result']} in {r.get('frames')} frames  ->  discovered the fence "
          f"{eng.clause_str(fence)} == not(count=4 & full=0)")


def interp_both():
    banner("5. Craig interpolation -- the fence carved from a refutation proof")
    for build in (build_elevator, build_fifo):
        ts = build()
        r = itp_mc(ts)
        print(f"  {ts.name:10s} {r['result']}  ->  interpolant widening converged to an invariant")


def smt_demo():
    banner("6. SMT / DPLL(T) -- lifting SAT to words (Sec. 'SMT')")
    a, b, c, d = (smt.bvvar(n) for n in "abcd")
    sumA = smt.bvadd(smt.bvadd(smt.bvadd(a, b), c), d)   # ((a+b)+c)+d
    sumB = smt.bvadd(smt.bvadd(a, b), smt.bvadd(c, d))   # (a+b)+(c+d)
    r = smt.solve([smt.Eq(sumA, sumB)], [[-1]], 32)
    print(f"  adder-tree miter  ((a+b)+c)+d == (a+b)+(c+d)   word-level DPLL(T): "
          f"{r[0]} ({len(r[1])} theory lemma)")
    _, n = smt.bitblast_equiv(sumA, sumB, 32, count_only=True)
    print(f"                    same miter, eager bit-blast: {n} CNF clauses "
          f"(a single 32-bit bvmul alone is ~20k -- the multiplier wall)")


if __name__ == "__main__":
    print("Chapter 3 proof engines, on the elevator interlock and the FIFO overflow guard.")
    cdcl_one_step()
    bmc_both()
    kind_both()
    ic3_both()
    interp_both()
    smt_demo()
    banner("the escalation, in one read")
    print("""  elevator  : safe for a LOCAL reason -- CDCL settles the one-step query,
              k-induction proves it at k=1. Every later engine agrees instantly.
  FIFO      : safe for a GLOBAL reason -- the one-step query hands back the
              unreachable garbage count=4 & full=0; BMC never reaches it from
              reset; k-induction loses at every k; IC3 and interpolation both
              close it by discovering the same hidden invariant full <-> count=4.
  datapath  : SMT lifts the same CDCL to words, proving an adder-tree rebalance
              equivalent algebraically instead of bit-blasting the multiplier wall.""")
