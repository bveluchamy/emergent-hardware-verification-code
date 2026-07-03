"""
smt_frontend.py -- a small SMT-LIB (QF_BV) reader.

The SV frontend turns RTL into a transition system the safety engines prove; this
turns the chapter's SMT-LIB miter into the term layer the DPLL(T) engine of
smt.py solves. It reads the restricted subset the chapter uses --

    (set-logic QF_BV)
    (declare-fun a () (_ BitVec 32))   ...
    (define-fun sumA () (_ BitVec 32) (bvadd (bvadd (bvadd a b) c) d))
    (define-fun sumB () (_ BitVec 32) (bvadd (bvadd a b) (bvadd c d)))
    (assert (not (= sumA sumB)))
    (check-sat)

-- parses the S-expressions, resolves define-fun bindings, and lowers every term
to smt.Term (bvadd / bvsub / bvmul / bvconst / bvvar). It returns the asserted
equality atoms plus a CNF skeleton over them, ready for smt.solve(): an
equivalence check is `(assert (not (= A B)))`, i.e. atom Eq(A,B) asserted false.

Deliberately small -- enough for the chapter's QF_BV equivalence miters, not a
full SMT-LIB front end.
"""

from __future__ import annotations
import re
import smt


# ---------------------------------------------------------------------------
# S-expression reader
# ---------------------------------------------------------------------------
def _sexprs(src: str):
    src = re.sub(r";[^\n]*", "", src)                 # strip ; comments
    toks = re.findall(r"\(|\)|[^\s()]+", src)
    pos = 0

    def parse():
        nonlocal pos
        t = toks[pos]
        pos += 1
        if t == "(":
            lst = []
            while toks[pos] != ")":
                lst.append(parse())
            pos += 1
            return lst
        return t

    out = []
    while pos < len(toks):
        out.append(parse())
    return out


# ---------------------------------------------------------------------------
# Term lowering
# ---------------------------------------------------------------------------
def _term(s, defs):
    if isinstance(s, str):
        if s in defs:
            return defs[s]
        if s.startswith("#x"):
            return smt.bvconst(int(s[2:], 16))
        if s.startswith("#b"):
            return smt.bvconst(int(s[2:], 2))
        return smt.bvconst(int(s))
    op = s[0]
    if op == "_" and isinstance(s[1], str) and s[1].startswith("bv"):
        return smt.bvconst(int(s[1][2:]))             # (_ bv5 32)
    if op == "bvadd":
        t = _term(s[1], defs)
        for x in s[2:]:
            t = smt.bvadd(t, _term(x, defs))
        return t
    if op == "bvsub":
        return smt.bvsub(_term(s[1], defs), _term(s[2], defs))
    if op == "bvmul":
        return smt.bvmul(_term(s[1], defs), _term(s[2], defs))
    if op == "bvneg":
        return smt.bvneg(_term(s[1], defs))
    raise SyntaxError(f"unsupported term: {s}")


def _width_of(sort) -> int:
    # sort is ["_", "BitVec", "32"]
    if isinstance(sort, list) and len(sort) == 3 and sort[1] == "BitVec":
        return int(sort[2])
    return 1


def read(src: str):
    """Return (atoms, cnf, width): equality atoms and a CNF over their 1-based
    indices, plus the bit width. `smt.solve(atoms, cnf, width)` decides it."""
    defs = {}
    width = 1
    atoms = []
    cnf = []

    def atom_index(a, b):
        atoms.append(smt.Eq(a, b))
        return len(atoms)

    def assert_formula(f):
        # supports: (= A B) | (not (= A B)) | (distinct A B)
        if f[0] == "not":
            inner = f[1]
            if inner[0] == "=":
                i = atom_index(_term(inner[1], defs), _term(inner[2], defs))
                cnf.append([-i])
                return
        if f[0] == "=":
            i = atom_index(_term(f[1], defs), _term(f[2], defs))
            cnf.append([i])
            return
        if f[0] == "distinct":
            i = atom_index(_term(f[1], defs), _term(f[2], defs))
            cnf.append([-i])
            return
        raise SyntaxError(f"unsupported assertion: {f}")

    for s in _sexprs(src):
        cmd = s[0]
        if cmd == "declare-fun":
            width = max(width, _width_of(s[3]))
            defs[s[1]] = smt.bvvar(s[1])
        elif cmd == "define-fun":
            width = max(width, _width_of(s[3]))
            defs[s[1]] = _term(s[4], defs)
        elif cmd == "assert":
            assert_formula(s[1])
        # set-logic / check-sat / exit: ignored
    return atoms, cnf, width


if __name__ == "__main__":
    src = """
    (set-logic QF_BV)
    (declare-fun a () (_ BitVec 8))
    (declare-fun b () (_ BitVec 8))
    (assert (not (= (bvadd a b) (bvadd b a))))   ; commutativity
    (check-sat)
    """
    atoms, cnf, w = read(src)
    assert len(atoms) == 1 and cnf == [[-1]] and w == 8
    r = smt.solve(atoms, cnf, w, allow_bitblast=False)
    print(f"[smt_frontend] parsed an 8-bit miter -> DPLL(T): {r[0]}")
    assert r[0] == "UNSAT"
    print("[smt_frontend] OK")
