"""
word.py -- a WORD-LEVEL model checker: BMC and k-induction over bit-vectors and
memories, so a design can be proved without ever bit-blasting its memory.

The bit-level engines (bmc/ic3) lower a whole design to gates, which turns a 4096-
entry DRAM store into 131072 state bits. That is the wrong move for a datapath whose
correctness argument does not depend on the address space being small. This module
keeps the design word-level:

  * a signal is a bit-vector term (smt.py's Term layer, now full QF_BV);
  * a memory is an ARRAY -- its next-state is a `store`, a read is a `select`, and
    the McCarthy read-over-write axioms decide the contract with the address left
    symbolic (word.py desugars every read into an ite-chain over the writes plus
    congruence at the base array; only the finitely many *access addresses* are
    ever compared, never the 2^addr entries).

The residual, array-free bit-vector formula is bit-blasted to CNF and handed to the
same cdcl.py SAT oracle every other engine uses, so BMC and k-induction here are the
familiar constructions -- unroll from reset / assume-k-then-prove-k+1 -- just carried
out over words and arrays instead of bare gates.
"""

from __future__ import annotations
from cdcl import Solver
from circuit import (BV, VAR, AND, OR, XOR, XNOR, NOT, ITE, FALSE, TRUE,
                     bv_var, bv_const, bv_eq, bv_ite, bv_add, bv_sub, bv_mul,
                     tseitin)
from smt import Term, bvvar, bvconst, bvselect, bvstore
from trace import T


# ---------------------------------------------------------------------------
# Width inference. wenv maps a name to an int width (a word) or ('mem', aw, dw)
# (a memory). A bare constant has no width of its own; it takes the width of the
# context it appears in.
# ---------------------------------------------------------------------------
_CMP = ("eq", "ne", "ult", "ule", "ugt", "uge")


def _mem_dw(arr, wenv):
    """Data width of an array term (a var of memory sort, or a store over one)."""
    if arr.kind == "store":
        return _mem_dw(arr.args[0], wenv)
    if arr.kind == "var":
        return wenv[arr.name][2]
    raise ValueError(f"not an array term: {arr.kind}")


def _mem_aw(arr, wenv):
    if arr.kind == "store":
        return _mem_aw(arr.args[0], wenv)
    if arr.kind == "var":
        return wenv[arr.name][1]
    raise ValueError(f"not an array term: {arr.kind}")


def width_of(t, wenv):
    k = t.kind
    if k == "var":
        s = wenv[t.name]
        return None if isinstance(s, tuple) else s        # array var: no scalar width
    if k == "const":
        return None                                       # from context
    if k in _CMP:
        return 1
    if k == "extract":
        hi, lo = t.val
        return hi - lo + 1
    if k == "zext":
        return t.val
    if k == "concat":
        return sum(width_of(a, wenv) for a in t.args)
    if k == "select":
        return _mem_dw(t.args[0], wenv)
    if k == "ite":
        return _maxw(width_of(t.args[1], wenv), width_of(t.args[2], wenv))
    if k == "not":
        return width_of(t.args[0], wenv)
    if k in ("add", "sub", "mul", "and", "or", "xor", "neg", "shl", "lshr"):
        w = None
        for a in t.args:
            w = _maxw(w, width_of(a, wenv))
        return w
    raise ValueError(f"width_of: {k}")


def _maxw(a, b):
    if a is None:
        return b
    if b is None:
        return a
    return max(a, b)


