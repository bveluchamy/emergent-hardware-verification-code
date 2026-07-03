"""
word_frontend.py -- lower book RTL to a WordTS (word.py), the memory kept as an array.

This is the word-level twin of frontend.py's bit-level elaborator. It reuses the very
same parser and the same if/case-folding machinery (`_expand`/`_fold`), but instead of
bit-blasting each signal to gates it renders each as a bit-vector *term* (smt.py), and
-- the point of the exercise -- renders an unpacked memory as an ARRAY: a write
`mem[i] <= d` becomes `store(mem, i, d)`, a read `mem[i]` becomes `select(mem, i)`, and
word.py proves the result with the address symbolic (never bit-blasting the 2^addr
entries). So the datapath designs are read from their own RTL, memory and all.

Scope: the synchronous-datapath subset the Chapter 2 memory designs use -- enums,
structs (flattened to per-field words), parameters/$clog2, part-selects, arithmetic and
comparison, if/case, one or more `always_ff` blocks, continuous assigns, and a 1-D
unpacked memory with a dynamic read/write port. That is enough to carry a design's
memory into the word-level engine; richer constructs (2-D arrays, functions) are the
next increment.
"""

from __future__ import annotations
from frontend import (tokenize, preprocess, Parser, _merge_checker, _desugar_temporal,
                      _fold, _subst, _stmts, _reset_signal)
from word import WordTS
from smt import (bvvar, bvconst, bvadd, bvsub, bvmul, bvand, bvor, bvxor, bvnot,
                 bveq, bvne, bvult, bvule, bvugt, bvuge, bvite, bvextract, bvconcat,
                 bvselect, bvstore, Term)


def parse_merge(texts):
    """Parse package + design + checker(s) as one stream (a package-only file has no
    module of its own), share the package-scope consts/types/structs across every module,
    merge each bound checker into its target, and desugar temporal operators."""
    p = Parser(tokenize(preprocess("\n".join(texts))))
    mods, binds = {}, []
    while not p.at_eof():
        if p.at("bind"):
            binds.append(p.parse_bind())
        else:
            m = p.parse_module()
            mods[m.name] = m
    # package/$unit scope is global: union every module's consts/types/structs, then give
    # each module the ones it is missing (so a checker sees the design's DATA_W etc.).
    allc, allt, alls = {}, {}, {}
    for m in mods.values():
        allc.update(m.consts); allt.update(m.types); alls.update(m.structs)
    for m in mods.values():
        for k, v in allc.items(): m.consts.setdefault(k, v)
        for k, v in allt.items(): m.types.setdefault(k, v)
        for k, v in alls.items(): m.structs.setdefault(k, v)
    for target, checker in binds:
        if target in mods and checker in mods:
            _merge_checker(mods[target], mods[checker])
    targets = [t for t, _ in binds if t in mods]
    main = mods[targets[0]] if targets else next(iter(mods.values()))
    _desugar_temporal(main)
    return main


_BIN = {"+": bvadd, "-": bvsub, "*": bvmul, "&": bvand, "|": bvor, "^": bvxor,
        "&&": bvand, "||": bvor, "==": bveq, "!=": bvne,
        "<": bvult, "<=": bvule, ">": bvugt, ">=": bvuge}


