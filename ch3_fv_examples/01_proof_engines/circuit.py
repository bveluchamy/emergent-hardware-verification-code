"""
circuit.py -- the "frontend, just enough to demo": a tiny gate / transition-
system DSL that Tseitin-encodes to CNF for cdcl.Solver.

Chapter 3 turns gates into clauses "by a chain of equivalences" -- that is
Tseitin encoding, and it is what this module does. You build the next-state
logic of a design as a DAG of Boolean signals (and bitvectors over them);
`tseitin()` allocates one fresh CNF variable per gate and emits its defining
clauses. A `TransitionSystem` bundles the state bits, their next-state
functions, the reset state, and the "bad" predicate (the property's negation).
The unrolling helpers (`fresh_frame`, `unroll`, `one_step`) instantiate that
logic across time frames -- the substrate BMC, k-induction, interpolation, and
IC3 all build on.
"""

from __future__ import annotations
from typing import Optional

from trace import T


# ---------------------------------------------------------------------------
# Signals: a small AIG-flavored DAG with structural simplification.
# ---------------------------------------------------------------------------
class Sig:
    _n = 0
    __slots__ = ("id", "kind", "args", "name", "val")

    def __init__(self, kind, args=(), name=None, val=None):
        self.id = Sig._n
        Sig._n += 1
        self.kind = kind          # 'const' 'var' 'not' 'and' 'or' 'xor' 'ite'
        self.args = tuple(args)
        self.name = name
        self.val = val


def CONST(b) -> Sig:
    return Sig("const", val=bool(b))


TRUE = CONST(True)
FALSE = CONST(False)


def VAR(name) -> Sig:
    return Sig("var", name=name)


def NOT(a: Sig) -> Sig:
    if a.kind == "const":
        return CONST(not a.val)
    if a.kind == "not":
        return a.args[0]
    return Sig("not", args=(a,))


def AND(*xs) -> Sig:
    out = []
    for x in xs:
        if x.kind == "const":
            if not x.val:
                return FALSE
            continue
        out.append(x)
    if not out:
        return TRUE
    if len(out) == 1:
        return out[0]
    return Sig("and", args=tuple(out))


def OR(*xs) -> Sig:
    out = []
    for x in xs:
        if x.kind == "const":
            if x.val:
                return TRUE
            continue
        out.append(x)
    if not out:
        return FALSE
    if len(out) == 1:
        return out[0]
    return Sig("or", args=tuple(out))


def XOR(a: Sig, b: Sig) -> Sig:
    if a.kind == "const":
        return b if not a.val else NOT(b)
    if b.kind == "const":
        return a if not b.val else NOT(a)
    return Sig("xor", args=(a, b))


def XNOR(a: Sig, b: Sig) -> Sig:
    return NOT(XOR(a, b))


def IMPLIES(a: Sig, b: Sig) -> Sig:
    return OR(NOT(a), b)


def IFF(a: Sig, b: Sig) -> Sig:
    return XNOR(a, b)


def ITE(c: Sig, t: Sig, e: Sig) -> Sig:
    if c.kind == "const":
        return t if c.val else e
    return Sig("ite", args=(c, t, e))


# ---------------------------------------------------------------------------
# Tseitin encoding to a cdcl.Solver, under an environment mapping VAR names to
# literals. `memo` caches per-encoding-context (one per time frame).
# ---------------------------------------------------------------------------
def _true_lit(solver):
    t = getattr(solver, "_true_lit", None)
    if t is None:
        t = solver.new_var()
        solver.add_clause([t])
        solver._true_lit = t
    return t


_OP_SYM = {"and": " ∧ ", "or": " ∨ ", "xor": " ⊕ "}


