"""
ic3.py -- IC3 / PDR (Property-Directed Reachability).

The engine Chapter 3 says "closes most industrial proofs without ever unrolling
the design." It keeps a sequence of frames F_0=Init, F_1, ..., F_k, each an
over-approximation of the states reachable in at most that many steps, every one
implying the property. When the frontier F_k admits a one-step move to a bad
state, IC3 takes that bad cube as a proof obligation and tries to push its
negation backward: if the cube has no predecessor in the previous frame, its
negation is *inductive relative to that frame*, gets generalized to a small
clause (dropping the literals that don't matter -- the FIFO's payload, the
elevator's floor), and is added to block it everywhere below. When propagation
carries every clause forward and two adjacent frames coincide, the converged
frame is an inductive invariant -- a proof.

On the FIFO this is where the hidden relationship the RTL never states gets
*discovered*: IC3 learns, clause by clause, exactly full <-> count=4, fences the
garbage out, and converges. The elevator converges immediately.

Two implementation moves from Eén--Mishchenko--Brayton's PDR (FMCAD 2011 -- the
reference implementation is ABC's `pdr`) keep the engine off the exponential
paths: every SAT witness is **ternary-lifted** (circuit.ternary_eval) from a
full minterm to a short cube before it becomes a proof obligation, and every
query Tseitin-encodes only the **cone it actually reads** rather than the whole
transition relation.
"""

from __future__ import annotations
from cdcl import Solver
from circuit import tseitin, ternary_eval, support
from trace import T

Cube = frozenset    # frozenset of signed state-bit indices (1-based)


