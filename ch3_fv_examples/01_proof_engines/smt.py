"""
smt.py -- SMT by DPLL(T): SAT lifted from gates to words.

Chapter 3's SMT section: a solver that "accepts a x b as a single atom and
reasons about it algebraically." Each theory atom becomes a Boolean variable and
two solvers play ping-pong -- CDCL proposes a truth assignment over the atoms,
the theory solver checks whether that assignment is consistent in the theory and,
on a conflict, returns a short *theory lemma* the SAT engine adds as a clause.

Two paths, both genuine and both in the book:

  * Eager bit-blasting (`bitblast_equiv`): lower each word-level operator to gates
    -- the ripple-carry bvadd (~200 clauses at 32 bits), the array bvmul (~20k) --
    and hand the miter to the CDCL of cdcl.py. This is where "the cost of formal
    verification is the cost of the encoded CNF" becomes literal.

  * Lazy DPLL(T) (`solve`): a word-level theory solver normalizes bit-vector
    arithmetic (associativity + commutativity of bvadd, commutativity of bvmul)
    to a polynomial normal form mod 2^w and decides equalities *without*
    bit-blasting -- closing the rebalanced adder tree and bvmul commutativity in
    O(terms). When the normal forms differ it is inconclusive (coefficient
    inequality mod 2^w does not prove the functions differ), so it falls back to
    bit-blasting that atom -- exactly the incremental bit-flattening the chapter
    describes.

The worked example is the chapter's own: the rebalanced four-operand adder tree
A = ((a+b)+c)+d  vs  B = (a+b)+(c+d), whose miter is UNSAT.
"""

from __future__ import annotations
from cdcl import Solver
from circuit import (BV, VAR, AND, OR, XOR, NOT, FALSE, TRUE,
                     bv_var, bv_const, bv_add, bv_mul, bv_inc, tseitin)
from trace import T


# ---------------------------------------------------------------------------
# A tiny QF_BV term layer.
# ---------------------------------------------------------------------------
class Term:
    __slots__ = ("kind", "args", "name", "val")

    def __init__(self, kind, args=(), name=None, val=None):
        self.kind, self.args, self.name, self.val = kind, args, name, val


def bvvar(name):          return Term("var", name=name)
def bvconst(v):           return Term("const", val=v)
def bvadd(*ts):           return Term("add", args=ts)
def bvsub(a, b):          return Term("sub", args=(a, b))
def bvneg(a):             return Term("neg", args=(a,))
def bvmul(a, b):          return Term("mul", args=(a, b))
# Theory of arrays (McCarthy select/store). An array is a `var` of array sort;
# `select(a,i)` reads it, `store(a,i,v)` is the array equal to a everywhere but i.
def bvselect(a, i):       return Term("select", args=(a, i))
def bvstore(a, i, v):     return Term("store", args=(a, i, v))
# The rest of QF_BV, so a word-level elaborator can render any RTL expression as a
# term (widths are inferred by word.width_of, so mixed-width designs are fine):
def bvite(c, a, b):       return Term("ite", args=(c, a, b))     # c is 1-bit
def bvand(a, b):          return Term("and", args=(a, b))
def bvor(a, b):           return Term("or", args=(a, b))
def bvxor(a, b):          return Term("xor", args=(a, b))
def bvnot(a):             return Term("not", args=(a,))
def bveq(a, b):           return Term("eq", args=(a, b))         # -> 1-bit
def bvne(a, b):           return Term("ne", args=(a, b))         # -> 1-bit
def bvult(a, b):          return Term("ult", args=(a, b))        # -> 1-bit (unsigned <)
def bvule(a, b):          return Term("ule", args=(a, b))        # -> 1-bit
def bvugt(a, b):          return Term("ugt", args=(a, b))        # -> 1-bit
def bvuge(a, b):          return Term("uge", args=(a, b))        # -> 1-bit
def bvextract(a, hi, lo): return Term("extract", args=(a,), val=(hi, lo))  # bits [hi:lo]
def bvconcat(*ts):        return Term("concat", args=ts)         # MSB-first
def bvzext(a, w):         return Term("zext", args=(a,), val=w)  # zero-extend to width w
def bvshl(a, b):          return Term("shl", args=(a, b))
def bvlshr(a, b):         return Term("lshr", args=(a, b))