# ---------------------------------------------------------------------------
# The bit-blaster: an array-free... almost. `select`/`store` are handled inline by
# read-over-write, so arrays never become state -- only the access addresses are
# compared. Everything else lowers straight to circuit.py bit-vector gates.
# ---------------------------------------------------------------------------
class _Blaster:
    def __init__(self, s, wenv=None):
        self.s = s
        self.wenv = wenv if wenv is not None else {}   # frame-tagged name -> width / mem sort
        self.env = {}                  # frame-tagged word name -> BV (bits are registered leaves)
        self.tenv = {}                 # bit-leaf name -> solver literal (for tseitin)
        self.reads = {}                # array var name -> [(idx_BV, value_BV)] for congruence
        self.memo = {}                 # tseitin cache for this solver

    def fresh_bv(self, name, w) -> BV:
        """A fresh word: a BV whose bit-leaves each get a solver literal in tenv."""
        bv = bv_var(name, w)
        for b in bv.bits:
            self.tenv[b.name] = self.s.new_var()
            if T.on:
                self.s.names[self.tenv[b.name]] = b.name
        return bv

    def _fit(self, bv, w):
        if w is None or bv.width == w:
            return bv
        return BV(bv.bits[:w] + [FALSE] * (w - bv.width))

    def sig(self, t):                  # a 1-bit term -> a single Sig
        return self.go(t, 1).bits[0]

    def lit(self, sig):
        return tseitin(self.s, sig, self.tenv, self.memo)

    def _assert(self, sig):
        self.s.add_clause([self.lit(sig)])

    def select(self, arr, jbv):
        """Read arr[j] as a BV, by read-over-write; base-array reads are fresh values
        made congruent (equal address -> equal value)."""
        if arr.kind == "store":
            a, i, v = arr.args
            ibv = self.go(i, jbv.width)
            vbv = self.go(v, _mem_dw(arr, self.wenv))
            return bv_ite(bv_eq(ibv, self._fit(jbv, ibv.width)), vbv, self.select(a, jbv))
        if arr.kind == "var":
            dw = self.wenv[arr.name][2]
            rl = self.reads.setdefault(arr.name, [])
            rv = self.fresh_bv(f"__rd_{arr.name.replace('@','_')}_{len(rl)}", dw)
            for (jk, rk) in rl:
                self._assert(OR(NOT(bv_eq(jbv, jk)), bv_eq(rv, rk)))   # congruence
            rl.append((jbv, rv))
            return rv
        raise ValueError(f"select base {arr.kind}")

    def go(self, t, w=None) -> BV:
        k = t.kind
        if k == "const":
            return bv_const(t.val, w or 1)
        if k == "var":
            return self._fit(self.env[t.name], w)
        if k == "select":
            jbv = self.go(t.args[1], _mem_aw(t.args[0], self.wenv))
            return self._fit(self.select(t.args[0], jbv), w)
        if k == "extract":
            hi, lo = t.val
            base = self.go(t.args[0])
            return BV(base.bits[lo:hi + 1])
        if k == "concat":
            bits = []
            for a in reversed(t.args):                    # MSB-first args, LSB-first bits
                bits += self.go(a).bits
            return BV(bits)
        if k == "zext":
            return self._fit(self.go(t.args[0]), t.val)
        if k == "ite":
            c = self.sig(t.args[0])
            nw = w or _maxw(width_of(t.args[1], self.wenv), width_of(t.args[2], self.wenv))
            return bv_ite(c, self.go(t.args[1], nw), self.go(t.args[2], nw))
        if k in _CMP:
            aw = _maxw(width_of(t.args[0], self.wenv), width_of(t.args[1], self.wenv)) or w or 1
            a, b = self.go(t.args[0], aw), self.go(t.args[1], aw)
            eq = bv_eq(a, b)
            if k == "eq":  return BV([eq])
            if k == "ne":  return BV([NOT(eq)])
            return BV([self._ucmp(k, a, b)])
        if k == "not":
            x = self.go(t.args[0], w)
            return BV([NOT(b) for b in x.bits])
        if k in ("and", "or", "xor", "add", "sub", "mul", "neg", "shl", "lshr"):
            nw = w or width_of(t, self.wenv)
            if k == "neg":
                return bv_sub(bv_const(0, nw), self.go(t.args[0], nw), nw)
            a = self.go(t.args[0], nw)
            b = self.go(t.args[1], nw) if len(t.args) > 1 else None
            if k == "and": return BV([AND(x, y) for x, y in zip(a.bits, self._fit(b, nw).bits)])
            if k == "or":  return BV([OR(x, y)  for x, y in zip(a.bits, self._fit(b, nw).bits)])
            if k == "xor": return BV([XOR(x, y) for x, y in zip(a.bits, self._fit(b, nw).bits)])
            if k == "add": return bv_add(a, b, nw)
            if k == "sub": return bv_sub(a, b, nw)
            if k == "mul": return bv_mul(a, b, nw)
            if k in ("shl", "lshr"): return self._shift(k, a, t.args[1], nw)
        raise ValueError(f"blast: {k}")

    def _ucmp(self, k, a: BV, b: BV) -> "Sig":
        # unsigned compare via subtract-and-borrow: a < b iff a - b borrows.
        w = max(a.width, b.width)
        borrow = FALSE
        for x, y in zip(a.bits + [FALSE] * (w - a.width), b.bits + [FALSE] * (w - b.width)):
            borrow = OR(AND(NOT(x), y), AND(borrow, NOT(XOR(x, y))))
        lt = borrow
        if k == "ult": return lt
        if k == "uge": return NOT(lt)
        gt = AND(NOT(lt), NOT(bv_eq(a, b)))
        if k == "ugt": return gt
        if k == "ule": return NOT(gt)

    def _shift(self, k, a: BV, amt_t, w):
        # constant shift amount only (the RTL here shifts by constants); barrel otherwise.
        amt = amt_t.val if amt_t.kind == "const" else None
        if amt is None:
            raise NotImplementedError("variable shift")
        if k == "shl":
            return BV(([FALSE] * amt + a.bits)[:w])
        return BV((a.bits[amt:] + [FALSE] * amt)[:w])