class WordElaborator:
    """AST (a parsed Module) -> WordTS, with memories as arrays."""

    def __init__(self, mod):
        self.mod = mod
        self.arrays = mod.arrays
        self.consts = mod.consts
        # width of every scalar signal (struct fields are already flattened to name.field)
        self.width = {n: s["width"] for n, s in mod.signals.items()}
        # continuous / always_comb wires: name -> AST (folded, so reads resolve to state)
        self.wire = {}
        for lhs, e in mod.assigns:
            if isinstance(lhs, str):
                self.wire[lhs] = e
        for stmt in mod.comb_stmts:
            for k, v in _fold(stmt, {}).items():
                self.wire[k] = v
        # next-state (per signal) and reset value, folded from the always_ff blocks.
        # Whole-struct / pattern assignments are expanded to per-field first (a struct is
        # carried as its flattened `name.field` words, exactly as the bit-level path does).
        self.nxt = _fold(self._wexpand(mod.next_stmt), {}) if mod.next_stmt else {}
        self.rst = _fold(self._wexpand(mod.reset_stmt), {}) if mod.reset_stmt else {}
        self._memo = {}

    # -- expand whole-struct / pattern LHS to per-field (word twin of _Elaborator._expand) --
    def _wexpand(self, stmt):
        if stmt is None:
            return None
        tag = stmt[0]
        if tag == "assign":
            return self._wexpand_assign(stmt[1], stmt[2])
        if tag == "block":
            return ("block", [self._wexpand(s) for s in stmt[1]])
        if tag == "if":
            return ("if", stmt[1], self._wexpand(stmt[2]),
                    self._wexpand(stmt[3]) if stmt[3] else None)
        if tag == "case":
            return ("case", stmt[1], [(l, self._wexpand(s)) for l, s in stmt[2]],
                    self._wexpand(stmt[3]) if stmt[3] else None)
        return stmt

    def _stype(self, name):
        return self.mod.signals.get(name, {}).get("stype")

    def _wexpand_assign(self, lhs, e):
        if isinstance(lhs, str) and self._stype(lhs):        # whole-struct <= e
            st = self._stype(lhs)
            return ("block", [self._wexpand_assign(f"{lhs}.{f}", self._proj(e, f))
                              for f, _ in self.mod.structs[st]])
        return ("assign", lhs, e)

    def _proj(self, e, field):
        """Project one field out of a struct-valued RHS."""
        if e[0] == "pattern":
            return e[1].get(field, e[1].get("default", ("const", 0, None)))
        if e[0] == "id":
            return ("id", f"{e[1]}.{field}")                 # struct signal -> flattened field
        if e[0] == "field":
            return ("id", f"{self._flat_field(e)}.{field}")
        if e[0] == "?:":
            return ("?:", e[1], self._proj(e[2], field), self._proj(e[3], field))
        raise NotImplementedError(f"struct projection of {e}")

    # -- sorts -------------------------------------------------------------
    def _mem_sort(self, name):
        dims, ew, _ = self.arrays[name]
        aw = max(1, (dims[0] - 1).bit_length())      # address bits for a 1-D memory
        return aw, ew

    def _is_array(self, ast):
        return ast[0] == "id" and ast[1] in self.arrays

    def _array_base(self, ast):
        """The memory name a read indexes into, seen through the store-chain that a
        same-cycle write builds up in _fold (a nonblocking read ignores that chain)."""
        if ast[0] == "id" and ast[1] in self.arrays:
            return ast[1]
        if ast[0] == "astore":
            return self._array_base(ast[1])
        if ast[0] == "?:":
            return self._array_base(ast[2]) or self._array_base(ast[3])
        return None

    # -- expression lowering: AST -> Term ----------------------------------
    def term(self, ast):
        tag = ast[0]
        if tag == "const":
            return bvconst(ast[1])
        if tag == "fill":
            return bvconst(-1 if ast[1] else 0)      # '1 / '0 (width fixed by context)
        if tag == "id":
            return self._resolve(ast[1])
        if tag == "astore":                          # ("astore", base_mem, idx, val)
            return bvstore(self.term(ast[1]), self.term(ast[2]), self.term(ast[3]))
        if tag in ("bit", "bit2"):                   # name[i]: array read OR vector bit-select
            base, idx = ast[1], ast[2]
            if isinstance(base, str):
                base = ("id", base)
            mem = self._array_base(base)
            if mem is not None:                      # a memory read -> the PRE-STATE array
                idx = idx if isinstance(idx, tuple) else ("const", idx, None)
                return bvselect(bvvar(mem), self.term(idx))   # nonblocking: read sees pre-state
            i = self._cint(idx)
            return bvextract(self.term(base), i, i)
        if tag == "partsel":                         # ("partsel", base, hi, lo) constant bounds
            return bvextract(self.term(("id", ast[1]) if isinstance(ast[1], str) else ast[1]),
                             self._cint(ast[2]), self._cint(ast[3]))
        if tag == "slice":                           # ("slice", base, hi, lo)
            return bvextract(self.term(ast[1]), self._cint(ast[2]), self._cint(ast[3]))
        if tag == "field":                           # struct field -> the flattened word
            return self._resolve(self._flat_field(ast))
        if tag == "concat":
            return bvconcat(*[self.term(p) for p in ast[1]])
        if tag == "un":
            _, op, a = ast
            if op == "~":
                return bvnot(self.term(a))
            if op == "!":
                return bveq(self.term(a), bvconst(0))
            if op == "-":
                return bvsub(bvconst(0), self.term(a))
        if tag == "?:":
            _, c, t, e = ast
            return bvite(self._cond(c), self.term(t), self.term(e))
        if tag == "bin":
            _, op, a, b = ast
            if op in ("&&", "||"):                   # logical -> reduce each side to 1-bit
                return (bvand if op == "&&" else bvor)(self._as1(a), self._as1(b))
            return _BIN[op](self.term(a), self.term(b))
        if tag == "call":
            return self._call(ast[1], ast[2])
        raise NotImplementedError(f"word term: {ast}")

    def _cond(self, ast):
        """A term used as a boolean (1-bit)."""
        return self._as1(ast)

    def _as1(self, ast):
        t = self.term(ast)
        # comparisons/logical already yield 1-bit; a wider value is true iff nonzero
        if ast[0] == "bin" and ast[1] in ("==", "!=", "<", "<=", ">", ">=", "&&", "||"):
            return t
        if ast[0] == "un" and ast[1] == "!":
            return t
        return bvne(t, bvconst(0))

    def _resolve(self, name):
        if name in self.consts:
            return bvconst(self.consts[name][0])
        if name in self.wire:                        # a comb wire: inline its definition
            if name not in self._memo:
                self._memo[name] = self.term(self.wire[name])
            return self._memo[name]
        return bvvar(name)                           # a register / input / memory leaf

    def _flat_field(self, ast):                      # ("field", ("id","req"), "push") -> "req.push"
        base = ast[1]
        root = base[1] if base[0] == "id" else self._flat_field(base)
        return f"{root}.{ast[2]}"

    def _cint(self, ast):
        if isinstance(ast, int):
            return ast
        if ast[0] == "const":
            return ast[1]
        return self._const_fold(ast)

    def _const_fold(self, ast):
        tag = ast[0]
        if tag == "const":
            return ast[1]
        if tag == "id":
            return self.consts[ast[1]][0]
        if tag == "bin":
            a, b = self._const_fold(ast[2]), self._const_fold(ast[3])
            return {"+": a + b, "-": a - b, "*": a * b}[ast[1]]
        raise NotImplementedError(f"const fold {ast}")

    def _call(self, fn, args):
        if fn in ("$clog2", "clog2"):
            n = self._const_fold(args[0])
            return bvconst(0 if n <= 1 else (n - 1).bit_length())
        if fn in ("$signed", "$unsigned"):
            return self.term(args[0])
        raise NotImplementedError(f"word call {fn}")

    # -- memory next: collapse the (possibly nested-guard) single write site into a
    #    conditional-value store.  A guarded write over unpacked memory is
    #      next = ite(g1, ite(g2, store(mem, i, v), mem), mem)
    #    which equals  store(mem, i, (g1&&g2) ? v : mem[i])  -- storing the old value back
    #    where the guard is false is a no-op, so no array-level ite is needed.
    def _mem_next(self, ast, base_name):
        writes = []                                  # [(guard_conds, idx_ast, val_ast)]

        def walk(a, guards):
            if a == ("id", base_name):
                return
            if a[0] == "astore":
                walk(a[1], guards)                   # its base must reduce to the memory
                writes.append((list(guards), a[2], a[3]))
            elif a[0] == "?:":
                _, c, then, els = a
                walk(then, guards + [(c, True)])
                walk(els, guards + [(c, False)])
            else:
                raise NotImplementedError(f"memory next shape {a}")

        walk(ast, [])
        base = bvvar(base_name)
        if not writes:
            return base
        if len(writes) > 1:
            raise NotImplementedError("multiple memory write sites in one cycle")
        guards, idx_ast, val_ast = writes[0]
        idx, val = self.term(idx_ast), self.term(val_ast)
        g = None
        for c, pol in guards:
            gc = self._cond(c) if pol else bvnot(self._cond(c))
            g = gc if g is None else bvand(g, gc)
        val = val if g is None else bvite(g, val, bvselect(base, idx))
        return bvstore(base, idx, val)

    # -- build the WordTS --------------------------------------------------
    def build(self):
        ts = WordTS(self.mod.name)
        regs = set(self.nxt) | set(self.rst)
        # inputs: declared inputs that are not registers (clk/reset are control, dropped)
        for n, s in self.mod.signals.items():
            if s.get("dir") == "input" and n not in regs and n not in self.arrays \
                    and n not in (self.mod.clock, self.mod.reset) and "stype" not in s:
                ts.add_input(n, self.width[n])
        # word registers
        for n in regs:
            if n in self.arrays or n == self.mod.reset:
                continue
            init = self.term(self.rst[n]) if n in self.rst else None
            ts.add_word(n, self.width.get(n, 1), init=init,
                        nxt=self.term(self.nxt[n]) if n in self.nxt else None)
        # memories
        for n in self.arrays:
            aw, dw = self._mem_sort(n)
            nxt = self._mem_next(self.nxt[n], n) if n in self.nxt else None
            ts.add_mem(n, aw, dw, nxt=nxt)
        # property / assumptions (a bare Sig-free AST from the checker)
        if self.mod.prop is not None:
            ts.prop = self._as1(self.mod.prop)
        for a in self.mod.assumptions:
            ts.assumptions.append(self._as1(a))
        return ts