class Eq:
    """The atom (= t1 t2)."""
    __slots__ = ("t1", "t2")

    def __init__(self, t1, t2):
        self.t1, self.t2 = t1, t2

    def __repr__(self):
        return f"(= {_show(self.t1)} {_show(self.t2)})"


def _show(t):
    if t.kind == "var":   return t.name
    if t.kind == "const": return str(t.val)
    if t.kind == "add":   return "(+ " + " ".join(_show(a) for a in t.args) + ")"
    if t.kind == "sub":   return f"(- {_show(t.args[0])} {_show(t.args[1])})"
    if t.kind == "neg":   return f"(- {_show(t.args[0])})"
    if t.kind == "mul":   return f"(* {_show(t.args[0])} {_show(t.args[1])})"
    if t.kind == "select": return f"(select {_show(t.args[0])} {_show(t.args[1])})"
    if t.kind == "store":  return (f"(store {_show(t.args[0])} {_show(t.args[1])} "
                                   f"{_show(t.args[2])})")
    return "?"


# ---------------------------------------------------------------------------
# Word-level theory solver: polynomial normal form mod 2^w.
#   A normal form is {monomial -> coeff mod 2^w}; a monomial is a sorted tuple of
#   variable names ((), the empty tuple, is the constant term). bvadd accumulates
#   coefficients (so associativity & commutativity are automatic); bvmul convolves
#   them (so x*y and y*x land on the same sorted monomial).
# ---------------------------------------------------------------------------
def normal_form(t, w):
    M = 1 << w

    def nf(t):
        if t.kind == "const":
            return {(): t.val % M}
        if t.kind == "var":
            return {(t.name,): 1}
        if t.kind == "neg":
            return {m: (-c) % M for m, c in nf(t.args[0]).items()}
        if t.kind == "add":
            out = {}
            for a in t.args:
                for m, c in nf(a).items():
                    out[m] = (out.get(m, 0) + c) % M
            return out
        if t.kind == "sub":
            return nf(bvadd(t.args[0], bvneg(t.args[1])))
        if t.kind == "mul":
            out = {}
            for m1, c1 in nf(t.args[0]).items():
                for m2, c2 in nf(t.args[1]).items():
                    m = tuple(sorted(m1 + m2))
                    out[m] = (out.get(m, 0) + c1 * c2) % M
            return out
        # normal_form decides only the arithmetic fragment (var/const/+/-/*).
        # A bitwise/shift/compare kind inside an Eq must go to the bit-blast
        # path instead of here; fail with a clear message, not a bare kind.
        raise ValueError(
            f"normal_form: non-arithmetic term kind {t.kind!r}; only "
            f"var/const/add/sub/neg/mul are handled word-level")

    return {m: c for m, c in nf(t).items() if c % M != 0}


def provably_equal(t1, t2, w):
    """True if t1 and t2 have the same polynomial normal form mod 2^w (sound: this
    implies the bit-vector functions are equal). The converse can fail mod 2^w, so
    a False here is 'inconclusive', not 'distinct'."""
    return normal_form(t1, w) == normal_form(t2, w)


# ---------------------------------------------------------------------------
# Theory of arrays, by eager read-over-write reduction (Ackermann-style).
#   Every select term is named by a fresh word variable, and the McCarthy axioms
#     select(store(a,i,v), j) = v                if i = j
#     select(store(a,i,v), j) = select(a, j)     if i != j
#   plus read congruence on a base array
#     i = j  ->  select(a,i) = select(a,j)
#   are emitted as clauses over Eq atoms. The index guards i=j are ordinary
#   bit-vector-arithmetic atoms, so the DPLL(T) loop above decides them with the
#   theory it already has -- meaning the address stays SYMBOLIC at its true width;
#   nothing about the memory is bit-blasted or enumerated. This is the word-level
#   way to carry a memory (the mem[]/cache_array[] of the Chapter 2 designs): a
#   write is a store, a read is a select, and "a read returns the last write to
#   that address" is the single read-over-write axiom, proved in O(1) regardless
#   of how many entries the array nominally has.
# ---------------------------------------------------------------------------
def _tkey(t):
    """A hashable structural key, so equal subterms share one name/atom."""
    if t.kind == "var":   return ("v", t.name)
    if t.kind == "const": return ("c", t.val)
    return (t.kind,) + tuple(_tkey(a) for a in t.args)


def _has_arrays(atoms):
    def scan(t):
        return t.kind in ("select", "store") or any(scan(a) for a in t.args)
    return any(scan(a.t1) or scan(a.t2) for a in atoms)


