"""
cegar.py -- Counterexample-Guided Abstraction Refinement, by localization.

The loop Chapter 2 develops on the MSI cache (Clarke et al., CAV 2000;
Figure `fig:cegar`), in runnable form. The abstraction here is
**localization**: keep a chosen set of state bits concrete and cut every
other register free -- its next-state function is discarded and the flop
becomes a fresh input the abstract model may drive to any value at any
cycle. That is existential abstraction: every concrete behavior survives
(drive each freed input with the value the real register would have taken),
so the abstract model over-approximates the design and a proof on it is
final.

A counterexample, though, may live in the invented behaviors, so it is
replayed on the concrete design -- and because the trace fixes reset and
every input, and the design is deterministic, the replay is a plain
simulation (circuit.ternary_eval with no X's), not another SAT call. If the
replay reaches bad, the bug is real, with a concrete trace. If it does not,
the earliest cycle where a freed bit the abstraction actually *reads* takes
an invented value different from its simulated one names exactly the
distinction the abstraction dropped; those bits are re-concretized and the
loop goes again. Each spurious round grows the kept set by at least one bit
(if every read freed bit agreed everywhere, the two runs would be identical
and the counterexample would have replayed), so the loop terminates.

Four moves per round -- Abstract, Check (IC3 on the small model), Conclude
or Replay, Refine -- and the proof that comes back names the handful of
bits the property actually depends on; everything else stayed cut free.
"""

from __future__ import annotations
from cdcl import Solver
from circuit import TransitionSystem, ternary_eval, support, bad_lit
from bmc import unroll
from ic3 import IC3
from trace import T


def localize(ts: TransitionSystem, keep: set) -> TransitionSystem:
    """The abstraction: every state bit outside `keep` becomes a free input.
    The next-state functions of the kept bits are untouched -- where they read
    a freed register they now read an unconstrained input, which is exactly
    'where the abstraction cannot tell, it must allow both behaviors'."""
    a = TransitionSystem(ts.name + "+loc")
    for n in ts.state:
        if n in keep:
            a.add_state_bit(n, ts.init[n], ts.next[n])
    a.inputs = list(ts.inputs) + [n for n in ts.state if n not in keep]
    a.bad = ts.bad
    a.assumptions = list(ts.assumptions)
    return a


def _abs_cex(abs_ts: TransitionSystem, kmax: int):
    """The shortest abstract counterexample, as one {name: 0/1} valuation per
    cycle over the abstract state bits AND inputs -- the freed bits are inputs
    here, so their invented values come back too, which is exactly what the
    refinement step compares against."""
    for k in range(kmax + 1):
        s = Solver()
        envs = unroll(s, abs_ts, k, from_init=True)
        s.add_clause([bad_lit(s, abs_ts, envs[k])])
        if s.solve():
            names = abs_ts.state + abs_ts.inputs
            return [{n: (1 if s.get_value(e[n]) else 0) for n in names}
                    for e in envs]
    return None


def _simulate(ts: TransitionSystem, cex: list):
    """Replay the abstract counterexample's INPUT sequence on the concrete
    design: reset state, recorded inputs, every register following its real
    next-state function. Deterministic, so this is simulation, not SAT.
    Returns (first cycle bad holds or None, per-cycle full valuations)."""
    state = {n: (1 if ts.init[n] else 0) for n in ts.state}
    rows = []
    for t, step in enumerate(cex):
        env = dict(state)
        for i in ts.inputs:
            env[i] = step[i]
        rows.append(env)
        memo = {}
        if ternary_eval(ts.bad, env, memo) == 1:
            return t, rows
        if t + 1 < len(cex):
            state = {n: ternary_eval(ts.next[n], env, memo) for n in ts.state}
    return None, rows


class _Frontier:
    """Freed bits the current abstraction actually reads -- the support of the
    kept next-state functions and of bad. A freed bit outside this set cannot
    influence the abstract model, so it is never a refinement candidate."""

    def __init__(self, ts):
        self.ts = ts
        self._sup = {}                       # state bit -> support of its next fn
        self._bad_sup = support(ts.bad)

    def _sup_of(self, n):
        s = self._sup.get(n)
        if s is None:
            s = self._sup[n] = support(self.ts.next[n])
        return s

    def read(self, keep: set) -> list:
        r = set(self._bad_sup)
        for n in keep:
            r |= self._sup_of(n)
        return [n for n in self.ts.state if n in r and n not in keep]