# ---------------------------------------------------------------------------
# The word-level transition system.
# ---------------------------------------------------------------------------
class WordTS:
    def __init__(self, name):
        self.name = name
        self.widths = {}      # name -> int width, or ('mem', addr_w, data_w)
        self.inputs = []      # input word names
        self.state = []       # state names (words and memories)
        self.init = {}        # name -> Term (reset value). Memories carry no
                              # init: word-level memory proofs assume ARBITRARY
                              # initial contents (sound in the SAFE direction; a
                              # memory-init-dependent refutation is not trusted --
                              # the contracts here are content-independent RAW).
        self.next = {}        # name -> Term (next value, over current-state + input names)
        self.prop = None      # Term (1-bit) asserted every reachable step
        self.assumptions = [] # [Term] 1-bit environment constraints (hold every step)

    def add_word(self, name, width, init=None, nxt=None):
        self.widths[name] = width
        self.state.append(name)
        if init is not None: self.init[name] = init
        if nxt is not None:  self.next[name] = nxt

    def add_mem(self, name, addr_w, data_w, nxt=None):
        self.widths[name] = ("mem", addr_w, data_w)
        self.state.append(name)
        if nxt is not None: self.next[name] = nxt

    def add_input(self, name, width):
        self.widths[name] = width
        self.inputs.append(name)


def _rename(t, tag, statenames):
    """Rename every state/input var `x` in a term to `x@tag` (frame-tagged)."""
    if t.kind == "var" and t.name in statenames:
        return bvvar(f"{t.name}@{tag}")
    if t.args:
        return Term(t.kind, args=tuple(_rename(a, tag, statenames) for a in t.args),
                    name=t.name, val=t.val)
    return t