def _name_gate(solver, sig, ls, y):
    """Give aux var `y` a readable compositional label built from its inputs, so
    a traced CDCL decision prints `(moving ∧ ¬door_open)` instead of `x47`."""
    from trace import fmt_lit
    if sig.kind == "ite":
        nm = f"({fmt_lit(ls[0], solver.names)} ? {fmt_lit(ls[1], solver.names)} : {fmt_lit(ls[2], solver.names)})"
    else:
        nm = "(" + _OP_SYM[sig.kind].join(fmt_lit(l, solver.names) for l in ls) + ")"
    solver.names[y] = nm if len(nm) <= 46 else f"g{y}"


def tseitin(solver, sig: Sig, env: dict, memo: dict) -> int:
    if sig.kind == "const":
        t = _true_lit(solver)
        return t if sig.val else -t
    if sig.kind == "var":
        return env[sig.name]
    if sig.id in memo:
        return memo[sig.id]
    if sig.kind == "not":
        r = -tseitin(solver, sig.args[0], env, memo)
        memo[sig.id] = r
        return r
    ls = [tseitin(solver, a, env, memo) for a in sig.args]
    y = solver.new_var()
    if sig.kind == "and":
        cls = [[-y, l] for l in ls] + [[y] + [-l for l in ls]]        # y <-> (l1 & ... & ln)
    elif sig.kind == "or":
        cls = [[-y] + list(ls)] + [[y, -l] for l in ls]               # y <-> (l1 | ... | ln)
    elif sig.kind == "xor":
        a, b = ls
        cls = [[-y, -a, -b], [-y, a, b], [y, -a, b], [y, a, -b]]      # y <-> (a ^ b)
    elif sig.kind == "ite":
        c, t, e = ls
        cls = [[-c, -t, y], [-c, t, -y], [c, -e, y], [c, e, -y]]      # y <-> (c ? t : e)
    else:
        raise ValueError(sig.kind)
    if T.on:
        _name_gate(solver, sig, ls, y)
    for cl in cls:
        solver.add_clause(cl)
    if T.on and getattr(solver, "_echo_enc", False):
        from trace import fmt_lit, fmt_clause
        args = ", ".join(fmt_lit(l, solver.names) for l in ls)
        T.say(f"{fmt_lit(y, solver.names)}  ⇔  {sig.kind}({args})")
        with T.section(""):
            for cl in cls:
                T.say(fmt_clause(cl, solver.names))
    memo[sig.id] = y
    return y


def count_gates(sig: "Sig") -> int:
    """Number of distinct non-leaf nodes in the signal DAG -- the count of aux
    variables a Tseitin encoding of `sig` introduces."""
    seen = set()

    def go(s):
        if s.kind in ("const", "var") or s.id in seen:
            return
        seen.add(s.id)
        for a in s.args:
            go(a)
    go(sig)
    return len(seen)


def sig_str(sig: "Sig", maxdepth: int = 6) -> str:
    """Compact infix rendering of a signal DAG -- for narrating a next-state
    function or the `bad` predicate before it is bit-blasted."""
    def go(s, d):
        if s.kind == "const":
            return "1'b1" if s.val else "1'b0"
        if s.kind == "var":
            return s.name
        if d >= maxdepth:
            return "…"
        if s.kind == "not":
            return "¬" + go(s.args[0], d + 1)
        if s.kind == "ite":
            return f"({go(s.args[0], d+1)} ? {go(s.args[1], d+1)} : {go(s.args[2], d+1)})"
        return "(" + _OP_SYM[s.kind].join(go(a, d + 1) for a in s.args) + ")"
    return go(sig, 0)


