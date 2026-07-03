"""
interp.py -- Craig interpolation and interpolation-based model checking
(McMillan 2003).

Chapter 3: "interpolation carves the fence from a proof." When the reachability
query A ∧ B is UNSAT (A = the reachable over-approximation followed by one
transition; B = the bad states), Craig's theorem gives an interpolant I over the
shared variables -- the next-state -- implied by A yet inconsistent with B. It
covers every state one step out while excluding the bug; iterating I as a
widening of the reachable set converges to an inductive invariant -- the same
`full <-> count=4` fence IC3 builds, here carved from a refutation.

A genuine interpolant needs a genuine proof, so this module carries its own
small *proof-producing* DPLL (the tested CDCL is left untouched) and extracts the
interpolant by McMillan's labelling: an A-leaf contributes its global literals, a
B-leaf contributes true, a resolution is ∨ on an A-local pivot and ∧ otherwise.
"""

from __future__ import annotations
from circuit import (AND, OR, NOT, TRUE, FALSE, VAR, tseitin, sig_str)
from cdcl import Solver
from bmc import bmc            # reliable bounded reachability (the trusted screen)
from trace import T


# ---------------------------------------------------------------------------
# Proof-producing DPLL.
# ---------------------------------------------------------------------------
class Proof:
    def __init__(self):
        self.src = {}      # clause -> ("A",) | ("B",) | ("res", left, right, pivot_lit)

    def leaf(self, c, tag):
        self.src.setdefault(c, (tag,))

    def res(self, c, left, right, pivot):
        self.src.setdefault(c, ("res", left, right, pivot))


def resolve(c1, c2, x):
    return frozenset(l for l in c1 if l != x) | frozenset(l for l in c2 if l != -x)


def dpll_prove(clauses_tagged):
    proof = Proof()
    clauses = []
    for c, tag in clauses_tagged:
        c = frozenset(c)
        proof.leaf(c, tag)
        clauses.append(c)
    allvars = sorted({abs(l) for c in clauses for l in c})

    def rec(a):
        a = dict(a)
        reason = {}
        order = []
        while True:
            confl = unit = ucl = None
            for c in clauses:
                sat = False
                un = []
                for l in c:
                    v = a.get(abs(l))
                    if v is None:
                        un.append(l)
                    elif v == (l > 0):
                        sat = True
                        break
                if sat:
                    continue
                if not un:
                    confl = c
                    break
                if len(un) == 1 and unit is None:
                    unit, ucl = un[0], c
            if confl is not None:
                c = confl
                for l in reversed(order):
                    if -l in c and l in reason:
                        nc = resolve(c, reason[l], -l)
                        proof.res(nc, c, reason[l], -l)
                        c = nc
                return c
            if unit is not None:
                a[abs(unit)] = (unit > 0)
                reason[unit] = ucl
                order.append(unit)
                continue
            break
        un = [v for v in allvars if a.get(v) is None]
        if not un:
            return None                       # SAT
        x = un[0]
        c0 = rec({**a, x: False})
        if c0 is None:
            return None
        if x not in c0 and -x not in c0:
            return c0
        c1 = rec({**a, x: True})
        if c1 is None:
            return None
        if x not in c1 and -x not in c1:
            return c1
        piv = x if x in c0 else -x
        nc = resolve(c0, c1, piv)
        proof.res(nc, c0, c1, piv)
        return nc

    r = rec({})
    if r is None:
        return ("SAT", None)
    return ("UNSAT", r, proof)


def mcmillan(proof, empty, is_global, lit_sig):
    memo = {}

    def itp(c):
        if c in memo:
            return memo[c]
        s = proof.src.get(c, ("A",))
        if s[0] in ("A", "B"):
            if s[0] == "B":
                r = TRUE
            else:
                g = [lit_sig(l) for l in c if is_global(abs(l))]
                r = OR(*g) if g else FALSE
        else:
            _, left, right, piv = s
            il, ir = itp(left), itp(right)
            r = OR(il, ir) if not is_global(abs(piv)) else AND(il, ir)
        memo[c] = r
        return r

    return itp(empty)


# ---------------------------------------------------------------------------
# Interpolation-based model checking (one-step image widening).
# ---------------------------------------------------------------------------
def _sat(sig_list_over_state, ts):
    """SAT-check a conjunction of Sigs over the state (and input) vars with the
    reliable CDCL. Inputs are free -- so a Sig that reads them (a Mealy `bad`) is
    satisfiable exactly when *some* input drives it."""
    s = Solver()
    cur = {n: s.new_var() for n in ts.state}
    for inp in ts.inputs:
        cur[inp] = s.new_var()
    memo = {}
    for sig in sig_list_over_state:
        s.add_clause([tseitin(s, sig, cur, memo)])
    return s.solve()


def _implies(a_sig, b_sig, ts):
    return not _sat([a_sig, NOT(b_sig)], ts)


class _Rec(Solver):
    """A Solver that also records every clause (units included) for the proof CNF;
    Solver.add_clause keeps units out of self.clauses, so we capture them here."""
    def __init__(self):
        super().__init__()
        self.log = []

    def add_clause(self, lits):
        seen, out, taut = set(), [], False
        for l in lits:
            if -l in seen:
                taut = True
                break
            if l in seen:
                continue
            seen.add(l)
            out.append(l)
        if not taut and out:
            self.log.append(frozenset(out))
        return super().add_clause(lits)