class IC3:
    def __init__(self, ts):
        self.ts = ts
        self.S = ts.state
        self.frames: list[set] = [set(), set()]   # frames[0]=Init (special), F_1 = true
        self.cex = None
        self._sig_sup: dict = {}                  # Sig.id -> its support (cached COI)

    # ---- query construction -------------------------------------------------
    def _query(self, need=None):
        """A fresh solver over one step. `need` names the state bits whose next-state
        functions this query actually constrains; only those cones are Tseitin-encoded.
        A wide design's full transition relation is thousands of gates -- loading all
        of it into a query that reads two bits of it buys nothing. None = every bit."""
        s = Solver()
        cur = {n: s.new_var() for n in self.S}
        for inp in self.ts.inputs:
            cur[inp] = s.new_var()
        memo = {}
        nxt = {n: tseitin(s, self.ts.next[n], cur, memo)
               for n in (self.S if need is None else need)}
        s._memo = memo
        return s, cur, nxt

    def _cur(self, cur, l):
        v = cur[self.S[abs(l) - 1]]
        return v if l > 0 else -v

    def _nxt(self, nxt, l):
        v = nxt[self.S[abs(l) - 1]]
        return v if l > 0 else -v

    def _assert_init(self, s, cur):
        for i, n in enumerate(self.S):
            s.add_clause([self._cur(cur, (i + 1) if self.ts.init[n] else -(i + 1))])

    def _assert_frame(self, s, cur, i):
        if i == 0:
            self._assert_init(s, cur)
            return
        for j in range(i, len(self.frames)):
            for cl in self.frames[j]:
                s.add_clause([self._cur(cur, l) for l in cl])

    def _bad_in(self, s, cur, mp):       # add the property-violation literal over a map
        from circuit import tseitin as _t
        return _t(s, self.ts.bad, mp, getattr(s, "_memo", {}))

    def _state_cube(self, s, cur) -> Cube:
        return frozenset((i + 1) if s.get_value(cur[self.S[i]]) else -(i + 1)
                         for i in range(len(self.S)))

    def _model_env(self, s, cur) -> dict:
        """The SAT model's concrete valuation of every state bit and input."""
        env = {n: (1 if s.get_value(cur[n]) else 0) for n in self.S}
        for inp in self.ts.inputs:
            env[inp] = 1 if s.get_value(cur[inp]) else 0
        return env

    def _sup_of(self, sig) -> frozenset:
        sup = self._sig_sup.get(sig.id)
        if sup is None:
            sup = self._sig_sup[sig.id] = support(sig)
        return sup

    def _lift(self, env, targets) -> Cube:
        """Ternary lifting of a SAT witness (Eén--Mishchenko--Brayton FMCAD 2011 --
        the move ABC's `pdr` makes on every predecessor). `env` is the model's
        concrete state+input valuation; `targets` are (Sig, required value) pairs
        that witnessed the query -- the successor cube's next-state functions, or
        the bad predicate. A state bit is dropped when the targets stay definite at
        their required values with the bit X'd: by ternary monotonicity every
        completion of the X's still makes the same transition, so the shortened
        cube is one proof obligation speaking for 2^dropped states instead of one.
        Inputs stay concrete -- the cube quantifies over states; the input is the
        recorded witness. This is what keeps IC3 from enumerating minterms."""
        lifted = dict(env)
        sups = [self._sup_of(t) for t, _ in targets]
        cone = frozenset().union(*sups) if sups else frozenset()
        n_free = n_sim = 0
        for n in self.S:                      # free drops: bits no target reads
            if n not in cone:
                lifted[n] = None
                n_free += 1
        for n in self.S:                      # simulated drops: X it, targets must stay definite
            if lifted[n] is None:
                continue
            saved = lifted[n]
            lifted[n] = None
            memo = {}
            if all(ternary_eval(t, lifted, memo) == req
                   for (t, req), sup in zip(targets, sups) if n in sup):
                n_sim += 1
            else:
                lifted[n] = saved
        cube = frozenset((i + 1) if lifted[n] == 1 else -(i + 1)
                         for i, n in enumerate(self.S) if lifted[n] is not None)
        if not cube:
            # a bad predicate reading only inputs can drop every state bit; keep the
            # minterm -- the blocking machinery needs at least one literal to work on
            cube = frozenset((i + 1) if env[n] else -(i + 1) for i, n in enumerate(self.S))
        if T.on and len(cube) < len(self.S):
            T.say(f"  ternary lift: {len(self.S)}-bit minterm → {len(cube)} literal(s) "
                  f"({n_free} outside the targets' cone, {n_sim} X'd by simulation)")
        return cube

    # ---- core IC3 -----------------------------------------------------------
    def _bad_cube(self, k):
        """A state in F_k that violates P, ternary-lifted to a cube (or None)."""
        s, cur, _ = self._query(need=())
        self._assert_frame(s, cur, k)
        bad = tseitin(s, self.ts.bad, cur, s._memo)
        s.add_clause([bad])
        if s.solve():
            return self._lift(self._model_env(s, cur), [(self.ts.bad, 1)])
        return None

    def _predecessor(self, cube: Cube, i):
        """A predecessor of `cube` inside F_{i}, not equal to `cube`, ternary-lifted:
        every state of the returned cube steps into `cube` under the recorded input.
        None if ¬cube is inductive relative to F_i."""
        s, cur, nxt = self._query(need=[self.S[abs(l) - 1] for l in cube])
        self._assert_frame(s, cur, i)
        # current state is NOT in cube (the asserting clause ¬cube)
        s.add_clause([self._cur(cur, -l) for l in cube])
        # next state IS in cube
        for l in cube:
            s.add_clause([self._nxt(nxt, l)])
        if s.solve():
            targets = [(self.ts.next[self.S[abs(l) - 1]], 1 if l > 0 else 0)
                       for l in cube]
            return self._lift(self._model_env(s, cur), targets)
        return None

    def _init_intersects(self, cube: Cube) -> bool:
        s, cur, _ = self._query(need=())
        self._assert_init(s, cur)
        for l in cube:
            s.add_clause([self._cur(cur, l)])
        return s.solve()

    def _inductive_rel(self, clause, i) -> bool:
        """Is `clause` (= ¬cube) inductive relative to F_i? i.e. F_i ∧ clause ∧ T ⇒ clause'.
        We look for a counterexample: an F_i-state where `clause` holds that steps to a
        state where `clause` is *violated*. A clause is violated only when every literal
        is false, so clause' violated = ⋀ ¬l' (each a unit) -- not the disjunction, which
        would be far weaker and leave generalization unable to drop any literal."""
        s, cur, nxt = self._query(need=[self.S[abs(l) - 1] for l in clause])
        self._assert_frame(s, cur, i)
        s.add_clause([self._cur(cur, l) for l in clause])       # clause holds now
        for l in clause:
            s.add_clause([self._nxt(nxt, -l)])                  # clause' violated next: ⋀ ¬l'
        return not s.solve()

    def _generalize(self, cube: Cube, i) -> Cube:
        """Minimal inductive cube: drop literals while ¬cube stays init-safe and
        inductive relative to F_{i-1}."""
        cube = set(cube)
        for l in list(cube):
            cand = cube - {l}
            if not cand:
                continue
            clause = frozenset(-x for x in cand)
            if not self._init_intersects(frozenset(cand)) and self._inductive_rel(clause, i - 1):
                cube = cand
        return frozenset(cube)

    def _add_blocked(self, clause, upto):
        """Add `clause` to F_1..F_upto, removing every clause it subsumes on the way.
        A clause with fewer literals blocks a strictly larger region, so the fat one
        it replaces only taxes each later query's frame assertion (PDR's clause
        management, Eén--Mishchenko--Brayton §5)."""
        for j in range(1, upto + 1):
            F = self.frames[j]
            F.difference_update([cl for cl in F if clause < cl])
            F.add(clause)

    def _block(self, bad: Cube, k) -> bool:
        """Block `bad` at level k by discharging proof obligations backward."""
        import heapq
        Q = [(k, bad)]
        while Q:
            i, s = heapq.heappop(Q)
            if i == 0:
                if self._init_intersects(s):
                    self.cex = s            # init can reach bad -> real CEX
                    return False
                continue
            pred = self._predecessor(s, i - 1)
            if pred is None:
                g = self._generalize(s, i)              # ¬g inductive rel F_{i-1}
                clause = frozenset(-l for l in g)
                self._add_blocked(clause, i)
                if T.on:
                    T.say(f"obligation {self.cube_str(s)} @F_{i}: no predecessor in F_{i-1} → "
                          f"¬cube is inductive; generalize to {len(g)}/{len(s)} literals and")
                    T.say(f"  learn {self.clause_str(clause)} into F_1..F_{i}")
                if i < len(self.frames) - 1:
                    heapq.heappush(Q, (i + 1, s))        # re-queue at the next frame
            else:
                if T.on:
                    T.say(f"obligation {self.cube_str(s)} @F_{i}: has a predecessor "
                          f"{self.cube_str(frozenset(pred))} in F_{i-1} → block that first")
                heapq.heappush(Q, (i - 1, frozenset(pred)))   # block predecessor first
                heapq.heappush(Q, (i, s))
        return True

    def _propagate(self):
        for i in range(1, len(self.frames) - 1):
            for cl in list(self.frames[i]):
                if cl in self.frames[i + 1]:
                    continue
                if self._inductive_rel(cl, i):
                    F = self.frames[i + 1]
                    F.difference_update([c2 for c2 in F if cl < c2])   # subsumption
                    F.add(cl)
            if self.frames[i] and self.frames[i].issubset(self.frames[i + 1]):
                return i + 1        # F_i == F_{i+1}: converged
        return None

    def solve(self, max_frames=40):
        if T.on:
            T.rule("IC3 / PDR -- frames of over-approximation, no unrolling")
            T.say("F_0=Init, each F_i ⊇ states reachable in ≤i steps and ⊆ P. Push bad")
            T.say("cubes backward; a cube with no predecessor gives a clause to block it.")
        # property must hold initially
        if self._init_intersects_bad():
            if T.on:
                T.say("Init already intersects bad → UNSAFE at step 0")
            return {"result": "UNSAFE", "depth": 0}
        while len(self.frames) - 1 < max_frames:
            k = len(self.frames) - 1
            if T.on:
                T.say(f"frontier k={k}: any state in F_{k} that can step to bad?")
            while True:
                bad = self._bad_cube(k)
                if bad is None:
                    break
                if T.on:
                    T.say(f"  found a bad predecessor {self.cube_str(bad)} in F_{k}; discharge it backward")
                with T.section(""):
                    if not self._block(bad, k):
                        if T.on:
                            T.say("obligation reached Init → the bad state is reachable → UNSAFE")
                        return {"result": "UNSAFE", "frames": k}
            if T.on:
                T.say(f"  F_{k} frontier is clean (no move to bad)")
            # A clean frontier with no clause ever learned means the property
            # holds in *every* state (0-inductive) -- "true" is already an
            # inductive invariant (e.g. a combinationally-valid FSM output).
            if all(not f for f in self.frames[1:]):
                if T.on:
                    T.say("no clause was ever needed → P holds in every state (0-inductive). SAFE.")
                return {"result": "SAFE", "frames": k, "invariant": set()}
            self.frames.append(set())
            conv = self._propagate()
            if conv is not None:
                inv = set()
                for j in range(conv, len(self.frames)):
                    inv |= self.frames[j]
                if T.on:
                    T.say(f"propagation makes F_{conv-1} = F_{conv}: converged. The frame is an")
                    T.say(f"inductive invariant ({len(inv)} clause(s)). SAFE.")
                return {"result": "SAFE", "frames": k, "invariant": inv}
        return {"result": "UNKNOWN", "frames": max_frames}

    def _init_intersects_bad(self):
        s, cur, _ = self._query(need=())
        self._assert_init(s, cur)
        s.add_clause([tseitin(s, self.ts.bad, cur, s._memo)])
        return s.solve()

    # ---- pretty-print a learned clause as a state condition -----------------
    def clause_str(self, clause) -> str:
        parts = []
        for l in sorted(clause, key=lambda x: abs(x)):
            n = self.S[abs(l) - 1]
            parts.append(n if l > 0 else f"!{n}")
        return "(" + " | ".join(parts) + ")"

    def cube_str(self, cube, cap=12) -> str:
        parts = []
        for l in sorted(cube, key=lambda x: abs(x)):
            n = self.S[abs(l) - 1]
            parts.append(n if l > 0 else f"!{n}")
        # a wide cube (a datapath's worth of bits) in full is not more instructive than
        # its first few literals -- cap the narration so a trace stays readable.
        if len(parts) > cap:
            parts = parts[:cap] + [f"…(+{len(parts) - cap} more)"]
        return "{" + " & ".join(parts) + "}"


