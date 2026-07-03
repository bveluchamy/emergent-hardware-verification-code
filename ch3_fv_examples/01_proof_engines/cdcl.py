"""
cdcl.py -- a from-scratch CDCL SAT solver.

This is the engine Chapter 3 calls "the V8 underneath the whole car": every
other engine in the proof-engine section (BMC, k-induction, interpolation,
IC3/PDR) ultimately asks this solver the same question -- is this Boolean
formula satisfiable? It implements Conflict-Driven Clause Learning exactly as
the chapter describes it:

  * unit propagation via two **watched literals** per clause,
  * **1-UIP** conflict analysis that turns every conflict into a permanent
    learned clause,
  * non-chronological **backjumping** to the asserting level,
  * **VSIDS** activity-based decisions with periodic decay,
  * geometric **restarts**.

Literals follow the DIMACS convention: a variable is an integer >= 1, and a
literal is the variable (positive) or its negation (negative). The public API
also supports incremental solving under **assumptions** and, on failure,
returns a genuine (not necessarily minimal) unsat core over them via
MiniSat-style analyzeFinal -- the interface production IC3/PDR implementations
lean on; the teaching ic3.py here builds a fresh per-query solver instead.
"""

from __future__ import annotations
from typing import Optional

from trace import T, fmt_lit, fmt_clause

LIT_UNDEF = 0


def var(lit: int) -> int:
    return abs(lit)


def neg(lit: int) -> int:
    return -lit


class Clause:
    __slots__ = ("lits", "learnt")

    def __init__(self, lits, learnt=False):
        self.lits = lits          # list[int]; lits[0], lits[1] are the watched literals
        self.learnt = learnt

    def __repr__(self):
        return f"Clause({self.lits})"