def _eliminate_arrays(atoms, cnf, w):
    """Return (atoms', cnf') with every array read replaced by a fresh word var and the
    read-over-write + congruence axioms added as clauses. Atoms are rebuilt and the
    caller's clauses remapped, so structurally-identical Eq atoms collapse to one Boolean
    (the rewritten originals and the axiom-generated equalities must share truth values)."""
    new_atoms, atom_id, extra = [], {}, []

    def A(a, b):                                   # 1-based index of Eq(a,b); alloc if new
        ka, kb = _tkey(a), _tkey(b)
        if (ka, kb) in atom_id: return atom_id[(ka, kb)]
        if (kb, ka) in atom_id: return atom_id[(kb, ka)]
        new_atoms.append(Eq(a, b))
        atom_id[(ka, kb)] = len(new_atoms)
        return len(new_atoms)

    sel_id, reads, ctr = {}, {}, [0]

    def elim(t):                                   # array-free bit-vector term
        if t.kind in ("var", "const"):
            return t
        if t.kind == "store":
            raise NotImplementedError("bare array equality (extensionality) not supported; "
                                      "compare select() results, not whole arrays")
        if t.kind == "select":
            base, idx = t.args
            jj = elim(idx)
            k = (_tkey(base), _tkey(jj))
            if k in sel_id:
                return sel_id[k]
            ctr[0] += 1
            vS = bvvar(f"__sel{ctr[0]}")
            sel_id[k] = vS
            if base.kind == "store":
                a, i, v = base.args
                p = A(elim(i), jj)                 # store index == read index ?
                extra.append([-p, A(vS, elim(v))])           #   i=j  -> vS = stored value
                extra.append([ p, A(vS, elim(bvselect(a, jj)))])  # i!=j -> vS = read below
            elif base.kind == "var":
                for (jk, vk) in reads.get(base.name, []):
                    extra.append([-A(jj, jk), A(vS, vk)])    # congruence: j=k -> a[j]=a[k]
                reads.setdefault(base.name, []).append((jj, vS))
            else:
                raise NotImplementedError(f"select on {base.kind}")
            return vS
        return Term(t.kind, args=tuple(elim(a) for a in t.args), name=t.name, val=t.val)

    remap = {i: A(elim(at.t1), elim(at.t2)) for i, at in enumerate(atoms, 1)}
    lit = lambda l: remap[l] if l > 0 else -remap[-l]
    new_cnf = [[lit(l) for l in cl] for cl in cnf] + extra
    return new_atoms, new_cnf


# ---------------------------------------------------------------------------
# Eager bit-blasting to the CDCL of cdcl.py.
# ---------------------------------------------------------------------------
def lower(t, w) -> BV:
    if t.kind == "const":
        return bv_const(t.val, w)
    if t.kind == "var":
        return bv_var(t.name, w)
    if t.kind == "neg":                                   # two's complement: ~x + 1
        return bv_inc(BV([NOT(b) for b in lower(t.args[0], w).bits]))
    if t.kind == "sub":
        return lower(bvadd(t.args[0], bvneg(t.args[1])), w)
    if t.kind == "add":
        acc = lower(t.args[0], w)
        for a in t.args[1:]:
            acc = bv_add(acc, lower(a, w), w)
        return acc
    if t.kind == "mul":
        return bv_mul(lower(t.args[0], w), lower(t.args[1], w), w)
    raise ValueError(t.kind)


def _var_names(t, out):
    if t.kind == "var":
        out.add(t.name)
    for a in t.args:
        _var_names(a, out)


class _CountSolver(Solver):
    """Counts every clause (units included) so we can report CNF cost."""
    def __init__(self):
        super().__init__()
        self.n_clauses = 0

    def add_clause(self, lits):
        seen, taut = set(), False
        for l in lits:
            if -l in seen:
                taut = True
                break
            seen.add(l)
        if not taut and lits:
            self.n_clauses += 1
        return super().add_clause(lits)