def cegar(ts: TransitionSystem, max_frames=40, max_rounds=200):
    """Abstract / Check / Conclude-or-Replay / Refine until the property is
    proved on an abstraction (final) or a counterexample replays (a real bug).
    Starts from the property's own support -- the predicates the checker
    names -- and lets the refutations name every further bit that matters."""
    fr = _Frontier(ts)
    keep = [n for n in ts.state if n in fr._bad_sup]
    total = len(ts.state)
    for rnd in range(1, max_rounds + 1):
        kset = set(keep)
        abs_ts = localize(ts, kset)
        print(f"  [CEGAR round {rnd:2d}] keep {len(keep)}/{total} bits concrete, "
              f"{total - len(keep)} cut free; model-check the abstraction ...")
        r = IC3(abs_ts).solve(max_frames)
        if r["result"] == "SAFE":
            print(f"  [CEGAR         ] SAFE on the abstraction ({r.get('frames')} frames) -> "
                  f"final: the abstraction has every concrete behavior and more")
            return {"result": "SAFE", "rounds": rnd, "kept": keep,
                    "frames": r.get("frames"), "invariant": r.get("invariant", set())}
        if r["result"] != "UNSAFE":
            return {"result": "UNKNOWN", "rounds": rnd, "kept": keep}
        kmax = r.get("frames", r.get("depth", 0)) + 2
        cex = _abs_cex(abs_ts, kmax)
        if cex is None:                      # IC3 said UNSAFE; BMC must find it
            return {"result": "UNKNOWN", "rounds": rnd, "kept": keep}
        bad_at, rows = _simulate(ts, cex)
        if bad_at is not None:
            print(f"  [CEGAR         ] the counterexample REPLAYS on the concrete design "
                  f"(bad at cycle {bad_at}) -> a real bug, with a concrete trace")
            return {"result": "UNSAFE", "rounds": rnd, "kept": keep,
                    "depth": bad_at, "trace": rows[:bad_at + 1]}
        # spurious: earliest divergence of a READ freed bit names the refinement
        frontier = fr.read(kset)
        t_div, div = None, []
        for t in range(len(rows)):
            div = [n for n in frontier if cex[t][n] != rows[t][n]]
            if div:
                t_div = t
                break
        if not div:                          # unreachable for a deterministic design;
            div = frontier                   # keep the loop honest if it ever trips
        shown = ", ".join(div[:4]) + (f" (+{len(div) - 4} more)" if len(div) > 4 else "")
        print(f"  [CEGAR         ] spurious: at cycle {t_div} the abstraction invented "
              f"{shown} -- the real run disagrees; re-concretize {len(div)} bit(s)")
        keep = [n for n in ts.state if n in kset or n in set(div)]
    return {"result": "UNKNOWN", "rounds": max_rounds, "kept": keep}


if __name__ == "__main__":
    from frontend import example
    from circuit import FALSE

    # the elevator interlock reads moving/door_open; floor and target are
    # irrelevant to it -- localization proves the property keeping 2 of 6 bits.
    ts = example("02_elevator_proof")
    r = cegar(ts)
    print(f"[cegar] elevator: {r['result']} in {r['rounds']} round(s); "
          f"kept {len(r['kept'])}/{len(ts.state)} bits: {r['kept']}")
    assert r["result"] == "SAFE" and len(r["kept"]) < len(ts.state)

    # the FIFO exercises the refinement: no-overflow names count/full, but the
    # first abstraction (full cut free) invents full=0 at count=4 -- the replay
    # disagrees, full is re-concretized, and the second round proves it.
    ts = example("03_fifo_proof")
    r = cegar(ts)
    print(f"[cegar] fifo: {r['result']} in {r['rounds']} round(s); "
          f"kept {len(r['kept'])}/{len(ts.state)} bits")
    assert r["result"] == "SAFE" and r["rounds"] == 2

    # a real bug must survive the replay and come back as a concrete trace
    buggy = example("03_fifo_proof")
    buggy.next["full"] = FALSE               # never set full -> overflow reachable
    rb = cegar(buggy)
    print(f"[cegar] buggy fifo: {rb['result']} at depth {rb.get('depth')} "
          f"(round {rb['rounds']})")
    assert rb["result"] == "UNSAFE"
    print("[cegar] OK: a proof on the abstraction is final; a real bug replays concretely")