class Solver:
    def __init__(self):
        self.n_vars = 0
        self.clauses: list[Clause] = []
        self.learnts: list[Clause] = []
        # watches[p] = clauses in which ~p is a WATCHED literal -- the list to
        # visit when p becomes true and falsifies that watch (a dict keyed by the
        # signed literal)
        self.watches: dict[int, list[Clause]] = {}
        self.assign: dict[int, Optional[bool]] = {}   # var -> True/False/None
        self.level: dict[int, int] = {}               # var -> decision level
        self.reason: dict[int, Optional[Clause]] = {}  # var -> antecedent clause
        self.trail: list[int] = []                    # assigned literals, in order
        self.trail_lim: list[int] = []                # trail indices where each level began
        self.qhead = 0                                # propagation queue head into trail
        self.activity: dict[int, float] = {}
        self.var_inc = 1.0
        self.var_decay = 1.0 / 0.95
        self.phase: dict[int, bool] = {}              # saved phase for phase-saving
        self.seen: dict[int, bool] = {}
        self.conflict_core: list[int] = []            # failed assumptions after UNSAT
        self.names: dict[int, str] = {}               # var -> human label (for tracing)

    # ---- construction -------------------------------------------------------
    def new_var(self) -> int:
        self.n_vars += 1
        v = self.n_vars
        self.assign[v] = None
        self.level[v] = -1
        self.reason[v] = None
        self.activity[v] = 0.0
        self.phase[v] = False
        self.seen[v] = False
        self.watches.setdefault(v, [])
        self.watches.setdefault(-v, [])
        return v

    def new_vars(self, k: int) -> list[int]:
        return [self.new_var() for _ in range(k)]

    def value(self, lit: int) -> Optional[bool]:
        a = self.assign[var(lit)]
        if a is None:
            return None
        return a if lit > 0 else (not a)

    # ---- tracing helpers ----------------------------------------------------
    def _l(self, lit: int) -> str:
        return fmt_lit(lit, self.names)

    def _c(self, clause) -> str:
        lits = clause.lits if isinstance(clause, Clause) else clause
        return fmt_clause(lits, self.names)

    def add_clause(self, lits) -> bool:
        # Adding a clause is a ROOT-level operation: cancel any leftover
        # decision levels from a previous solve() first. Without this, a clause
        # that simplifies to a unit is judged against decision-level assignments
        # -- a unit contradicting a mere decision would permanently poison the
        # solver (_empty), and a unit enqueued at level > 0 would be erased by
        # the next solve()'s cancel and silently vanish.
        self._cancel_until(0)
        # simplify: drop falsified-at-root duplicates, detect tautology / unit
        seen = set()
        out = []
        for l in lits:
            if -l in seen:
                return True          # tautology x v -x
            if l in seen:
                continue
            seen.add(l)
            out.append(l)
        if len(out) == 0:
            self._empty = True       # empty clause -> UNSAT
            return False
        if len(out) == 1:
            ok = self._enqueue(out[0], None)
            if not ok:                   # a root unit that contradicts an existing one -> UNSAT
                self._empty = True
            return ok
        c = Clause(out, learnt=False)
        self.clauses.append(c)
        self._attach(c)
        return True

    def _attach(self, c: Clause):
        self.watches[neg(c.lits[0])].append(c)
        self.watches[neg(c.lits[1])].append(c)

    # ---- assignment / trail -------------------------------------------------
    def _enqueue(self, lit: int, reason: Optional[Clause]) -> bool:
        val = self.value(lit)
        if val is not None:
            return val            # already True -> fine; already False -> conflict (False)
        v = var(lit)
        self.assign[v] = (lit > 0)
        self.level[v] = self._decision_level()
        self.reason[v] = reason
        self.phase[v] = (lit > 0)
        self.trail.append(lit)
        return True

    def _decision_level(self) -> int:
        return len(self.trail_lim)

    def _new_decision_level(self):
        self.trail_lim.append(len(self.trail))

    def _cancel_until(self, lvl: int):
        if self._decision_level() <= lvl:
            return
        for i in range(len(self.trail) - 1, self.trail_lim[lvl] - 1, -1):
            v = var(self.trail[i])
            self.assign[v] = None
            self.reason[v] = None
            self.level[v] = -1
        del self.trail[self.trail_lim[lvl]:]
        del self.trail_lim[lvl:]
        self.qhead = min(self.qhead, len(self.trail))

    # ---- unit propagation (watched literals) --------------------------------
    def _propagate(self) -> Optional[Clause]:
        while self.qhead < len(self.trail):
            p = self.trail[self.qhead]
            self.qhead += 1
            ws = self.watches[p]          # clauses watching ~(...) such that p falsifies a watch
            i = 0
            new_ws = []
            conflict = None
            while i < len(ws):
                c = ws[i]
                i += 1
                false_lit = neg(p)
                # ensure the falsified literal is c.lits[1]
                if c.lits[0] == false_lit:
                    c.lits[0], c.lits[1] = c.lits[1], c.lits[0]
                first = c.lits[0]
                if self.value(first) is True:
                    new_ws.append(c)         # clause already satisfied; keep watch
                    continue
                # look for a new, non-false literal to watch
                found = False
                for k in range(2, len(c.lits)):
                    if self.value(c.lits[k]) is not False:
                        c.lits[1], c.lits[k] = c.lits[k], c.lits[1]
                        self.watches[neg(c.lits[1])].append(c)
                        found = True
                        break
                if found:
                    continue
                # no new watch: clause is unit (or conflicting) on `first`
                new_ws.append(c)
                if self.value(first) is False:
                    conflict = c
                    if T.on and T.deep:
                        T.say(f"✗ conflict: {self._c(c)} is fully falsified")
                    # keep the rest of the watch list intact
                    new_ws.extend(ws[i:])
                    self.watches[p] = new_ws
                    self.qhead = len(self.trail)
                    return conflict
                else:
                    if T.on and T.deep:
                        T.say(f"⇒ {self._l(first)} forced (unit clause {self._c(c)})")
                    self._enqueue(first, c)
            self.watches[p] = new_ws
        return None

    # ---- VSIDS --------------------------------------------------------------
    def _bump(self, v: int):
        self.activity[v] += self.var_inc
        if self.activity[v] > 1e100:
            for u in self.activity:
                self.activity[u] *= 1e-100
            self.var_inc *= 1e-100

    def _decay(self):
        self.var_inc *= self.var_decay

    def _pick_branch(self) -> int:
        best, best_a = 0, -1.0
        for v in range(1, self.n_vars + 1):
            if self.assign[v] is None and self.activity[v] > best_a:
                best, best_a = v, self.activity[v]
        if best == 0:
            return LIT_UNDEF
        return best if self.phase[best] else -best

    # ---- 1-UIP conflict analysis -------------------------------------------
    def _analyze(self, confl: Clause):
        learnt = [0]                 # placeholder for the asserting (1-UIP) literal
        counter = 0
        seen = self.seen
        p = 0
        idx = len(self.trail) - 1
        cur = self._decision_level()
        while True:
            for q in confl.lits:
                if q == p:
                    continue
                v = var(q)
                if not seen[v] and self.level[v] > 0:
                    seen[v] = True
                    self._bump(v)
                    if self.level[v] >= cur:
                        counter += 1
                    else:
                        learnt.append(q)
            # select next literal at the current level from the trail
            while not seen[var(self.trail[idx])]:
                idx -= 1
            p = self.trail[idx]
            seen[var(p)] = False
            counter -= 1
            if counter <= 0:
                break
            confl = self.reason[var(p)]
            idx -= 1
        learnt[0] = neg(p)           # the unique implication point, negated -> asserting
        # backjump level = second-highest level in `learnt`
        if len(learnt) == 1:
            bj = 0
        else:
            mx = 1
            for k in range(2, len(learnt)):
                if self.level[var(learnt[k])] > self.level[var(learnt[mx])]:
                    mx = k
            learnt[1], learnt[mx] = learnt[mx], learnt[1]
            bj = self.level[var(learnt[1])]
        for q in learnt:
            seen[var(q)] = False
        return learnt, bj

    def _record(self, learnt):
        if len(learnt) == 1:
            self._cancel_until(0)
            self._enqueue(learnt[0], None)
        else:
            c = Clause(learnt, learnt=True)
            self.learnts.append(c)
            self._attach(c)
            self._enqueue(learnt[0], c)

    # ---- main search --------------------------------------------------------
    def solve(self, assumptions=None) -> bool:
        assumptions = assumptions or []
        if getattr(self, "_empty", False):
            if T.on and T.deep:
                T.say("an empty clause was added at construction → UNSAT immediately")
            return False
        self._cancel_until(0)
        self.qhead = 0           # re-propagate root facts against any clauses added since the last solve (incremental use)
        self.conflict_core = []
        if T.on and T.deep:
            T.say(f"CDCL search: {self.n_vars} vars, {len(self.clauses)} clauses"
                  + (f", {len(assumptions)} assumption(s) [{', '.join(self._l(a) for a in assumptions)}]"
                     if assumptions else ""))
        # propagate root-level units first
        if self._propagate() is not None:
            if T.on and T.deep:
                T.say("root-level unit propagation hits a conflict → UNSAT")
            return False
        restart_base, restart_at, conflicts = 100, 100, 0
        ui = 0  # next assumption index
        while True:
            confl = self._propagate()
            if confl is not None:
                conflicts += 1
                if self._decision_level() == 0:
                    if T.on and T.deep:
                        T.say("conflict at decision level 0 → UNSAT")
                    return False
                learnt, bj = self._analyze(confl)
                if T.on and T.deep:
                    T.say(f"  1-UIP analysis ⇒ learn {self._c(learnt)}, backjump to level {bj}")
                self._cancel_until(bj)
                ui = 0        # a backjump can unassign an assumption decided at a level
                              # above bj; re-scan assumptions from the start so a dropped
                              # one is re-established (else solve() may violate it)
                self._record(learnt)
                self._decay()
                if conflicts >= restart_at:
                    if T.on and T.deep:
                        T.say(f"  restart after {conflicts} conflicts (keep learned clauses)")
                    self._cancel_until(0)
                    ui = 0        # a restart wipes the assumption decisions -> re-apply them
                                  # from the start; without this the assumptions are silently
                                  # dropped and solve() can return a model that violates them
                    restart_base = self._restart_next(restart_base)
                    restart_at = conflicts + restart_base
            else:
                # honor assumptions as the first decisions
                if ui < len(assumptions):
                    a = assumptions[ui]
                    ui += 1
                    val = self.value(a)
                    if val is True:
                        continue
                    if val is False:
                        # assumption conflicts with current state -> UNSAT under assumptions
                        if T.on and T.deep:
                            T.say(f"assumption {self._l(a)} contradicts the trail → UNSAT under assumptions")
                        self.conflict_core = self._assumption_core(a, assumptions[:ui])
                        return False
                    if T.on and T.deep:
                        T.say(f"assume {self._l(a)} @ level {self._decision_level() + 1}")
                    self._new_decision_level()
                    self._enqueue(a, None)
                    continue
                lit = self._pick_branch()
                if lit == LIT_UNDEF:
                    if T.on and T.deep:
                        T.say(f"all {self.n_vars} vars assigned, no conflict → SAT")
                    return True       # all variables assigned, no conflict -> SAT
                if T.on and T.deep:
                    T.say(f"decide {self._l(lit)} @ level {self._decision_level() + 1} (VSIDS pick)")
                self._new_decision_level()
                self._enqueue(lit, None)

    def _assumption_core(self, failed, assumed_so_far):
        """Failed-assumption analysis (MiniSat's analyzeFinal): from the
        assignment that falsifies `failed`, walk reason clauses TRANSITIVELY;
        the assumptions whose decisions are reached -- plus `failed` itself --
        are jointly unsatisfiable with the clause set. A genuine core, though
        not necessarily minimal. (The one-step predecessor of this routine
        looked only at the immediate reason clause and could return a set that
        was still satisfiable -- an under-approximation, the unsound direction.)"""
        assumed = set(assumed_so_far)
        core = {failed}
        seen = {var(failed)}
        stack = [var(failed)]
        while stack:
            v = stack.pop()
            r = self.reason[v]
            if r is None:                       # a decision: an assumption if assumed
                for a in assumed:
                    if var(a) == v:
                        core.add(a)
                continue
            for q in r.lits:
                u = var(q)
                if u not in seen and self.level[u] > 0:
                    seen.add(u)
                    stack.append(u)
        return [a for a in assumed_so_far if a in core]

    def _restart_next(self, prev):
        # geometric restart growth is plenty for these instances
        return max(100, int(prev * 1.5))

    # ---- results ------------------------------------------------------------
    def model(self) -> dict[int, bool]:
        return {v: (self.assign[v] if self.assign[v] is not None else False)
                for v in range(1, self.n_vars + 1)}

    def get_value(self, v: int) -> bool:
        a = self.assign[v]
        return a if a is not None else False