def bitblast_equiv(t1, t2, w, count_only=False):
    """Bit-blast the miter (t1 != t2) and solve. Returns
    ('UNSAT', n_clauses) | ('SAT', witness, n_clauses)."""
    s = _CountSolver()
    names = set()
    _var_names(t1, names)
    _var_names(t2, names)
    env = {}
    for nm in sorted(names):
        for i in range(w):
            env[f"{nm}[{i}]"] = s.new_var()
    A, B = lower(t1, w), lower(t2, w)
    differ = OR(*[XOR(x, y) for x, y in zip(A.bits, B.bits)])
    memo = {}
    s.add_clause([tseitin(s, differ, env, memo)])         # assert the outputs differ
    if count_only:
        return ("COUNTED", s.n_clauses)
    if s.solve():
        wit = {nm: sum((1 << i) for i in range(w) if s.get_value(env[f"{nm}[{i}]"]))
               for nm in sorted(names)}
        return ("SAT", wit, s.n_clauses)
    return ("UNSAT", s.n_clauses)


# ---------------------------------------------------------------------------
# DPLL(T): the ping-pong loop.
#   atoms : list of Eq atoms.   cnf : CNF over 1-based atom indices.
# ---------------------------------------------------------------------------
def theory_check(atoms, assign, w):
    """Check the asserted literals for theory consistency. Returns None if
    consistent, else (conflict_atom_indices) -- the minimal inconsistent set, whose
    negation becomes the theory lemma."""
    # equalities asserted true give variable substitutions x := term (first wins)
    subst = {}
    eq_used = {}
    for i, atom in enumerate(atoms, 1):
        if assign[i] and atom.t1.kind == "var" and atom.t1.name not in subst:
            subst[atom.t1.name] = atom.t2
            eq_used[atom.t1.name] = i
        elif assign[i] and atom.t2.kind == "var" and atom.t2.name not in subst:
            subst[atom.t2.name] = atom.t1
            eq_used[atom.t2.name] = i

    def apply(t, used):
        # chase var := var := ... := term to a fixpoint (array congruence builds such
        # chains), recording every equality atom the chain rode so the conflict lemma
        # names exactly the equalities that forced it; then recurse into args.
        seen = set()
        while t.kind == "var" and t.name in subst and t.name not in seen:
            seen.add(t.name)
            used.add(eq_used[t.name])
            t = subst[t.name]
        if t.args:
            return Term(t.kind, args=tuple(apply(a, used) for a in t.args),
                        name=t.name, val=t.val)
        return t

    # a disequality whose two sides are provably equal (after substitution) conflicts
    for i, atom in enumerate(atoms, 1):
        if not assign[i]:                                 # atom asserted FALSE -> t1 != t2
            used = set()
            t1, t2 = apply(atom.t1, used), apply(atom.t2, used)
            if provably_equal(t1, t2, w):
                return {i} | used
    return None


def solve(atoms, cnf, w, allow_bitblast=True):
    """DPLL(T). Returns ('UNSAT', lemmas) | ('SAT', model) | ('SAT-bb', witness)."""
    if _has_arrays(atoms):
        if T.on:
            T.rule("theory of arrays: read-over-write reduction before DPLL(T)")
        atoms, cnf = _eliminate_arrays(atoms, cnf, w)
    if T.on:
        T.rule(f"DPLL(T) @ {w}-bit -- SAT proposes, the word-level theory disposes")
        for i, a in enumerate(atoms, 1):
            T.say(f"  atom {i}:  {a}")
        T.say("loop: CDCL finds a truth assignment over the atoms; the theory checks it in")
        T.say("      the bit-vector algebra and returns a lemma on any inconsistency.")
    s = Solver()
    s.new_vars(len(atoms))
    for cl in cnf:
        s.add_clause(list(cl))
    lemmas = []
    while s.solve():
        assign = {i: s.get_value(i) for i in range(1, len(atoms) + 1)}
        s._cancel_until(0)    # back to root before adding lemmas incrementally, so a
                              # unit lemma that flips a model decision is not mistaken
                              # for a root conflict (which would wrongly poison to UNSAT)
        if T.on:
            T.say("SAT skeleton: " + ", ".join(
                (("" if assign[i] else "¬") + f"atom{i}") for i in range(1, len(atoms) + 1)))
        conflict = theory_check(atoms, assign, w)
        if conflict is None:
            # word-level is inconclusive on the asserted disequalities; confirm by
            # bit-blasting them (incremental bit-flattening) to get SAT + a witness.
            if T.on:
                T.say("  theory: asserted equalities are consistent; a disequality is word-level-")
                T.say("  inconclusive → bit-blast that atom to settle it")
            if not allow_bitblast:
                return ("SAT", assign)
            # Bit-blast the CONJUNCTION of all asserted literals together, so a
            # true-equality premise constrains the disequalities (checking one
            # disequality in isolation dropped the premises -> false SAT).
            rb = _bitblast_all(atoms, assign, w)
            if rb[0] == "UNSAT":
                # This truth assignment is theory-infeasible: block it whole.
                lem = [(-i if assign[i] else i) for i in range(1, len(atoms) + 1)]
                if T.on:
                    T.say(f"  bit-blast of the asserted conjunction is UNSAT → block this "
                          f"assignment with lemma {lem}")
                s.add_clause(lem)
                lemmas.append(lem)
                continue
            if T.on:
                T.say("  bit-blast of the asserted conjunction yields a witness → genuinely SAT")
            return ("SAT-bb", rb[1])
        lemma = [(-i if assign[i] else i) for i in sorted(conflict)]
        if T.on:
            T.say(f"  theory conflict on atoms {sorted(conflict)} (normal forms force it) → "
                  f"learn lemma {lemma}")
        s.add_clause(lemma)
        lemmas.append(lemma)
    if T.on:
        T.say(f"Boolean skeleton is UNSAT after {len(lemmas)} theory lemma(s) → UNSAT overall.")
    return ("UNSAT", lemmas)