# ---------------------------------------------------------------------------
# Word-level BMC: unroll from reset, look for a reachable ¬prop.
# ---------------------------------------------------------------------------
def wbmc(ts: WordTS, k, want_model=False):
    names = set(ts.widths)
    s = Solver()
    B = _Blaster(s)

    def alloc(frame):
        for n, wd in ts.widths.items():
            tag = f"{n}@{frame}"
            B.wenv[tag] = wd
            if not isinstance(wd, tuple):       # a word gets a fresh BV; a memory stays symbolic
                B.env[tag] = B.fresh_bv(tag, wd)

    alloc(0)
    # every signal's current-frame value: a word is a fresh @frame var, a memory is a
    # store-chain Term over the initial symbolic array. Inputs are fresh each frame.
    cur = {n: bvvar(f"{n}@0") for n in names}

    for n in ts.state:                          # init: pin reset values at frame 0
        if n in ts.init and not isinstance(ts.widths[n], tuple):
            i0 = _rename(ts.init[n], 0, names)
            B._assert(bv_eq(B.env[f"{n}@0"], B.go(i0, ts.widths[n])))

    if T.on:
        T.rule(f"word-level BMC of {ts.name}: unroll {k} frames, memory kept symbolic")

    for frame in range(k + 1):
        for a in ts.assumptions:                # assumptions hold at this frame
            B._assert(B.sig(_subst_cur(a, cur, names)))
        bad = NOT(B.sig(_subst_cur(ts.prop, cur, names)))     # ¬prop reachable here?
        if s.solve([B.lit(bad)]):
            if T.on:
                T.say(f"  frame {frame}: ¬prop is SAT -> counterexample at depth {frame}")
            return ("CEX", frame, _model(s, B, ts, k) if want_model else None)
        if frame < k:                           # advance every signal one frame
            alloc(frame + 1)
            nxt = {}
            for n in names:
                if n in ts.state and n in ts.next:
                    e = _subst_cur(ts.next[n], cur, names)
                    if isinstance(ts.widths[n], tuple):
                        nxt[n] = e              # memory: keep the store-chain term
                    else:
                        B._assert(bv_eq(B.env[f"{n}@{frame + 1}"], B.go(e, ts.widths[n])))
                        nxt[n] = bvvar(f"{n}@{frame + 1}")     # word: relational fresh var
                elif n in ts.state:
                    nxt[n] = cur[n]             # held (no next)
                else:
                    nxt[n] = bvvar(f"{n}@{frame + 1}")         # input: fresh each frame
            cur = nxt
    if T.on:
        T.say(f"  no ¬prop through depth {k} -> SAFE up to {k}")
    return ("SAFE-UP-TO", k, None)


def _subst_cur(t, cur, names):
    """Replace each state/input var by its current-frame term (word: a fresh @frame var;
    memory: its store-chain)."""
    if t.kind == "var" and t.name in cur:
        return cur[t.name]
    if t.args:
        return Term(t.kind, args=tuple(_subst_cur(a, cur, names) for a in t.args),
                    name=t.name, val=t.val)
    return t


def _model(s, B, ts, k):
    out = {}
    for n, wd in ts.widths.items():
        if isinstance(wd, tuple):
            continue
        for f in range(k + 1):
            bv = B.env.get(f"{n}@{f}")
            if bv is None:
                continue
            v = 0
            for i, b in enumerate(bv.bits):
                if b.kind == "var" and s.get_value(B.tenv[b.name]):
                    v |= (1 << i)
            out[f"{n}@{f}"] = v
    return out