if __name__ == "__main__":
    # tiny self-tests
    s = Solver(); a, b, c = s.new_vars(3)
    s.add_clause([a, b]); s.add_clause([-a, c]); s.add_clause([-b, c]); s.add_clause([-c])
    assert s.solve() is False, "expected UNSAT"     # forces c, but -c
    print("[cdcl] UNSAT case ok")

    s = Solver(); a, b, c = s.new_vars(3)
    s.add_clause([a, b]); s.add_clause([-a, c]); s.add_clause([-b, c])
    assert s.solve() is True, "expected SAT"
    m = s.model(); assert (m[a] or m[b]) and (not m[a] or m[c]) and (not m[b] or m[c])
    print("[cdcl] SAT case ok, model =", {1: m[a], 2: m[b], 3: m[c]})

    # pigeonhole PHP(3,2) is UNSAT -- 3 pigeons, 2 holes
    s = Solver()
    p = {(i, j): s.new_var() for i in range(3) for j in range(2)}
    for i in range(3):
        s.add_clause([p[(i, 0)], p[(i, 1)]])                 # each pigeon in some hole
    for j in range(2):
        for i1 in range(3):
            for i2 in range(i1 + 1, 3):
                s.add_clause([-p[(i1, j)], -p[(i2, j)]])     # no two pigeons share a hole
    assert s.solve() is False
    print("[cdcl] PHP(3,2) UNSAT ok")
    print("[cdcl] all self-tests passed")