def _bitblast_all(atoms, assign, w):
    """Bit-blast the CONJUNCTION of every asserted literal over a shared
    variable environment: each true equality as t1==t2, each false one as
    t1!=t2. Returns ('SAT', witness) | ('UNSAT',). Checking one disequality in
    isolation (the old fallback) ignored the true-equality premises, so e.g.
    (x+1==y+1) & (x!=y) wrongly read SAT; here the premise x+1==y+1 constrains
    the same bit-level x, y and the conjunction is correctly UNSAT."""
    s = _CountSolver()
    names = set()
    for atom in atoms:
        _var_names(atom.t1, names)
        _var_names(atom.t2, names)
    env = {}
    for nm in sorted(names):
        for i in range(w):
            env[f"{nm}[{i}]"] = s.new_var()
    memo = {}
    for i, atom in enumerate(atoms, 1):
        A, B = lower(atom.t1, w), lower(atom.t2, w)
        differ = OR(*[XOR(x, y) for x, y in zip(A.bits, B.bits)])
        lit = tseitin(s, differ, env, memo)
        s.add_clause([lit] if not assign[i] else [-lit])   # differ / not-differ
    if s.solve():
        wit = {nm: sum((1 << i) for i in range(w) if s.get_value(env[f"{nm}[{i}]"]))
               for nm in sorted(names)}
        return ("SAT", wit)
    return ("UNSAT",)


def _model_via_bitblast(atoms, assign, w):
    r = _bitblast_all(atoms, assign, w)
    return r[1] if r[0] == "SAT" else {}


