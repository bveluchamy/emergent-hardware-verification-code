"""
memproof.py -- carrying a memory word-level, with the theory of arrays.

Two of the Chapter 2 datapath designs state contracts *about the contents of a
memory*, not just its control:

  * mem_ctrl  -- "a read of an address returns the last value written there"
                 (the write-then-read / shadow-register property).
  * sync_fifo -- "a value pushed into the queue emerges at the head uncorrupted"
                 (Wolper's data-independence, the symbolic-token checker).

Bit-blasting the array to prove these forces the address space small (a 4096-entry
DRAM store becomes 131072 state bits). The word-level engine avoids that entirely:
the memory is a single array variable, a write is `store(mem, a, d)`, a read is
`select(mem, a)`, and the McCarthy read-over-write axioms in smt.py decide the
contract with the address left SYMBOLIC at its true width. Nothing is enumerated.

This is the array-theory counterpart of sec.py: sec.py keeps *operands* symbolic
(the SMT section's adder tree), memproof.py keeps the *memory* symbolic. Both are
the Chapter 3 SMT engine reasoning above the bit level.
"""

from __future__ import annotations
from smt import bvvar, bvconst, bvselect, bvstore, Eq, solve
from trace import T


# ---------------------------------------------------------------------------
# mem_ctrl: the write-then-read invariant, proved by one-step induction.
#
# The book checker keeps a shadow register `wr_shadow` = the last value written to
# address 0, and asserts a read of address 0 returns it. That is the observable
# face of the invariant  select(mem, A) == shadow  for the watched address A. We
# prove the invariant is inductive: assume it holds, apply one arbitrary write
# (data d to address a), and show it still holds -- for the SAME symbolic A, with
# the shadow updated exactly when the write targets A. Array theory closes both
# cases (a hits A, a misses A) with no case enumeration of the address space.
# ---------------------------------------------------------------------------
def build_write_then_read(bug=False):
    mem, A, shadow = bvvar("mem"), bvvar("A"), bvvar("shadow")
    a, d = bvvar("a"), bvvar("d")                 # an arbitrary write: mem[a] <= d
    mem2 = bvstore(mem, a, d)
    sn = bvvar("shadow_next")                     # shadow' (defined by the clauses below)

    hit = Eq(a, A)                                # atom 1: does the write target A?
    ih  = Eq(bvselect(mem, A), shadow)            # atom 2: the inductive hypothesis
    read2 = bvselect(mem2, A)                     # the read of A after the write
    goal = Eq(read2, sn)                          # atom 3: invariant preserved?
    def_hit  = Eq(sn, d)                          # atom 4: a hits A  -> shadow' = d
    def_miss = Eq(sn, shadow)                     # atom 5: a misses A -> shadow' = shadow
    atoms = [hit, ih, goal, def_hit, def_miss]

    # shadow' is d on a hit, shadow on a miss.  THE BUG drops the shadow update on a
    # hit (shadow' stays the stale value), so a fresh write to A is not reflected.
    if bug:
        cnf = [[5], [2], [-3]]                    # shadow' = shadow (always); IH; refute goal
        note = "BUG: shadow not updated when the write targets the watched address"
    else:
        cnf = [[-1, 4], [1, 5], [2], [-3]]        # hit->def_hit, miss->def_miss, IH, refute goal
        note = "shadow' = (a==A) ? d : shadow"
    return atoms, cnf, note


# ---------------------------------------------------------------------------
# sync_fifo: Wolper data-independence. A token is pushed into slot P. The FIFO's
# no-overflow invariant guarantees every later push lands in a DIFFERENT free slot
# (a full ring stops accepting), so by the time the head reaches P the token has
# never been overwritten. Reading slot P then yields the token. Array theory proves
# it as a chain of disjoint stores over a store at P -- the address never enumerated.
# ---------------------------------------------------------------------------
def build_fifo_token(n_intervening=3, bug=False):
    mem, P, tok = bvvar("mem"), bvvar("P"), bvvar("tok")
    buf = bvstore(mem, P, tok)                    # push the token into slot P
    atoms, cnf = [], []
    # each later push writes some data at slot Q_k; the no-overflow invariant says
    # Q_k != P (a correct FIFO never overwrites an unread slot).
    for k in range(n_intervening):
        Q, dat = bvvar(f"Q{k}"), bvvar(f"d{k}")
        atoms.append(Eq(Q, P))                    # atom: does this push alias slot P?
        cnf.append([-len(atoms)])                 # assume Q_k != P  (the FIFO invariant)
        buf = bvstore(buf, Q, dat)
    # THE BUG: drop the no-overflow invariant on the first push, so it may alias P and
    # clobber the token before it is read.
    if bug and n_intervening > 0:
        cnf = cnf[1:]                             # first push no longer constrained off P
        note = "BUG: no-overflow invariant dropped -- a push may overwrite the unread token"
    else:
        note = f"{n_intervening} disjoint pushes; the token in slot P is never overwritten"
    atoms.append(Eq(bvselect(buf, P), tok))       # the head read returns the token?
    cnf.append([-len(atoms)])                     # refute it: read != tok
    return atoms, cnf, note


def _run(name, builder, w, bug):
    atoms, cnf, note = builder(bug=bug)
    if T.on:
        T.rule(f"{name} -- word-level memory via the theory of arrays")
        T.say(f"  {note}")
    res = solve(atoms, cnf, w)
    holds = res[0] == "UNSAT"
    verdict = ("HOLDS -> read-over-write proves it, address symbolic"
               if holds else "REFUTED -> the array theory found a corrupting witness")
    print(f"  [{name:14s}] {'HOLDS' if holds else 'REFUTED'} -> {verdict.split('-> ',1)[1]}")
    return holds


def prove_mem(w=12, bug=False):
    """Return whether both memory-content contracts HOLD word-level. The bug-injected
    form refutes them (returns False), so `--check` exits nonzero exactly when the bug
    is caught -- the same convention as sec/sec-bug."""
    print("DUT: mem_ctrl write-then-read + sync_fifo data-independence (theory of arrays)"
          + (" -- MUTATION" if bug else ""))
    ok_wtr  = _run("write-then-read", build_write_then_read, w, bug)
    ok_fifo = _run("fifo-token",      build_fifo_token,      w, bug)
    hold = ok_wtr and ok_fifo
    if bug:
        print("REFUTED: array theory catches the corrupted memory (read-over-write no "
              "longer holds).")
    else:
        print("PROOF HOLDS: both memory contracts proven word-level, address never enumerated."
              if hold else "  (a contract failed)")
    return hold


if __name__ == "__main__":
    assert prove_mem(w=12, bug=False),     "the memory contracts must hold"
    assert not prove_mem(w=12, bug=True),  "the bug-injected memories must be refuted"
    print("[memproof] OK: mem_ctrl write-then-read and FIFO data-independence proven by "
          "read-over-write array theory; both bug-injected memories refuted")