# ---------------------------------------------------------------------------
# Ternary (three-valued) simulation: evaluate a signal DAG over {0, 1, X}.
#
# X means "unknown -- could be either". The gate rules are Kleene's strong
# three-valued logic: a gate answers definitely only when its inputs force the
# answer (0 AND anything = 0; 1 OR anything = 1), and says X otherwise. The
# load-bearing property is *monotonicity in information*: refining an input
# from X to 0 or 1 can never flip a definite output, only sharpen an X. So a
# definite output under some X'd inputs is a PROOF that every completion of
# those X's produces that same output -- which is exactly the license IC3/PDR
# uses to drop the X'd state bits from a predecessor cube (ternary lifting,
# Eén--Mishchenko--Brayton FMCAD 2011; ABC's `pdr`).
#
# The price is X-pessimism: reconvergent fanout loses correlation (v OR NOT v
# evaluates to X, though every completion gives 1), so ternary lifting keeps
# some literals a SAT-based lifter would drop. That is the accepted trade --
# each drop attempt costs one linear-time simulation instead of a SAT call.
# ---------------------------------------------------------------------------
def ternary_eval(sig: "Sig", env: dict, memo: Optional[dict] = None):
    """Evaluate `sig` under `env` mapping VAR name -> 0 / 1 / None (None = X).
    Returns 0, 1, or None. Iterative post-order (the MSI cache's next-state
    cones are thousands of gates deep -- no recursion limit to trip). A shared
    `memo` (keyed by Sig.id) may be passed when evaluating several signals
    under the SAME env."""
    if memo is None:
        memo = {}
    stack = [sig]
    while stack:
        s = stack[-1]
        if s.id in memo:
            stack.pop()
            continue
        if s.kind == "const":
            memo[s.id] = 1 if s.val else 0
            stack.pop()
            continue
        if s.kind == "var":
            memo[s.id] = env[s.name]
            stack.pop()
            continue
        todo = [a for a in s.args if a.id not in memo]
        if todo:
            stack.extend(todo)
            continue
        vals = [memo[a.id] for a in s.args]
        if s.kind == "not":
            v = vals[0]
            r = None if v is None else 1 - v
        elif s.kind == "and":
            r = (0 if any(v == 0 for v in vals)
                 else None if any(v is None for v in vals) else 1)
        elif s.kind == "or":
            r = (1 if any(v == 1 for v in vals)
                 else None if any(v is None for v in vals) else 0)
        elif s.kind == "xor":
            a, b = vals
            r = None if (a is None or b is None) else a ^ b
        elif s.kind == "ite":
            c, t, e = vals
            if c is not None:
                r = t if c == 1 else e
            else:
                # both branches agreeing rescues an unknown select -- a node-level
                # rule slightly sharper than a gate netlist of the same mux
                r = t if (t == e and t is not None) else None
        else:
            raise ValueError(s.kind)
        memo[s.id] = r
        stack.pop()
    return memo[sig.id]


def support(sig: "Sig") -> frozenset:
    """The VAR names `sig` structurally reads -- its cone of influence. A state
    bit outside a target's support can be dropped from a predecessor cube with
    no simulation at all (the free half of ternary lifting)."""
    seen, out, stack = set(), set(), [sig]
    while stack:
        s = stack.pop()
        if s.id in seen:
            continue
        seen.add(s.id)
        if s.kind == "var":
            out.add(s.name)
        else:
            stack.extend(s.args)
    return frozenset(out)


# ---------------------------------------------------------------------------
# Bitvectors: LSB-first lists of Sig.
# ---------------------------------------------------------------------------
class BV:
    def __init__(self, bits):
        self.bits = list(bits)

    @property
    def width(self):
        return len(self.bits)


def bv_var(name, w) -> BV:
    return BV([VAR(f"{name}[{i}]") for i in range(w)])


def bv_const(v, w) -> BV:
    return BV([CONST((v >> i) & 1) for i in range(w)])


def bv_eq(a: BV, b: BV) -> Sig:
    w = max(a.width, b.width)
    ab = a.bits + [FALSE] * (w - a.width)
    bb = b.bits + [FALSE] * (w - b.width)
    return AND(*[XNOR(x, y) for x, y in zip(ab, bb)])


def bv_eq_const(a: BV, k: int) -> Sig:
    return bv_eq(a, bv_const(k, a.width))


def bv_ge_const(a: BV, k: int) -> Sig:
    # unsigned a >= k, for the small widths here
    return OR(*[AND(bv_eq_const(a, v)) for v in range(k, 1 << a.width)])


