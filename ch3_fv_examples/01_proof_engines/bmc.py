"""
bmc.py -- Bounded Model Checking.

Unroll the transition relation from reset to depth k and ask CDCL whether any
reachable state within k steps violates the property. SAT at depth k is a
concrete counterexample trace; UNSAT to a chosen bound is "no bug that shallow"
-- a bug finder, not (by itself) a proof. On both of Chapter 3's examples,
anchored at reset, every query is UNSAT: the elevator is safe, and the FIFO's
incremental `full` logic keeps `full <-> count=4` so the garbage state the
one-step query found is never reached from reset.
"""

from __future__ import annotations
from cdcl import Solver
from circuit import (TransitionSystem, fresh_frame, next_env, assert_init,
                     bad_lit, read_bv)
from trace import T


def tie(solver, ts: TransitionSystem, env_from: dict, env_to: dict):
    """Constrain env_to's state vars to equal the next-state of env_from."""
    nxt = next_env(solver, ts, env_from)
    for st in ts.state:
        a, b = nxt[st], env_to[st]
        solver.add_clause([-a, b])
        solver.add_clause([a, -b])


def unroll(solver, ts: TransitionSystem, k: int, from_init=True):
    envs = [fresh_frame(solver, ts, 0)]
    if from_init:
        assert_init(solver, ts, envs[0])
    for i in range(k):
        envs.append(fresh_frame(solver, ts, i + 1))
        tie(solver, ts, envs[i], envs[i + 1])
    return envs


def trace(solver, ts, envs):
    """Decode a per-frame valuation of the state vars for a SAT result."""
    out = []
    for env in envs:
        row = {}
        seen_bv = set()
        for st in ts.state:
            base = st.split("[")[0]
            if "[" in st and base not in seen_bv:
                seen_bv.add(base)
                w = sum(1 for x in ts.state if x.startswith(base + "["))
                row[base] = read_bv(solver, env, base, w)
            elif "[" not in st:
                row[st] = int(solver.get_value(env[st]))
        out.append(row)
    return out


def bmc(ts: TransitionSystem, kmax: int):
    if T.on:
        T.rule("BMC -- unroll from reset, hunt a counterexample")
        T.say("build init(s0) ∧ T(s0,s1) ∧ … ∧ T(s_{k-1},s_k), then ask if bad(s_k) can hold.")
    for k in range(kmax + 1):
        s = Solver()
        envs = unroll(s, ts, k, from_init=True)
        s.add_clause([bad_lit(s, ts, envs[k])])
        if T.on:
            T.say(f"depth k={k}: is a bad state reachable in exactly {k} step(s) from reset?")
        with T.section(""):
            sat = s.solve()
        if sat:
            tr = trace(s, ts, envs)
            if T.on:
                T.say(f"  SAT → real counterexample, {k} step(s) from reset:")
                with T.section(""):
                    for i, row in enumerate(tr):
                        T.say(f"cycle {i}: {row}")
            return {"result": "CEX", "depth": k, "trace": tr}
        if T.on:
            T.say(f"  UNSAT → no counterexample of length {k}")
    if T.on:
        T.say(f"no counterexample up to depth {kmax}: a bug finder, not (yet) a proof.")
    return {"result": "SAFE-UP-TO", "depth": kmax}


if __name__ == "__main__":
    from frontend import example
    for ts in (example("02_elevator_proof"), example("03_fifo_proof")):
        r = bmc(ts, 12)
        print(f"[bmc] {ts.name:8s}: {r['result']} (depth {r['depth']})")
        assert r["result"] == "SAFE-UP-TO"
    print("[bmc] OK: both safe up to depth 12 from reset (the FIFO never reaches the garbage)")
