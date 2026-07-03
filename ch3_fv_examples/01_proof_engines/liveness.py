"""
liveness.py -- liveness-to-safety (L2S), so the safety engines prove liveness.

A safety engine (BMC / k-induction / IC3) only ever answers "can a bad *state* be
reached?" Liveness -- "req is always eventually granted" -- is about infinite
behavior, not a single bad state. But a finite-state system violates a liveness
property exactly when it has a **lasso**: a reachable cycle in which the good event
never happens. And a lasso *is* a safety property, once you augment the machine to
watch for it. That reduction is what lets IC3 close the arbiter's no-starvation and
the CDC handshake -- the properties the chapter otherwise sends to a commercial
liveness engine -- with no new solver, just a bit more state.

The construction (Biere/Artho/Schuppan "liveness checking as safety checking"):

  * A response property `a |-> s_eventually b` becomes a monitor register
        pending' = (pending | a) & !b            pending = "an obligation is owed"
    and the good event is `p = !pending`. The property holds iff `p` recurs -- iff
    there is *no* reachable loop with `pending` stuck high.
  * A nondeterministic oracle input `__save` guesses when the loop starts; at that
    moment a shadow copy of the (real) state is frozen. `__triggered` records
    whether `p` held anywhere since the save.
  * bad = we are back at the saved state (the loop closed) and `p` never held on
    it and the environment obeyed its assumptions:
        saved & (state == shadow) & !triggered & assumptions-held-so-far
    If bad is unreachable, no p-avoiding loop exists → the liveness holds. If IC3
    finds bad reachable, the trace *is* the starvation lasso.

Assumptions (`assume property (...)`) gate the whole thing through a monotone
`__assm_ok` latch, so a counterexample is only accepted if the environment kept its
side of the contract every cycle -- exactly the fairness the arbiter needs.
"""

from __future__ import annotations
from circuit import (TransitionSystem, Sig, VAR, AND, OR, NOT, ITE, XNOR,
                     TRUE, FALSE)


def apply_assumptions(ts: TransitionSystem) -> TransitionSystem:
    """Guard a SAFETY property by the environment assumptions: bad is only reachable on
    a path that respected every `assume` at every step (a monotone `__assm_ok` latch).
    Without this the safety engines ignore assumptions; the liveness path already does
    this internally. No assumptions -> the system is returned unchanged."""
    if not ts.assumptions:
        return ts
    L = TransitionSystem(ts.name)
    for inp in ts.inputs:
        L.add_input(inp)
    for s in ts.state:
        L.add_state_bit(s, ts.init[s], ts.next[s])
    assm = AND(*ts.assumptions)
    aok = VAR("__assm_ok")
    L.add_state_bit("__assm_ok", 1, AND(aok, assm))
    L.bad = AND(ts.bad, aok, assm)              # bad only where assumptions have held
    L.liveness = ts.liveness
    L.assumptions = ts.assumptions
    return L


def liveness_to_safety(ts: TransitionSystem, idx: int = 0) -> TransitionSystem:
    """Augment `ts` so that its `liveness[idx]` property (a |-> s_eventually b)
    becomes the reachability of `L.bad`. Returns the augmented safety system."""
    a, b = ts.liveness[idx]
    L = TransitionSystem(ts.name + "_L2S")

    # inputs: the original environment, plus the loop-start oracle
    for inp in ts.inputs:
        L.add_input(inp)
    save = L.add_input("__save")

    # the original design, carried verbatim (same next-state, same reset)
    for s in ts.state:
        L.add_state_bit(s, ts.init[s], ts.next[s])

    # obligation monitor:  pending' = (pending | a) & !b ;  good event p = !pending
    pending = VAR("__pending")
    L.add_state_bit("__pending", 0, AND(OR(pending, a), NOT(b)))
    p = NOT(pending)

    # the oracle latch: once it fires, we are inside the guessed loop forever
    saved = VAR("__saved")
    L.add_state_bit("__saved", 0, OR(saved, save))

    # freeze a shadow of the *real* state (design + obligation) at the save cycle:
    # before saved it tracks the state; on the save it captures it; then it holds.
    watched = list(ts.state) + ["__pending"]
    for w in watched:
        L.add_state_bit(f"__shadow_{w}", 0, ITE(saved, VAR(f"__shadow_{w}"), VAR(w)))

    # did the good event occur anywhere since the save?
    trig = VAR("__triggered")
    L.add_state_bit("__triggered", 0, ITE(OR(saved, save), OR(trig, p), FALSE))

    # environment assumptions: a monotone latch that a counterexample must respect
    if ts.assumptions:
        assm_now = AND(*ts.assumptions)
        aok = VAR("__assm_ok")
        L.add_state_bit("__assm_ok", 1, AND(aok, assm_now))
        assm_guard = AND(aok, assm_now)
    else:
        assm_guard = TRUE

    # the loop has closed: the real state equals its saved shadow
    loop_closed = AND(*[XNOR(VAR(w), VAR(f"__shadow_{w}")) for w in watched])

    # bad = a p-avoiding loop, reachable under the assumptions
    L.bad = AND(saved, loop_closed, NOT(trig), assm_guard)
    return L


if __name__ == "__main__":
    import os
    import frontend
    from ic3 import IC3
    from bmc import bmc
    here = os.path.dirname(os.path.abspath(__file__))
    ch2 = os.path.join(here, "..", "..", "ch2_rtl_fv_examples")

    # arbiter, proved from the BOOK design + its concurrent-SVA checker + the stable-
    # request env: a requester held under the fairness assumption is never starved --
    # the lasso is unreachable, IC3 proves SAFE.
    a = os.path.join(ch2, "02_arbiter")
    ts = frontend.load(os.path.join(a, "round_robin_arbiter.sv"),
                       os.path.join(a, "round_robin_arbiter_checker.sv"),
                       os.path.join(a, "fv", "round_robin_arbiter_env.sv"))
    L = liveness_to_safety(ts)
    r = IC3(L).solve()
    print(f"[liveness] arbiter no-starvation, stable req: {r['result']} "
          f"({len(ts.state)}→{len(L.state)} bits)")
    assert r["result"] == "SAFE", "a stable request must never be starved"

    # CDC handshake, from the book design + checker: a request under the TX contract is
    # eventually acked -- every RX guarantee the checker states holds.
    c = os.path.join(ch2, "03_cdc_handshake")
    ts2 = frontend.load(os.path.join(c, "cdc_handshake_rx.sv"),
                        os.path.join(c, "cdc_handshake_rx_checker.sv"))
    for i in range(len(ts2.liveness)):
        ri = IC3(liveness_to_safety(ts2, i)).solve()
        print(f"[liveness] CDC handshake guarantee {i}: {ri['result']}")
        assert ri["result"] == "SAFE"

    # drop the fairness assumption → a pulsing request starves → the lasso is real.
    ts.assumptions = []
    Lu = liveness_to_safety(ts)
    ru = bmc(Lu, 10)
    print(f"[liveness] arbiter without fairness: BMC finds a starvation lasso -> {ru['result']}")
    assert ru["result"] == "CEX", "without fairness the pulsing request must starve"
    print("[liveness] OK: liveness-to-safety turns 'eventually' into a lasso the safety "
          "engines settle -- proved with the assume, refuted without it")