def bv_ite(c: Sig, a: BV, b: BV) -> BV:
    w = max(a.width, b.width)
    ab = a.bits + [FALSE] * (w - a.width)
    bb = b.bits + [FALSE] * (w - b.width)
    return BV([ITE(c, x, y) for x, y in zip(ab, bb)])


def bv_inc(a: BV) -> BV:
    out, carry = [], TRUE
    for bit in a.bits:
        out.append(XOR(bit, carry))
        carry = AND(bit, carry)
    return BV(out)


def bv_dec(a: BV) -> BV:
    out, borrow = [], TRUE
    for bit in a.bits:
        out.append(XOR(bit, borrow))
        borrow = AND(NOT(bit), borrow)
    return BV(out)


def bv_add(a: BV, b: BV, width=None) -> BV:
    """Ripple-carry adder, wrapping to `width` (default max of the operands) --
    the ~200-clause bvadd the SMT section bit-blasts."""
    w = width or max(a.width, b.width)
    ab = a.bits + [FALSE] * (w - a.width)
    bb = b.bits + [FALSE] * (w - b.width)
    out, carry = [], FALSE
    for x, y in zip(ab[:w], bb[:w]):
        out.append(XOR(XOR(x, y), carry))                 # sum bit
        carry = OR(AND(x, y), AND(carry, XOR(x, y)))      # carry out
    return BV(out)


def bv_mul(a: BV, b: BV, width=None) -> BV:
    """Shift-and-add array multiplier, wrapping to `width` -- the bvmul that
    bit-blasts to ~20k clauses at 32 bits (the multiplier wall)."""
    w = width or max(a.width, b.width)
    acc = BV([FALSE] * w)
    for i, bbit in enumerate(b.bits[:w]):
        partial = BV([FALSE] * i + [AND(bbit, x) for x in a.bits[:w - i]])
        acc = bv_add(acc, partial, w)
    return acc


def bv_sub(a: BV, b: BV, width=None) -> BV:
    """a - b, wrapping to `width`, via two's complement (~b + 1)."""
    w = width or max(a.width, b.width)
    bb = b.bits + [FALSE] * (w - b.width)
    neg_b = bv_inc(BV([NOT(x) for x in bb[:w]]))
    return bv_add(a, neg_b, w)


# ---------------------------------------------------------------------------
# Transition system.
# ---------------------------------------------------------------------------
class TransitionSystem:
    def __init__(self, name):
        self.name = name
        self.state: list[str] = []        # state-bit VAR names
        self.inputs: list[str] = []       # input-bit VAR names
        self.next: dict[str, Sig] = {}    # name -> next-state Sig (over state+input VARs)
        self.init: dict[str, bool] = {}   # name -> reset value
        self.bad: Optional[Sig] = None    # property violation (over state VARs)
        self.liveness: list = []          # [(antecedent Sig, eventually Sig)] -- a |-> F b
        self.assumptions: list = []       # [Sig] -- environment constraints (each holds every cycle)
        self.covers: list = []            # [Sig] -- cover targets (reachability sanity, BMC)

    def add_state_bit(self, name, init, nxt):
        self.state.append(name)
        self.init[name] = bool(init)
        self.next[name] = nxt

    def add_state_bv(self, bv_name, bv_now: BV, init_val, nxt_bv: BV):
        for i in range(bv_now.width):
            self.add_state_bit(f"{bv_name}[{i}]", (init_val >> i) & 1, nxt_bv.bits[i])

    def add_input(self, name):
        self.inputs.append(name)
        return VAR(name)


def fresh_frame(solver, ts: TransitionSystem, tag) -> dict:
    """A fresh environment: one solver var per state bit and input bit."""
    env = {}
    for s in ts.state:
        env[s] = solver.new_var()
        if T.on:
            solver.names[env[s]] = f"{s}@{tag}"
    for inp in ts.inputs:
        env[inp] = solver.new_var()
        if T.on:
            solver.names[env[inp]] = f"{inp}@{tag}"
    env["__memo__"] = {}
    env["__tag__"] = tag
    return env