if __name__ == "__main__":
    from frontend import example
    build_elevator = lambda: example("02_elevator_proof")
    build_fifo = lambda: example("03_fifo_proof")

    r = IC3(build_elevator()).solve()
    print(f"[ic3] elevator: {r['result']} (in {r.get('frames')} frames)")
    assert r["result"] == "SAFE"

    eng = IC3(build_fifo())
    r = eng.solve()
    print(f"[ic3] fifo:     {r['result']} (in {r.get('frames')} frames); "
          f"learned {len(r.get('invariant', []))} invariant clause(s):")
    for cl in sorted(r.get("invariant", []), key=lambda c: sorted(c, key=abs)):
        print("        " + eng.clause_str(cl))
    assert r["result"] == "SAFE"
    # the invariant must fence out the garbage the book names -- count=4 & full=0, the
    # unreachable state from which a push overflows. (With proper generalization IC3
    # now learns the tighter clauses count[2]→full and full→¬count[0..1], which
    # together imply that fence rather than stating it verbatim.)
    garbage = {"count[0]": 0, "count[1]": 0, "count[2]": 1, "full": 0}   # count=4, full=0
    def _sat_lit(l):
        v = garbage.get(eng.S[abs(l) - 1], 0)
        return (v == 1) if l > 0 else (v == 0)
    excluded = any(not any(_sat_lit(l) for l in cl) for cl in r["invariant"])
    assert excluded, "IC3's invariant must exclude the count=4 & full=0 overflow garbage"
    print(f"[ic3] OK: IC3 proved the FIFO; its {len(r['invariant'])}-clause invariant pins the "
          f"full/count relation and fences out count=4 & full=0")

    # and a sanity check that it really is a model checker: inject a bug -> UNSAFE
    buggy = build_fifo()
    buggy.next["full"] = __import__("circuit").FALSE   # never set the full flag (overflow possible)
    rb = IC3(buggy).solve()
    print(f"[ic3] buggy fifo (full stuck at 0): {rb['result']}")
    assert rb["result"] == "UNSAFE"
    print("[ic3] OK: finds the real counterexample when the invariant genuinely fails")