# ---------------------------------------------------------------------------
# Word-level k-induction: base case (no ¬prop in k steps from reset) + step
# (prop for k consecutive symbolic states -> prop at the (k+1)-th).
# ---------------------------------------------------------------------------
def w_kinduction(ts: WordTS, k=1):
    base = wbmc(ts, k - 1)
    if base[0] == "CEX":
        return ("CEX", base[1])

    names = set(ts.widths)
    s = Solver()
    B = _Blaster(s)

    def alloc(frame):
        for n, wd in ts.widths.items():
            tag = f"{n}@{frame}"
            B.wenv[tag] = wd
            if not isinstance(wd, tuple):
                B.env[tag] = B.fresh_bv(tag, wd)

    for f in range(k + 1):
        alloc(f)
    cur = {f: {n: bvvar(f"{n}@{f}") for n in names} for f in range(k + 1)}

    if T.on:
        T.rule(f"word-level k-induction of {ts.name} at k={k}")
    # transition + assumptions + assumed prop for frames 0..k-1
    for f in range(k):
        for n in ts.state:
            if n in ts.next and not isinstance(ts.widths[n], tuple):
                e = _subst_cur(ts.next[n], cur[f], names)
                B._assert(bv_eq(B.env[f"{n}@{f + 1}"], B.go(e, ts.widths[n])))
            elif n in ts.next:
                cur[f + 1][n] = _subst_cur(ts.next[n], cur[f], names)
        for a in ts.assumptions:
            B._assert(B.sig(_subst_cur(a, cur[f], names)))
        B._assert(B.sig(_subst_cur(ts.prop, cur[f], names)))
    for a in ts.assumptions:
        B._assert(B.sig(_subst_cur(a, cur[k], names)))
    bad = NOT(B.sig(_subst_cur(ts.prop, cur[k], names)))       # violate prop at frame k?
    if s.solve([B.lit(bad)]):
        return ("UNKNOWN", k)                 # step fails: not inductive at this k
    return ("SAFE", k)


# ---------------------------------------------------------------------------
if __name__ == "__main__":
    from smt import (bvadd, bveq, bvne, bvult, bvite, bvselect, bvstore, bvand, bvor)

    # (1) a saturating counter that must never exceed 4 -- word-level k-induction.
    #     cnt' = (cnt == 4) ? 4 : cnt + 1 ;  prop: cnt <= 4.
    ts = WordTS("counter")
    ts.add_word("cnt", 3, init=bvconst(0),
                nxt=bvite(bveq(bvvar("cnt"), bvconst(4)), bvconst(4),
                          bvadd(bvvar("cnt"), bvconst(1))))
    ts.prop = bvor(bvult(bvvar("cnt"), bvconst(4)), bveq(bvvar("cnt"), bvconst(4)))  # cnt<=4
    r = w_kinduction(ts, 1)
    print(f"[word] saturating counter, cnt<=4: {r[0]}")
    assert r[0] == "SAFE"

    # (2) the same counter with a broken bound (never resets) violates cnt<=4 -> CEX.
    bad = WordTS("counter_bad")
    bad.add_word("cnt", 4, init=bvconst(0), nxt=bvadd(bvvar("cnt"), bvconst(1)))
    bad.prop = bvor(bvult(bvvar("cnt"), bvconst(4)), bveq(bvvar("cnt"), bvconst(4)))
    rb = wbmc(bad, 8)
    print(f"[word] unbounded counter, cnt<=4: {rb[0]} at depth {rb[1]}")
    assert rb[0] == "CEX"

    # (3) a one-entry-per-cycle memory: whatever address we hold, writing d there and
    #     reading it back next cycle yields d -- proved with the address SYMBOLIC.
    m = WordTS("mem_echo")
    m.add_input("a", 12)
    m.add_input("d", 8)
    m.add_mem("mem", 12, 8, nxt=bvstore(bvvar("mem"), bvvar("a"), bvvar("d")))
    m.add_word("a_q", 12, init=bvconst(0), nxt=bvvar("a"))
    m.add_word("d_q", 8, init=bvconst(0), nxt=bvvar("d"))
    m.add_word("wrote", 1, init=bvconst(0), nxt=bvconst(1))
    # after one write, a read of the just-written address returns the just-written data
    m.prop = bvor(bveq(bvvar("wrote"), bvconst(0)),
                  bveq(bvselect(bvvar("mem"), bvvar("a_q")), bvvar("d_q")))
    rm = w_kinduction(m, 1)
    print(f"[word] memory echo (symbolic 12-bit address): {rm[0]}")
    assert rm[0] == "SAFE"

    print("[word] OK: word-level BMC + k-induction prove a bounded counter and a symbolic "
          "memory echo, and refute an unbounded counter -- the memory never bit-blasted")