def next_env(solver, ts: TransitionSystem, env: dict) -> dict:
    """Map each state bit to the literal of its next-state function in `env`, and
    give the next step fresh input variables -- so a property that reads inputs (a
    Mealy / combinational-output assertion, not just a pure state invariant) can be
    evaluated at the next state too. State-only properties never touch these."""
    memo = env["__memo__"]
    out = {}
    for s in ts.state:
        out[s] = tseitin(solver, ts.next[s], env, memo)
    for inp in ts.inputs:
        out[inp] = solver.new_var()
        if T.on:
            solver.names[out[inp]] = f"{inp}@+1"
    out["__memo__"] = {}
    return out


def assert_init(solver, ts: TransitionSystem, env: dict):
    for s in ts.state:
        lit = env[s]
        solver.add_clause([lit if ts.init[s] else -lit])


def bad_lit(solver, ts: TransitionSystem, env: dict) -> int:
    return tseitin(solver, ts.bad, env, env["__memo__"])


def tie(solver, env_a: dict, env_next: dict, ts: TransitionSystem):
    """Constrain frame B's state vars to equal frame A's next-state literals."""
    for s in ts.state:
        a = env_next[s]       # next-state literal computed in frame A
        b = env_a[s]          # frame B's state var (passed in as env_a here)
        solver.add_clause([-a, b]); solver.add_clause([a, -b])   # a <-> b


def read_bv(solver, env, bv_name, width):
    return sum((1 << i) if solver.get_value(env[f"{bv_name}[{i}]"]) else 0
               for i in range(width))


if __name__ == "__main__":
    from cdcl import Solver
    # sanity: encode (a XOR b) and force it true with a=b -> UNSAT
    s = Solver()
    env = {"a": s.new_var(), "b": s.new_var()}
    memo = {}
    x = tseitin(s, XOR(VAR("a"), VAR("b")), env, memo)
    s.add_clause([x])                       # a xor b
    s.add_clause([env["a"]]); s.add_clause([env["b"]])  # a=b=1
    assert s.solve() is False
    print("[circuit] XOR Tseitin ok (a xor b with a=b is UNSAT)")
    # bitvector: count=3, inc -> 4
    s = Solver()
    env = {f"c[{i}]": s.new_var() for i in range(3)}
    cnt = BV([VAR(f"c[{i}]") for i in range(3)])
    nxt = bv_inc(cnt)
    memo = {}
    eq4 = tseitin(s, bv_eq_const(BV([nxt.bits[i] for i in range(3)]), 4), env, memo)
    s.add_clause([tseitin(s, bv_eq_const(cnt, 3), env, memo)])  # count=3
    s.add_clause([eq4])
    assert s.solve() is True
    print("[circuit] bitvector inc ok (count=3 -> next=4 is SAT)")
    # ternary simulation: a controlling input decides despite an X ...
    a, b = VAR("a"), VAR("b")
    assert ternary_eval(AND(a, b), {"a": 0, "b": None}) == 0        # 0 AND X = 0
    assert ternary_eval(OR(a, b), {"a": 1, "b": None}) == 1         # 1 OR X = 1
    assert ternary_eval(XOR(a, b), {"a": 1, "b": None}) is None     # xor can't be saved
    assert ternary_eval(ITE(a, b, b), {"a": None, "b": 1}) == 1     # agreeing branches
    # ... and X-pessimism is real: v OR NOT v is constantly 1, but ternary says X
    v = VAR("v")
    assert ternary_eval(OR(v, NOT(v)), {"v": None}) is None
    assert ternary_eval(OR(v, NOT(v)), {"v": 0}) == 1
    assert support(AND(a, ITE(b, v, v))) == frozenset({"a", "b", "v"})
    print("[circuit] ternary simulation ok (controlling inputs decide; x∨¬x shows the pessimism)")
    print("[circuit] all self-tests passed")