def build_word(*paths):
    texts = []
    for p in paths:
        with open(p) as f:
            texts.append(f.read())
    return WordElaborator(parse_merge(texts)).build()


if __name__ == "__main__":
    import os
    from word import wbmc, w_kinduction
    here = os.path.dirname(os.path.abspath(__file__))
    ch2 = os.path.join(here, "..", "..", "ch2_rtl_fv_examples")

    # Build the WordTS straight from the book sync_fifo.sv -- memory and all -- and prove
    # its data-independence: a value written to a slot is read back intact. The address
    # is symbolic (the 8x32 memory is never bit-blasted).
    fifo = os.path.join(ch2, "04_sync_fifo")
    ts = build_word(os.path.join(fifo, "sync_fifo.sv"),
                    os.path.join(fifo, "fv", "sync_fifo_word_props.sv"))
    print(f"[word_frontend] sync_fifo -> WordTS: {len(ts.state)} state "
          f"({sum(1 for n in ts.state if isinstance(ts.widths[n], tuple))} memory), "
          f"{len(ts.inputs)} inputs")
    r = w_kinduction(ts, 1)
    print(f"[word_frontend] FIFO write-then-read (address symbolic, memory not blasted): {r[0]}")
    assert r[0] == "SAFE"
    print("[word_frontend] OK: the book sync_fifo.sv is read into a WordTS and its memory "
          "contract proved word-level with the address kept symbolic")
