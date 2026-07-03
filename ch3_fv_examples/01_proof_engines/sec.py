"""
sec.py -- sequential equivalence of the pipelined ALU, word-level, via DPLL(T).

Chapter 2's pipelined ALU forwards operands so that back-to-back dependent
instructions read the right value before it has been written back. Its contract is
sequential equivalence: for every program, the pipeline produces exactly what a
simple in-order reference (one add per cycle, no pipeline, no forwarding) would.
The book runs this unbounded on a commercial tool; here the *word-level* SMT engine
(smt.py) settles it directly -- and this is the case the chapter's SMT section is
about, so it belongs to that engine, not to bit-blasted BMC.

The key move is to keep the operand values as symbolic bit-vectors and let the
theory reason about them. Over a fixed (hazard-exercising) program the control is
concrete -- which stage each operand forwards from is known -- so each result is a
word-level term. We build two independent models:

  * reference:  seq[i]  = arch(rs1) + arch(rs2),  arch(src) = the latest earlier
                writer of src, else its initial value.
  * pipeline:   pip[i]  = fwd(rs1) + fwd(rs2),     fwd(src) forwards from the i-1
                (MEM) or i-2 (WB) result on a hazard, else reads the register file
                (a writer at distance ≥3, already committed), else the initial value.

Each result is a fresh variable pinned by an equality; the miter asks whether any
pip[i] can differ from seq[i]. DPLL(T) substitutes the equalities and normalizes
the sums (the add normal form mod 2^w): the two collapse to the same sum of initial
values, the disequality is theory-inconsistent, and the miter is UNSAT -- proven
for every operand value at once, at any width. Break a forwarding path and the
engine returns SAT with the operands that expose it.
"""

from __future__ import annotations
from smt import bvvar, bvconst, bvadd, Eq, solve
from trace import T


# A small program of ADDs (rd = rs1 + rs2) that exercises every forwarding path:
#   I1 reads r1 one instruction after I0 writes it   (MEM forward, distance 1)
#   I2 reads r1 two after I0                           (WB forward, distance 2)
#   I3 reads r6 (distance 1) and r1 (distance 3 → RF, already committed)
DEFAULT_PROGRAM = [
    (1, 2, 3),   # I0:  r1 = r2 + r3
    (4, 1, 5),   # I1:  r4 = r1 + r5
    (6, 1, 4),   # I2:  r6 = r1 + r4
    (7, 6, 1),   # I3:  r7 = r6 + r1
]


def build_sec(program=DEFAULT_PROGRAM, nregs=8, bug=None):
    """Return (atoms, cnf, description) for the pipeline-vs-reference miter.
    `bug` in {None, 'no_mem_fwd', 'no_wb_fwd', 'swap_operands'} injects a defect.
    Each result is a fully-expanded term over the initial register values, so the
    word-level normal form collapses both models to a sum of initial values."""
    init = {r: bvvar(f"rf{r}_init") for r in range(nregs)}

    # ---- reference: sequential in-order register file -----------------------
    seq = []
    def arch(src, i):
        if src == 0:
            return bvconst(0)
        for j in range(i - 1, -1, -1):          # latest earlier writer of src
            if program[j][0] == src:
                return seq[j]
        return init[src]
    for i, (rd, rs1, rs2) in enumerate(program):
        seq.append(bvadd(arch(rs1, i), arch(rs2, i)))

    # ---- pipeline: forwarding from MEM (i-1) / WB (i-2), else the RF ---------
    pip, notes = [], []
    def fwd(src, i):
        if src == 0:
            return bvconst(0), "x0"
        if i - 1 >= 0 and program[i - 1][0] == src and bug != "no_mem_fwd":
            return pip[i - 1], f"MEM(I{i-1})"
        if i - 2 >= 0 and program[i - 2][0] == src and bug != "no_wb_fwd":
            return pip[i - 2], f"WB(I{i-2})"
        for j in range(i - 3, -1, -1):          # already committed to the RF
            if program[j][0] == src:
                return pip[j], f"RF(I{j})"
        return init[src], f"RF(rf{src}_init)"
    for i, (rd, rs1, rs2) in enumerate(program):
        va, na = fwd(rs1, i)
        vb, nb = fwd(rs2, i)
        if bug == "swap_operands" and i == 1:
            va, vb = vb, va                              # a silly datapath defect
        pip.append(bvadd(va, vb))
        notes.append(f"I{i}: r{rd} = r{rs1}[{na}] + r{rs2}[{nb}]")

    miters = [Eq(pip[i], seq[i]) for i in range(len(program))]
    # assert that at least one pipeline result differs from the reference
    cnf = [[-(m + 1) for m in range(len(miters))]]
    desc = {"program": program, "notes": notes, "nmiter": len(miters)}
    return miters, cnf, desc


def prove_sec(program=DEFAULT_PROGRAM, nregs=8, w=8, bug=None):
    """Decide the SEC with word-level DPLL(T). Returns 'EQUIVALENT' | 'DIFFERS'."""
    atoms, cnf, desc = build_sec(program, nregs, bug)
    if T.on:
        T.rule("Pipelined-ALU sequential equivalence (word-level DPLL(T))")
        T.say(f"program of {len(desc['program'])} ADDs; pipeline forwarding decisions:")
        with T.section(""):
            for n in desc["notes"]:
                T.say(n)
        T.say(f"miter: does any pipeline result differ from the in-order reference?")
    res = solve(atoms, cnf, w, allow_bitblast=True)
    return "EQUIVALENT" if res[0] == "UNSAT" else "DIFFERS"


if __name__ == "__main__":
    r = prove_sec()
    print(f"[sec] pipelined ALU vs in-order reference: {r}")
    assert r == "EQUIVALENT", "the correctly-forwarded pipeline must match the reference"

    for bug in ("no_mem_fwd", "no_wb_fwd"):
        rb = prove_sec(bug=bug)
        print(f"[sec] with '{bug}' broken: {rb}")
        assert rb == "DIFFERS", f"{bug} should break sequential equivalence"

    # swapping an adder's operands is NOT a bug: the word-level engine knows a+b == b+a
    # and sees through it -- exactly the strength the SMT section is about.
    rs = prove_sec(bug="swap_operands")
    print(f"[sec] with 'swap_operands': {rs}  (add is commutative -> still equivalent)")
    assert rs == "EQUIVALENT"
    print("[sec] OK: word-level DPLL(T) proves the forwarding pipeline equivalent to its "
          "in-order reference, catches a broken forwarding path, and sees through a "
          "commutative operand swap")