# ---------------------------------------------------------------------------
if __name__ == "__main__":
    W = 32
    a, b, c, d = bvvar("a"), bvvar("b"), bvvar("c"), bvvar("d")

    # --- The chapter's worked example: rebalanced four-operand adder tree. ---
    sumA = bvadd(bvadd(bvadd(a, b), c), d)          # ((a+b)+c)+d   linear chain
    sumB = bvadd(bvadd(a, b), bvadd(c, d))          # (a+b)+(c+d)   balanced tree
    miter = Eq(sumA, sumB)

    res = solve([miter], [[-1]], W)                  # assert NOT(sumA = sumB)
    print(f"[smt] adder-tree miter, DPLL(T) word-level @ {W}-bit: {res[0]} "
          f"({len(res[1])} theory lemma(s))")
    assert res[0] == "UNSAT"

    bb = bitblast_equiv(sumA, sumB, W)
    print(f"[smt] adder-tree miter, eager bit-blast @ {W}-bit : {bb[0]} "
          f"({bb[-1]} CNF clauses)")
    assert bb[0] == "UNSAT"

    # --- A buggy "balanced tree" that drops d: ((a+b)+c)+d  vs  (a+b)+(c+a). ---
    sumBug = bvadd(bvadd(a, b), bvadd(c, a))
    rb = bitblast_equiv(sumA, sumBug, W)
    print(f"[smt] buggy tree (uses a twice): {rb[0]}  witness={rb[1]}")
    assert rb[0] == "SAT" and (rb[1]["a"] != rb[1]["d"])

    # --- The multiplier wall: commutativity, word-level vs the bit-blast cost. ---
    comm = Eq(bvmul(a, b), bvmul(b, a))
    rc = solve([comm], [[-1]], W, allow_bitblast=False)
    _, nclauses = bitblast_equiv(bvmul(a, b), bvmul(b, a), W, count_only=True)
    print(f"[smt] bvmul commutativity, DPLL(T) word-level @ {W}-bit: {rc[0]}  "
          f"(eager bit-blast would emit {nclauses} clauses -- the multiplier wall)")
    assert rc[0] == "UNSAT"

    # --- The DPLL(T) ping-pong with Boolean structure + a theory lemma. ---
    #     (x = y)  AND  ( (x+k) != (y+k) )  is theory-UNSAT by linearity.
    x, y, k = bvvar("x"), bvvar("y"), bvconst(7)
    A1 = Eq(x, y)                                    # atom 1
    A2 = Eq(bvadd(x, k), bvadd(y, k))               # atom 2
    rp = solve([A1, A2], [[1], [-2]], W)            # assert x=y AND NOT(x+k = y+k)
    print(f"[smt] congruence ping-pong: {rp[0]}  lemma(s)={rp[1]}")
    assert rp[0] == "UNSAT" and any(len(l) > 1 for l in rp[1])

    # --- Theory of arrays: the McCarthy read-over-write axioms, word-level. ---
    mem, i, j, v = bvvar("mem"), bvvar("i"), bvvar("j"), bvvar("v")

    # (1) read-your-own-write: select(store(mem,i,v), i) = v, at any index i.
    row_hit = Eq(bvselect(bvstore(mem, i, v), i), v)
    r1 = solve([row_hit], [[-1]], W)                 # assert NOT(read = written)
    print(f"[smt] array read-over-write (same index): {r1[0]}")
    assert r1[0] == "UNSAT"

    # (2) a write to a DIFFERENT address is transparent: i != j implies
    #     select(store(mem,i,v), j) = select(mem, j).
    a_ij   = Eq(i, j)                                                  # atom 1
    a_read = Eq(bvselect(bvstore(mem, i, v), j), bvselect(mem, j))     # atom 2
    r2 = solve([a_ij, a_read], [[-1], [-2]], W)      # assert i!=j AND reads differ
    print(f"[smt] array read-over-write (disjoint index): {r2[0]}")
    assert r2[0] == "UNSAT"

    # (3) mem_ctrl's write-then-read, at the design's TRUE 12-bit address width --
    #     no entry is enumerated, the address stays symbolic. A read of address A
    #     after writing D there returns D.
    A12, D = bvvar("addr"), bvvar("data")
    wtr = Eq(bvselect(bvstore(mem, A12, D), A12), D)
    r3 = solve([wtr], [[-1]], 12)
    print(f"[smt] mem_ctrl write-then-read @ 12-bit address (symbolic, not blasted): {r3[0]}")
    assert r3[0] == "UNSAT"

    # (4) FIFO data-independence in miniature: a token written at slot P survives a
    #     later push to a different slot Q, so the read at P still yields the token.
    P, Q, tok, other = bvvar("P"), bvvar("Q"), bvvar("tok"), bvvar("other")
    fifo_mem = bvstore(bvstore(mem, P, tok), Q, other)
    a_pq   = Eq(P, Q)                                       # atom 1
    a_keep = Eq(bvselect(fifo_mem, P), tok)                 # atom 2
    r4 = solve([a_pq, a_keep], [[-1], [-2]], W)      # P!=Q AND token corrupted
    print(f"[smt] FIFO token survives a disjoint push: {r4[0]}")
    assert r4[0] == "UNSAT"

    # (5) a BUGGY memory: when the two writes collide (P = Q) the second clobbers the
    #     first, so claiming the read at P still returns the first token is refutable.
    a_keep2 = Eq(bvselect(fifo_mem, P), tok)
    a_diff  = Eq(tok, other)
    r5 = solve([a_pq, a_keep2, a_diff], [[1], [-2], [-3]], W)  # P=Q, read!=tok, tok!=other
    print(f"[smt] colliding writes clobber (P=Q): {r5[0]}  (a witness, as it should be)")
    assert r5[0] in ("SAT", "SAT-bb")

    print("[smt] OK: DPLL(T) proves the adder tree and bvmul-commutativity word-level, "
          "bit-blasts the buggy case to a witness, learns a congruence lemma, and carries "
          "a symbolic memory by read-over-write array theory (address never enumerated)")
