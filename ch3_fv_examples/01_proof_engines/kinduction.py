"""
kinduction.py -- temporal (k-)induction.

Base case: BMC shows the property holds for the first k states from reset.
Inductive step: take k+1 states tied by the transition relation (NOT anchored at
reset), assume the property in the first k, and ask whether the (k+1)-th can be
bad. UNSAT => the property is k-inductive (proved); SAT => a counterexample to
induction (CTI).

  * The elevator is 1-inductive: the step is UNSAT at k=1 (the cross-gating
    forbids an unsafe next state wherever you start). Proved, no helper.
  * The FIFO loses at every k. The step is free to start from the garbage
    count=4 & full=0, which *self-loops* under idle -- so for any k there is a
    chain of k property-satisfying garbage states leading to overflow, and the
    step is SAT at every depth. The cure is the helper invariant full <-> count=4,
    which interpolation and IC3 find automatically (Phases 4 and 3).
"""

from __future__ import annotations
from cdcl import Solver
from circuit import fresh_frame, bad_lit, read_bv, next_env, tseitin
from bmc import bmc, tie, trace
from trace import T


def one_step_inductive(ts):
    """The k=1 inductive step (the chapter's combinational one-step query): assume
    P(s) at a free start, ask whether one step can reach not-P(s'). UNSAT => the
    property is 1-inductive; SAT => a counterexample-to-induction. Returns
    (sat, (solver, start_env)) so the caller can read the witness state."""
    if T.on:
        T.rule("CDCL one-step -- is the property 1-inductive?")
        T.say("assume P(s) at a free start state, force one transition, ask if P(s') can fail.")
    s = Solver()
    env0 = fresh_frame(s, ts, 0)
    s.add_clause([-bad_lit(s, ts, env0)])          # assume the property holds now
    nxt = next_env(s, ts, env0)
    s.add_clause([tseitin(s, ts.bad, nxt, nxt["__memo__"])])   # assert next state is bad
    with T.section(""):
        sat = s.solve()
    if T.on:
        T.say("SAT → not 1-inductive (a P-state steps to ¬P; reachable? this query cannot say)"
              if sat else
              "UNSAT → 1-inductive: no P-state steps to ¬P, so the property is closed in one step.")
    return sat, (s, env0)


def k_induction(ts, kmax: int):
    if T.on:
        T.rule("k-induction -- base case (BMC) + an unanchored inductive step")
        T.say("step at depth k: assume P holds in k consecutive states tied by T,")
        T.say("ask if the (k+1)-th can be bad. UNSAT ⇒ k-inductive (proved).")
    last_cti = None
    for k in range(1, kmax + 1):
        if T.on:
            T.say(f"k={k}: base case — property holds for the first {k} state(s) from reset?")
        base = bmc(ts, k - 1)                      # property holds for first k states?
        if base["result"] == "CEX":
            if T.on:
                T.say(f"  base case FAILS at k={k} → the property is simply false (real CEX)")
            return {"result": "CEX", "k": k, "trace": base["trace"]}
        if T.on:
            T.say(f"  base holds; inductive step — P in states 0..{k-1}, can state {k} be bad?")
        s = Solver()
        envs = [fresh_frame(s, ts, i) for i in range(k + 1)]
        for i in range(k):
            tie(s, ts, envs[i], envs[i + 1])
        for i in range(k):
            s.add_clause([-bad_lit(s, ts, envs[i])])   # assume P in the first k states
        s.add_clause([bad_lit(s, ts, envs[k])])         # ask: can state k be bad?
        with T.section(""):
            step_sat = s.solve()
        if not step_sat:
            if T.on:
                T.say(f"  UNSAT → the step is closed: property is {k}-inductive. PROVED.")
            return {"result": "PROVED", "k": k}
        last_cti = trace(s, ts, envs)                   # spurious CTI; try a larger k
        if T.on:
            T.say(f"  SAT → counterexample-to-induction (a P-satisfying state stepping to bad):")
            T.say(f"        {last_cti[-2] if len(last_cti) > 1 else last_cti[-1]} → bad. "
                  f"Maybe unreachable; try k={k+1}.")
    if T.on:
        T.say(f"stalled at k={kmax}: the step stays SAT (a recurring CTI). A stronger")
        T.say("invariant is needed — exactly what IC3 and interpolation build automatically.")
    return {"result": "STALLED", "kmax": kmax, "cti": last_cti}


if __name__ == "__main__":
    from frontend import example
    build_elevator = lambda: example("02_elevator_proof")
    build_fifo = lambda: example("03_fifo_proof")

    r = k_induction(build_elevator(), 8)
    print(f"[k-ind] elevator: {r['result']} at k={r.get('k')}")
    assert r["result"] == "PROVED" and r["k"] == 1

    r = k_induction(build_fifo(), 8)
    cti_last = r["cti"][-2] if r["cti"] else None       # the property-satisfying garbage state
    print(f"[k-ind] fifo:     {r['result']} up to k={r.get('kmax')}; "
          f"recurring CTI ...-> {cti_last} -> overflow")
    assert r["result"] == "STALLED"
    assert cti_last and cti_last.get("count") == 4 and cti_last.get("full") == 0
    print("[k-ind] OK: elevator 1-inductive; FIFO loses at every k on the count=4 & full=0 garbage")