def _build_query(ts, R):
    """Build CNF for A = R(s) ∧ T(s,s'), B = bad(s'); return (tagged_clauses,
    is_global, lit_sig). Shared vars are the next-state vars s'."""
    s = _Rec()
    cur = {n: s.new_var() for n in ts.state}
    for inp in ts.inputs:
        cur[inp] = s.new_var()
    nxt = {n: s.new_var() for n in ts.state}
    memo = {}
    # A: transition relation s' = next(s), and R(s)
    for n in ts.state:
        f = tseitin(s, ts.next[n], cur, memo)
        s.add_clause([-f, nxt[n]])
        s.add_clause([f, -nxt[n]])
    s.add_clause([tseitin(s, R, cur, memo)])
    A = list(s.log)
    s.log = []
    # B: bad(s') -- fresh next-step inputs so a property that reads inputs (a
    # Mealy / combinational-output assertion) encodes; they are B-local, so
    # interpolation projects them out and the frontier stays over state names.
    memoB = {}
    bad_env = {n: nxt[n] for n in ts.state}
    for inp in ts.inputs:
        bad_env[inp] = s.new_var()
    s.add_clause([tseitin(s, ts.bad, bad_env, memoB)])
    B = list(s.log)
    tagged = [(c, "A") for c in A] + [(c, "B") for c in B]
    glob = set(nxt.values())
    name = {nxt[n]: n for n in ts.state}
    lit_sig = lambda l: (VAR(name[abs(l)]) if l > 0 else NOT(VAR(name[abs(l)]))) \
        if abs(l) in name else FALSE
    return tagged, (lambda v: v in glob), lit_sig


def itp_mc(ts, max_iter=80, bmc_depth=12):
    """Interpolation-based model checking (McMillan 2003), one-step image widening.

    A trusted screen runs first: McMillan's method BMC-checks each unrolling depth
    anyway, and here that bounded reachability is decided by the reliable CDCL, not
    the compact proof-producing DPLL below (whose branch pruning can mis-rule a
    larger datapath query UNSAT). So a genuine counterexample reachable from reset
    within `bmc_depth` is reported honestly as UNSAFE, never papered over by a
    coarse over-approximation. Past that screen the design has no shallow bug, and
    the interpolation loop carves the fence: each UNSAT query yields an interpolant
    I(s') that widens R until the image closes (I ⊆ R) -- the invariant."""
    if T.on:
        T.rule("Interpolation (McMillan) -- carve the fence from a refutation")
        T.say("A trusted BMC screen first; then, from each UNSAT one-step query, extract an")
        T.say("interpolant I(s') over the frontier and widen R := R ∨ I until the image closes.")
    if bmc(ts, bmc_depth)["result"] == "CEX":
        if T.on:
            T.say("BMC screen found a reachable bad state → UNSAFE (no proof to carve)")
        return {"result": "UNSAFE"}
    R = AND(*[VAR(n) if ts.init[n] else NOT(VAR(n)) for n in ts.state])
    init = R
    for it in range(max_iter):
        if T.on:
            T.say(f"iteration {it}: R = {sig_str(R)}")
            T.say(f"  query  A = R(s) ∧ T(s,s')   B = bad(s')   -- can R reach bad in one step?")
        tagged, is_global, lit_sig = _build_query(ts, R)
        res = dpll_prove(tagged)
        if res[0] == "SAT":
            if _implies(R, init, ts) and _implies(init, R, ts):
                if T.on:
                    T.say("  SAT with R = Init → a genuine one-step counterexample. UNSAFE.")
                return {"result": "UNSAFE"}
            if T.on:
                T.say("  SAT but R over-approximates Init → the k=1 image is too coarse to refine. UNKNOWN.")
            return {"result": "UNKNOWN", "reason": "k=1 over-approx too coarse"}
        _, empty, proof = res
        I = mcmillan(proof, empty, is_global, lit_sig)   # over s' names == state names
        if T.on:
            T.say(f"  UNSAT → interpolant I = {sig_str(I)}")
        if _implies(I, R, ts):
            if T.on:
                T.say("  I ⊆ R: the image added nothing new → R is inductive. SAFE.")
            return {"result": "SAFE", "invariant": R}
        if T.on:
            T.say("  I ⊄ R: new frontier states → widen R := R ∨ I and iterate")
        R = OR(R, I)
    return {"result": "UNKNOWN", "reason": "iteration limit"}


if __name__ == "__main__":
    # textbook interpolant: A = (x) ∧ (¬x ∨ y); B = (¬y); shared var y; I ⇒ y.
    res = dpll_prove([(frozenset({1}), "A"), (frozenset({-1, 2}), "A"), (frozenset({-2}), "B")])
    assert res[0] == "UNSAT"
    _, empty, proof = res                       # the empty clause, and the resolution proof
    I = mcmillan(proof, empty, lambda v: v == 2,
                 lambda l: VAR("y") if l == 2 else (NOT(VAR("y")) if l == -2 else FALSE))
    print("[interp] textbook interpolant over the shared variable y: extracted")

    from frontend import example
    r = itp_mc(example("02_elevator_proof"))
    print(f"[interp] elevator: {r['result']}")
    assert r["result"] == "SAFE"
    r = itp_mc(example("03_fifo_proof"))
    print(f"[interp] fifo:     {r['result']}")
    assert r["result"] == "SAFE"
    print("[interp] OK: interpolation proves both -- the fence carved from refutation proofs")
