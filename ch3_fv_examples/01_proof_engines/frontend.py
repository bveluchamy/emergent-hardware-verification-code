"""
frontend.py -- a small synthesizable-SystemVerilog reader.

The chapter's engines consume a TransitionSystem (state bits, inputs, next-state
functions, init, the bad condition). Real formal tools build that from RTL; so
does this. It reads a restricted synthesizable subset --

    typedef enum logic [1:0] {IDLE=0, C5=1, C10=2} state_t;   // named constants
    localparam logic [7:0] PRICE = 8'd15;                     // constants
    state_t state, next_state;
    logic w;
    assign w = (state == C5);                                 // continuous comb
    always_comb begin                                         // procedural comb
      next_state = state;                                     //   default (no latch)
      case (state)
        IDLE: if (nickel) next_state = C5;
        C5:   if (dime)   next_state = C10;
      endcase
    end
    always_ff @(posedge clk or negedge rst_n)                 // sequential (+async reset)
      if (!rst_n) state <= IDLE;
      else        state <= next_state;
    assert property (@(posedge clk) disable iff (!rst_n) (state <= 2'd2));

-- lexes it, parses it (recursive descent), folds each procedural block into
functional per-signal expressions, lowers every expression to the gate /
bit-vector DSL of circuit.py, and elaborates a TransitionSystem: input ports
become inputs, registers written in the always_ff become state bits (reset value
-> init, else-branch expression -> next), continuous and always_comb assigns
become shared combinational nodes, enum labels / localparams become constants,
and the asserted property's negation becomes `bad`.

It is deliberately small -- "just enough to prove the Chapter 2 designs from
their book files" -- not an IEEE-1800 parser. The point is that the model the
engines prove is *derived from RTL*, not hand-built. Beyond the FSM subset
(enum, case, if/else in always_comb, async reset) it reads what the book
checkers actually use: packed structs and packages, `bind` with array ports,
unpacked arrays and bounded SV queues (compile-time expanded), user functions
(inlined), `generate` loops (unrolled by token replay), `$past`/`$stable`
(shadow registers), procedural immediate asserts (path-guarded), and
`p |-> ##[lo:hi] q` delay windows lowered EXACTLY to aux-bit monitors -- only a
genuinely unbounded consequent (s_eventually) becomes a liveness obligation.
Blocking vs nonblocking assignment is honored (a `<=` read gives the pre-edge
value), which is what a checker's blocking queue bookkeeping and the synthesized
monitor chains each depend on.
"""

from __future__ import annotations
import re
from circuit import (Sig, BV, VAR, CONST, AND, OR, NOT, XOR, TRUE, FALSE,
                     bv_const, bv_eq, bv_ite, bv_add, bv_sub, bv_ge_const,
                     TransitionSystem)


# ---------------------------------------------------------------------------
# Lexer
# ---------------------------------------------------------------------------
_TOKEN = re.compile(r"""
    (?P<ws>\s+)
  | (?P<lcomment>//[^\n]*)
  | (?P<bcomment>/\*.*?\*/)
  | (?P<str>"(?:\\.|[^"\\])*")
  | (?P<sized>\d+'[bdhBDH][0-9a-fA-F_xXzZ]+)
  | (?P<cast>\d+'(?=\())
  | (?P<pattern>'\{)
  | (?P<unsized>'[01xzXZ])
  | (?P<tick>'(?=\())
  | (?P<num>\d+)
  | (?P<sysid>\$[A-Za-z_][A-Za-z0-9_]*)
  | (?P<dollar>\$)
  | (?P<id>[A-Za-z_][A-Za-z0-9_$]*)
  | (?P<op>\|->|\|=>|\#\#|::|<<|>>|<=|>=|==|!=|&&|\|\||[-+~!&|\^?:()\[\]{}.,;@=<>*\#])
""", re.VERBOSE | re.DOTALL)

_KEYWORDS = {"module", "endmodule", "input", "output", "inout", "logic", "reg",
             "wire", "bit", "always_ff", "always_comb", "assign", "begin", "end",
             "if", "else", "posedge", "negedge", "assert", "assume", "property",
             "disable", "iff", "typedef", "enum", "case", "endcase",
             "localparam", "parameter", "default", "or", "s_eventually"}


def preprocess(src: str, defines=None) -> str:
    """A minimal preprocessor: `ifdef / `ifndef / `else / `endif / `define. Unknown
    macros are undefined, so `ifdef VERILATOR takes the `else (formal) branch -- which
    is exactly the concurrent-SVA form the checkers write for a real formal tool."""
    defs = set(defines or ())
    out, stack = [], []                                  # stack of [emitting, taken, parent]
    emitting = lambda: all(fr[0] for fr in stack)
    for line in src.split("\n"):
        s = line.lstrip()
        if s.startswith("`ifdef ") or s.startswith("`ifndef "):
            macro = s.split()[1]
            cond = (macro in defs) if s.startswith("`ifdef") else (macro not in defs)
            par = emitting()
            stack.append([par and cond, cond, par])
        elif s.startswith("`else"):
            fr = stack[-1]
            fr[0] = fr[2] and not fr[1]
            fr[1] = True
        elif s.startswith("`endif"):
            stack.pop()
        elif s.startswith("`define"):
            parts = s.split()
            if emitting() and len(parts) >= 2:
                defs.add(parts[1])
        elif s.startswith("`include"):
            # Dropping an `include would silently omit a whole file's
            # properties/assumptions and could make a proof vacuous. The
            # driver passes every source explicitly; surface this loudly.
            raise SyntaxError(
                f"`include is not resolved by this frontend; pass the file "
                f"explicitly on the command line instead: {s}")
        elif s.startswith("`"):                          # benign: `timescale, `default_nettype
            pass
        elif emitting():
            out.append(line)
    return "\n".join(out)


def tokenize(src: str):
    toks, i = [], 0
    while i < len(src):
        m = _TOKEN.match(src, i)
        if not m:
            raise SyntaxError(f"lex error near: {src[i:i+20]!r}")
        i = m.end()
        kind = m.lastgroup
        if kind in ("ws", "lcomment", "bcomment"):
            continue
        text = m.group()
        if kind == "id" and text in _KEYWORDS:
            toks.append(("kw", text))
        else:
            toks.append((kind, text))
    toks.append(("eof", ""))
    return toks


def _const_value_width(text: str):
    """Parse a sized literal like 3'd4 / 1'b0 / 8'hFF -> (value, width). Any
    x/z bits are read as 0 (the engines are 2-valued)."""
    w, rest = text.split("'")
    base = {"b": 2, "d": 10, "h": 16, "o": 8}[rest[0].lower()]
    digits = re.sub(r"[xXzZ]", "0", rest[1:].replace("_", ""))
    return int(digits, base), int(w)


# ---------------------------------------------------------------------------
# Parser -> a tiny AST (expressions stay as tuples; module is a dataclass-ish)
# ---------------------------------------------------------------------------
class Module:
    def __init__(self, name):
        self.name = name
        self.signals = {}     # name -> {"dir": in/out/None, "width": w, "stype": struct?}
        self.consts = {}      # name -> (value, width)   -- enum labels + localparams
        self.types = {}       # typedef name -> width (scalar/enum types)
        self.structs = {}     # struct typedef name -> [(field, width), ...]  (flattened)
        self.assigns = []     # (lhs_name, expr_ast)     -- continuous assigns
        self.comb_stmts = []  # [stmt_ast]               -- always_comb bodies
        self.reset_stmt = None  # stmt_ast run under reset (-> init)
        self.next_stmt = None   # stmt_ast run otherwise (-> next)
        self.clock = None
        self.reset = None     # reset signal name (from `if (rst)` / `if (!rst_n)`)
        self.prop = None      # expr_ast that must hold (safety)
        self.liveness = []    # [(antecedent_ast, eventually_ast)]  -- a |-> s_eventually b
        self.assumptions = [] # [expr_ast]  -- assume property (bool), constrains the env
        self.properties = {}  # named property -> parsed spec (from property..endproperty)
        self.next_props = []  # [(ante, cons, is_assume)] from `p |=> q` (desugared to a reg)
        self.windows = []     # [(lo, hi, ante, cons, is_assume)] from `p |-> ##[lo:hi] q`
        self.covers = []      # [expr] -- cover property reachability targets (BMC sanity)
        self.functions = {}   # name -> (arg_names, body_expr)  -- inlined at desugar
        self.queues = {}      # name -> (elem_width, elem_stype) -- bounded SV queues
        self.ports = []       # port names in order (which merged signals are the interface)
        self.arrays = {}      # name -> (dims, elem_width, elem_stype)  -- unpacked memory arrays


# Integral type keywords whose width the engines fold to a bit count.
_TYPEWORDS = {"logic", "reg", "wire", "bit", "int", "integer", "unsigned",
              "signed", "byte", "shortint", "longint"}

# Binary operator precedence (higher binds tighter), Verilog-flavoured.
# IEEE 1800 binding, loosest to tightest: ?: < || < && < | < ^ < & <
# equality < relational < shift < additive < multiplicative. Shift must bind
# tighter than relational (they were tied at 8, mis-associating `a < b << c`).
_PREC = {"?": 1, "||": 2, "&&": 3, "|": 4, "^": 5, "&": 6,
         "==": 7, "!=": 7, "<": 8, "<=": 8, ">": 8, ">=": 8,
         "<<": 9, ">>": 9, "+": 10, "-": 10, "*": 11}


class Parser:
    def __init__(self, toks, overrides=None, unit=None):
        self.toks = toks
        self.p = 0
        self.overrides = overrides or {}    # param name -> forced value (reduced-size proof)
        # `unit` is the compilation-unit scope accumulated over earlier FILES
        # (consts, types, structs) -- a checker file resolves the design's / the
        # package's types at PARSE time, not just at elaboration. File order
        # matters, exactly as it does for a real tool's compilation unit.
        self.unit = unit

    def peek(self):
        return self.toks[self.p]

    def next(self):
        t = self.toks[self.p]
        self.p += 1
        return t

    def eat(self, text):
        k, v = self.toks[self.p]
        if v != text:
            raise SyntaxError(f"expected {text!r}, got {v!r}")
        self.p += 1
        return v

    def at(self, text):
        return self.toks[self.p][1] == text

    def at_eof(self):
        return self.toks[self.p][0] == "eof"

    # ---- module ----
    def parse_module(self) -> Module:
        mod = Module("")
        if self.unit:                            # seed the $unit scope from earlier files
            mod.consts.update(self.unit.get("consts", {}))
            mod.types.update(self.unit.get("types", {}))
            mod.structs.update(self.unit.get("structs", {}))
        self._consts = mod.consts
        while not self.at("module"):             # $unit-scope typedefs / params / packages
            if self.at_eof():                    # a package-only / $unit-only file: no module,
                return mod                       # its decls still feed the compilation unit
            t = self.peek()[1]
            if t == "typedef":
                self.parse_typedef(mod)
            elif t in ("localparam", "parameter"):
                self.parse_param(mod)
            elif t in ("package", "import"):      # inline a package's decls; drop `import`
                self.parse_item(mod)
            else:
                raise SyntaxError(f"unexpected top-level item {t!r} before module")
        self.eat("module")
        mod.name = self.next()[1]
        while self.at("import"):             # module-header import: `module m import pkg::*; (`
            while not self.at(";"):
                self.next()
            self.eat(";")
        if self.at("#"):                     # parameter port list #( ... ) -- skip decls, keep values
            self.next(); self.eat("(")
            self._parse_param_decls(mod)
            self.eat(")")
        if self.at("("):
            self.parse_port_list(mod)
        self.eat(";")
        while not self.at("endmodule"):
            self.parse_item(mod)
        self.eat("endmodule")
        return mod

    def _parse_param_decls(self, mod):
        while not self.at(")"):
            if self.peek()[1] == "parameter":
                self.next()
            while self.peek()[1] in _TYPEWORDS:   # optional type: int / logic / int unsigned
                self.next()
            self._width()                    # ignore declared width of the param itself
            nm = self.next()[1]
            self.eat("=")
            val = self._const_of(self.parse_expr())
            mod.consts[nm] = (self.overrides.get(nm, val), 32)
            if self.at(","):
                self.eat(",")

    def _width(self):
        """Parse an optional [hi:lo] and return the bit width. hi/lo may be
        constant expressions over already-declared parameters."""
        if self.at("["):
            self.eat("[")
            hi = self._const_of(self.parse_expr())
            self.eat(":")
            lo = self._const_of(self.parse_expr())
            self.eat("]")
            return hi - lo + 1
        return 1

    def _const_of(self, ast):
        """Fold a constant expression (literals + already-known params) to an int."""
        tag = ast[0]
        if tag == "const":
            return ast[1]
        if tag == "fill":
            return ast[1]
        if tag == "id" and ast[1] in getattr(self, "_consts", {}):
            return self._consts[ast[1]][0]
        if tag == "bin":
            a, b = self._const_of(ast[2]), self._const_of(ast[3])
            return {"+": a + b, "-": a - b, "*": a * b, "/": a // b,
                    "<<": a << b, ">>": a >> b}[ast[1]]
        if tag == "un" and ast[1] == "-":
            return -self._const_of(ast[2])
        if tag == "call" and ast[1] in ("$clog2", "clog2"):
            n = self._const_of(ast[2][0])
            return 0 if n <= 1 else (n - 1).bit_length()
        raise SyntaxError(f"expected a constant expression, got {ast}")

    def _register_signal(self, mod, name, stype, direction, width):
        """Register a signal; a struct-typed signal is flattened to one signal per
        field (name.field), the struct itself kept as a marker for whole-struct ops."""
        if stype in mod.structs:
            for f, w in mod.structs[stype]:
                mod.signals[f"{name}.{f}"] = {"dir": direction, "width": w}
            mod.signals[name] = {"dir": direction, "width": width, "stype": stype}
        else:
            mod.signals.setdefault(name, {"dir": direction, "width": width})

    def parse_port_list(self, mod):
        # Comma-separated ports inherit the previous port's direction and type, so
        # `input logic clk, rst_n, req0` makes all three inputs (IEEE-1800 ANSI ports).
        self.eat("(")
        last_dir, last_w, last_stype = None, 1, None
        while not self.at(")"):
            if self.peek()[1] in ("input", "output", "inout"):
                last_dir = self.next()[1]
                last_w, last_stype = 1, None      # a fresh direction spec re-defaults the type
            if self.peek()[1] in ("logic", "reg", "wire", "bit"):
                self.next()
                last_w, last_stype = self._width(), None
            elif self.peek()[1] in mod.types:
                tn = self.next()[1]
                last_w, last_stype = mod.types[tn], (tn if tn in mod.structs else None)
            elif self.at("["):
                last_w, last_stype = self._width(), None
            nm = self.next()[1]
            dims = self._unpacked_dims()          # an ARRAY port (a checker probing a memory)
            if dims:
                mod.arrays[nm] = (dims, last_w, last_stype)
                mod.signals[nm] = {"dir": last_dir, "width": last_w, "stype": last_stype}
            else:
                self._register_signal(mod, nm, last_stype, last_dir, last_w)
            mod.ports.append(nm)
            if self.at(","):
                self.eat(",")
        self.eat(")")

    def parse_item(self, mod):
        # keep _const_of aware of the params/consts seen so far
        self._consts = mod.consts
        self._mod = mod                          # for procedural local-variable decls
        # an optional statement label:  a_funds_safe: assert property (...)
        if self.peek()[0] == "id" and self.toks[self.p + 1][1] == ":":
            self.next()
            self.eat(":")
        t = self.peek()[1]
        if t == "package":                       # package NAME; <typedefs/params> endpackage
            self.eat("package")
            self.next()
            self.eat(";")
            while not self.at("endpackage"):
                self.parse_item(mod)
            self.eat("endpackage")
            if self.at(":"):                     # optional `endpackage : name`
                self.eat(":")
                self.next()
            if self.at(";"):
                self.eat(";")
            return
        if t == "import":                        # import pkg::*;  (contents already inlined)
            while not self.at(";"):
                self.next()
            self.eat(";")
            return
        if t == "property":
            self.parse_property(mod)
            return
        if t == "generate":
            self.parse_generate(mod)
            return
        if t == "genvar":                        # standalone genvar decl
            self.next(); self.next(); self.eat(";")
            return
        if t == "function":
            self.parse_function(mod)
            return
        if t == "typedef":
            self.parse_typedef(mod)
        elif t in ("localparam", "parameter"):
            self.parse_param(mod)
        elif t in ("logic", "reg", "wire", "bit") or t in mod.types:
            self.parse_decl(mod)
        elif t == "assign":
            self.eat("assign")
            lhs = self._parse_lvalue()
            self.eat("=")
            mod.assigns.append((lhs, self.parse_expr()))
            self.eat(";")
        elif t == "always_ff":
            self.parse_always_ff(mod)
        elif t == "always":                  # plain `always @(posedge clk)` -- clocked;
            self.parse_always_ff(mod, kw="always")   # the book's abstract checker uses it
        elif t == "always_comb":
            self.next()
            mod.comb_stmts.append(self.parse_stmt())
        elif t == "assert":
            self.parse_assert(mod)
        elif t == "assume":
            self.parse_assume(mod)
        elif t == "cover":
            self.parse_cover(mod)
        else:
            raise SyntaxError(f"unexpected item {t!r}")

    def parse_typedef(self, mod):
        self.eat("typedef")
        if self.at("struct"):
            self._consts = mod.consts            # let field widths resolve params
            self.eat("struct")
            if self.at("packed"):
                self.eat("packed")
            self._width()                        # optional signing/[W] on the struct itself
            self.eat("{")
            fields = []
            while not self.at("}"):
                ft = self.next()[1]              # field base type: `logic`, an enum, or a struct
                if ft in mod.types:
                    w = mod.types[ft]
                elif ft in mod.structs:
                    w = sum(fw for _, fw in mod.structs[ft])
                else:
                    w = self._width()            # logic [W-1:0]
                fname = self.next()[1]
                fields.append((fname, w))
                self.eat(";")
            self.eat("}")
            tname = self.next()[1]
            mod.structs[tname] = fields
            mod.types[tname] = sum(w for _, w in fields)   # packed width, for whole-struct ops
            self.eat(";")
            return
        self.eat("enum")
        if self.peek()[1] in ("logic", "reg", "wire", "bit"):
            self.next()
        w = self._width()
        self.eat("{")
        val = 0
        labels = []                          # (name, value) for this enum
        while not self.at("}"):
            nm = self.next()[1]
            if self.at("="):
                self.eat("=")
                val = self._const_of(self.parse_expr())
            labels.append((nm, val))
            val += 1
            if self.at(","):
                self.eat(",")
        self.eat("}")
        # Width must cover the largest label, or a state ≥ 2^w folds away
        # (an unbased `enum {A,B,C}` defaults w=1, so C=2 would read as 0).
        need = max((v.bit_length() for _, v in labels), default=1)
        if w < need:
            w = need
        for nm, v in labels:
            mod.consts[nm] = (v, w)
        tname = self.next()[1]
        mod.types[tname] = w
        self.eat(";")

    def parse_param(self, mod):
        self.next()                          # localparam / parameter
        while self.peek()[1] in _TYPEWORDS:  # optional type: int / logic / int unsigned / ...
            self.next()
        w = self._width()
        while True:
            nm = self.next()[1]
            self.eat("=")
            val = self._const_of(self.parse_expr())
            mod.consts[nm] = (self.overrides.get(nm, val), w)
            if self.at(","):
                self.eat(",")
            else:
                break
        self.eat(";")

    def parse_decl(self, mod):
        t = self.next()[1]
        stype = t if t in mod.structs else None
        w = mod.types[t] if t in mod.types else self._width()
        while True:
            nm = self.next()[1]
            dims = self._unpacked_dims()          # `mem [N]` / `arr [0:A-1][0:B-1]` / `q [$]`
            if dims == ["$"]:
                mod.queues[nm] = (w, stype)        # a bounded SV queue (finite by its guards)
            elif dims:
                mod.arrays[nm] = (dims, w, stype)  # an unpacked memory, not a flat signal
            else:
                self._register_signal(mod, nm, stype, None, w)
            if self.at(","):
                self.eat(",")
            else:
                break
        self.eat(";")

    def _unpacked_dims(self):
        """Trailing unpacked dimensions after a signal name: `[N]` or `[lo:hi]`, each an
        array level. Returns [size, ...] (empty for a plain signal)."""
        dims = []
        while self.at("["):
            self.eat("[")
            if self.at("$"):                      # `[$]` -- an (unbounded) SV queue
                self.next()
                self.eat("]")
                dims.append("$")
                continue
            a = self._const_of(self.parse_expr())
            if self.at(":"):
                self.eat(":")
                b = self._const_of(self.parse_expr())
                self.eat("]")
                dims.append(abs(a - b) + 1)
            else:
                self.eat("]")
                dims.append(a)
        return dims

    def parse_always_ff(self, mod, kw="always_ff"):
        self.eat(kw)
        self.eat("@")
        self.eat("(")
        self.eat("posedge")
        mod.clock = self.next()[1]
        async_resets = []                    # signals in `or negedge/posedge X`
        while self.at("or"):                 # e.g. `or negedge rst_n`
            self.eat("or")
            self.next()                      # posedge / negedge
            async_resets.append(self.next()[1])  # signal (keep, do not discard)
        self.eat(")")
        body = self.parse_stmt()
        if body[0] == "block" and len(body[1]) == 1:
            body = body[1][0]
        # A block is a reset block iff its outer `if` tests a reset signal. A bare
        # `if (id)` / `if (!id)` is treated as reset ONLY when the signal is in the
        # async sensitivity list or matches a reset-name convention -- otherwise a
        # synchronous clear/enable (`if (clr)`, `if (en)`) would be silently taken
        # as reset and its clocked body dropped. The FIFO's outer condition
        # `if (push && !full)` is not a bare id, so it stays next-state either way.
        reset_stmt, next_stmt = None, body
        if body[0] == "if":
            try:
                sig = _reset_signal(body[1])
            except SyntaxError:
                sig = None
            if sig is not None and (sig in async_resets or _looks_like_reset(sig)):
                mod.reset = sig
                _, _, reset_stmt, next_stmt = body
            else:
                reset_stmt, next_stmt = None, body
        # Merge multiple always_ff blocks (each contributes its own registers):
        # accumulate the reset/next statements so all sequential state survives.
        if mod.next_stmt is None:
            mod.reset_stmt, mod.next_stmt = reset_stmt, next_stmt
        else:
            mod.reset_stmt = ("block", _stmts(mod.reset_stmt) + _stmts(reset_stmt))
            mod.next_stmt = ("block", _stmts(mod.next_stmt) + _stmts(next_stmt))

    def _eat_clocking(self):
        """@(posedge clk) [disable iff (...)] -- the leading clocking/reset gate,
        shared by assert and assume; parsed and discarded (reset is handled by the
        always_ff init and the from-reset proof semantics)."""
        self.eat("@")
        self.eat("(")
        self.next()                          # posedge
        self.next()                          # clk
        self.eat(")")
        if self.at("disable"):
            self.eat("disable")
            self.eat("iff")
            self.eat("(")
            self.parse_expr()                # rst / !rst_n
            self.eat(")")

    def _delay_range(self):
        """`##N` -> (N, N); `##[lo:hi]` -> (lo, hi); `##[lo:$]` -> (lo, None) --
        an unbounded window, which is a liveness obligation, not a safety one."""
        self.eat("##")
        if self.at("["):
            self.eat("[")
            lo = self._const_of(self.parse_expr())
            self.eat(":")
            if self.at("$"):
                self.next()
                hi = None
            else:
                hi = self._const_of(self.parse_expr())
            self.eat("]")
            return lo, hi
        n = self._const_of(self.parse_primary())
        return n, n

    def _parse_property_spec(self):
        """A property body: `<clocking> ante [ |-> | |=> ] [s_eventually|##..] cons`.
        Returns ('safety', bool) | ('live', ante, cons) | ('next', ante, cons) |
        ('window', lo, hi, ante, cons).

        `p |-> ##[lo:hi] q` is lowered EXACTLY, not approximated: it becomes a
        window monitor (one aux bit per cycle of horizon) whose violation is a
        plain safety property -- see _desugar_windows. Only a genuinely unbounded
        consequent (`s_eventually q`, `##[lo:$] q`) is a liveness obligation.

        A SEQUENCE antecedent `a ##[0|1:$] b |-> ...` is supported through a
        sticky monitor: a register remembers that `a` has occurred, and the
        effective antecedent is that register conjoined with `b` -- the exact
        "some earlier a, now b" match set (see _desugar_sticky)."""
        self._eat_clocking()
        ante = self.parse_expr()
        while self.at("##"):                 # sequence antecedent: a ##[lo:$] b
            lo, hi = self._delay_range()
            if hi is not None or lo > 1:
                raise SyntaxError("sequence antecedents support ##[0:$] / ##[1:$] only")
            ante = ("sticky", lo, ante, self.parse_expr())
        if self.at("|->") or self.at("|=>"):
            arrow = self.next()[1]
            if self.at("s_eventually"):
                self.eat("s_eventually")
                return ("live", ante, self.parse_expr())
            if self.at("##"):
                lo, hi = self._delay_range()
                cons = self.parse_expr()
                if hi is None:                                    # ##[lo:$]: liveness
                    return ("live", ante, cons)
                if arrow == "|=>":                                # |=> ##[l:h] == |-> ##[l+1:h+1]
                    lo, hi = lo + 1, hi + 1
                return ("window", lo, hi, ante, cons)
            cons = self.parse_expr()
            if arrow == "|=>":
                return ("next", ante, cons)                       # p |=> q (next cycle)
            return ("safety", ("bin", "||", ("un", "!", ante), cons))   # p |-> q
        return ("safety", ante)

    def _apply_spec(self, mod, spec, is_assume):
        kind = spec[0]
        if kind == "safety":
            if is_assume:
                mod.assumptions.append(spec[1])
            else:
                mod.prop = spec[1] if mod.prop is None else ("bin", "&&", mod.prop, spec[1])
        elif kind == "live":
            if is_assume:
                raise SyntaxError("liveness assumptions are not supported")
            mod.liveness.append((spec[1], spec[2]))
        elif kind == "window":                                    # p |-> ##[lo:hi] q
            mod.windows.append((spec[1], spec[2], spec[3], spec[4], is_assume))
        else:                                                     # ("next", ...) -- p |=> q
            mod.next_props.append((spec[1], spec[2], is_assume))

    def _skip_action(self):
        """Skip an optional assert/assume fail action:  else $error(...) ."""
        if self.at("else"):
            while not self.at(";") and not self.at_eof():
                self.next()

    def parse_property(self, mod):
        """property NAME[(arg, ...)]; <spec> ; endproperty -- stored as
        (arg_names, spec); a FORMAL ARGUMENT is instantiated by substitution at
        each `assert property (NAME(actual))` site, exactly as IEEE 1800 defines
        it (the book's per-way coherence properties use this form)."""
        self.eat("property")
        name = self.next()[1]
        args = []
        if self.at("("):
            self.eat("(")
            while not self.at(")"):
                args.append(self.next()[1])
                if self.at(","):
                    self.eat(",")
            self.eat(")")
        self.eat(";")
        mod.properties[name] = (args, self._parse_property_spec())
        if self.at(";"):
            self.eat(";")
        self.eat("endproperty")

    def _named_spec(self, mod):
        """A reference to a named property, with optional actuals: p or p(e, ...)."""
        name = self.next()[1]
        argn, spec = mod.properties[name]
        actuals = []
        if self.at("("):
            actuals = self._args()
        if len(actuals) != len(argn):
            raise SyntaxError(f"property {name} expects {len(argn)} argument(s)")
        if not argn:
            return spec
        env = dict(zip(argn, actuals))
        sub = lambda a: _subst_ids(a, env) if isinstance(a, tuple) else a
        return tuple(spec[:1]) + tuple(sub(x) for x in spec[1:])

    def parse_assert(self, mod):
        self.eat("assert")
        self.eat("property")
        self.eat("(")
        spec = self._parse_property_spec() if self.at("@") else self._named_spec(mod)
        self.eat(")")
        self._skip_action()
        self.eat(";")
        self._apply_spec(mod, spec, is_assume=False)

    def parse_assume(self, mod):
        self.eat("assume")
        self.eat("property")
        self.eat("(")
        spec = self._parse_property_spec() if self.at("@") else self._named_spec(mod)
        self.eat(")")
        self._skip_action()
        self.eat(";")
        self._apply_spec(mod, spec, is_assume=True)

    def parse_cover(self, mod):
        """cover property (<clocking> expr [##[0|1:$] expr]*); -- a reachability
        target: can the sequence be completed at all? Checked by BMC as a sanity
        against vacuous assumption sets (the book: "run these first"). Never
        gates a proof."""
        self.eat("cover")
        self.eat("property")
        self.eat("(")
        self._eat_clocking()
        e = self.parse_expr()
        while self.at("##"):
            lo, hi = self._delay_range()
            if hi is not None or lo > 1:
                raise SyntaxError("cover sequences support ##[0:$] / ##[1:$] only")
            e = ("sticky", lo, e, self.parse_expr())
        self.eat(")")
        self._skip_action()
        self.eat(";")
        mod.covers.append(e)

    def parse_generate(self, mod):
        """generate for (genvar w = LO; w < HI; w++) begin : label <items> end endgenerate
        Unrolled by TOKEN REPLAY: the body's token span is re-parsed once per
        iteration with the genvar token substituted by the literal index, so every
        stored AST is already constant -- a `$past(bus_req.set)` under `[w]` needs
        no later genvar resolution."""
        self.eat("generate")
        while not self.at("endgenerate"):
            self.eat("for")
            self.eat("(")
            if self.at("genvar"):
                self.next()
            var = self.next()[1]
            self.eat("=")
            lo = self._const_of(self.parse_expr())
            self.eat(";")
            bound = self.parse_expr()
            if bound[0] != "bin" or bound[1] not in ("<", "<="):
                raise SyntaxError(f"unsupported generate bound {bound}")
            hi = self._const_of(bound[3]) + (1 if bound[1] == "<=" else 0)
            self.eat(";")
            while not self.at(")"):
                self.next()
            self.eat(")")
            self.eat("begin")
            if self.at(":"):
                self.eat(":")
                self.next()
            start, depth = self.p, 1                 # find the matching `end`
            q = self.p
            while depth:
                v = self.toks[q][1]
                depth += (v == "begin") - (v == "end")
                q += 1
            span = self.toks[start:q - 1]
            for k in range(lo, hi):
                sub = [(("num", str(k)) if (kk == "id" and vv == var) else (kk, vv))
                       for kk, vv in span] + [("eof", "")]
                child = Parser(sub, overrides=self.overrides)
                child._consts = mod.consts
                child._mod = mod
                while not child.at_eof():
                    child.parse_item(mod)
            self.p = q                                # past the `end`
        self.eat("endgenerate")

    def parse_function(self, mod):
        """function [automatic] <type> name(<args>); <if/return chain> endfunction --
        stored as (arg names, one expression): an `if (c) return e;` chain becomes
        nested ternaries, and calls are inlined at desugar time."""
        self.eat("function")
        if self.at("automatic"):
            self.next()
        while self.peek()[1] in _TYPEWORDS:
            self.next()
        self._width()
        name = self.next()[1]
        args = []
        self.eat("(")
        while not self.at(")"):
            while self.peek()[1] in _TYPEWORDS:
                self.next()
            self._width()
            args.append(self.next()[1])
            if self.at(","):
                self.eat(",")
        self.eat(")")
        self.eat(";")
        stmts = []
        while not self.at("endfunction"):
            stmts.append(self.parse_stmt())
        self.eat("endfunction")

        def chain(ss):
            if not ss:
                raise SyntaxError(f"function {name}: fell off the end without a return")
            s = ss[0]
            if s[0] == "return":
                return s[1]
            if s[0] == "if" and s[3] is None and s[2][0] == "return":
                return ("?:", s[1], s[2][1], chain(ss[1:]))
            if s[0] == "block":
                return chain(list(s[1]) + ss[1:])
            raise SyntaxError(f"function {name}: unsupported statement {s[0]}")
        mod.functions[name] = (args, chain(stmts))

    def parse_bind(self):
        """bind <target> <checker> <inst> (.*);  ->  (target, checker)."""
        self.eat("bind")
        target = self.next()[1]
        checker = self.next()[1]
        if self.at("#"):                                         # #(.P(v), ...) param override
            self.next()
            self.eat("(")
            depth = 1
            while depth > 0 and not self.at_eof():
                v = self.next()[1]
                depth += (v == "(") - (v == ")")
        self.next()                                              # instance name
        self.eat("(")
        depth = 1
        while depth > 0 and not self.at_eof():
            v = self.next()[1]
            depth += (v == "(") - (v == ")")
        self.eat(";")
        return (target, checker)

    # ---- statements (procedural: assignment / if / case / begin-end) ----
    def parse_stmt(self):
        if self.peek()[1] in ("unique", "priority", "unique0"):   # case/if qualifier -- ignore
            self.next()
            return self.parse_stmt()
        if self.at("return"):                     # inside a function body
            self.eat("return")
            e = self.parse_expr()
            self.eat(";")
            return ("return", e)
        if self.at("assert"):                     # immediate assert in procedural code:
            self.eat("assert")                    # under its if/case path condition it is
            self.eat("(")                         # a safety property like any other
            e = self.parse_expr()
            self.eat(")")
            self._skip_action()
            self.eat(";")
            return ("passert", e)
        if self.at("void"):                       # void'(q.pop_front());
            self.next()
            self.eat("'")
            self.eat("(")
            s = self.parse_call_stmt()
            self.eat(")")
            self.eat(";")
            return s
        if self.peek()[1] == "automatic" or (self.peek()[1] in _TYPEWORDS
                                             and self.toks[self.p + 1][1] != "("):
            # procedural local variables: `automatic logic [W] a = e, b, c;`
            if self.peek()[1] == "automatic":
                self.next()
            while self.peek()[1] in _TYPEWORDS:
                self.next()
            w = self._width()
            inits = []
            while True:
                name = self.next()[1]
                self._mod.signals.setdefault(name, {"dir": None, "width": w})
                if self.at("="):
                    self.eat("=")
                    inits.append(("assign", name, self.parse_expr(), False))
                if self.at(","):
                    self.eat(",")
                else:
                    break
            self.eat(";")
            return ("block", inits)                # inits are BLOCKING comb assigns
        if self.at("begin"):
            self.eat("begin")
            if self.at(":"):                      # named block: begin : label
                self.eat(":")
                self.next()
            body = []
            while not self.at("end"):
                body.append(self.parse_stmt())
            self.eat("end")
            return ("block", body)
        if self.at("for"):                        # for (int v = LO; v </<= HI; v++) body
            self.eat("for")
            self.eat("(")
            while self.peek()[1] in _TYPEWORDS:   # optional `int`
                self.next()
            var = self.next()[1]
            self.eat("=")
            lo = self.parse_expr()
            self.eat(";")
            bound = self.parse_expr()             # `v < HI` or `v <= HI`
            if bound[0] != "bin" or bound[1] not in ("<", "<="):
                raise SyntaxError(f"unsupported for-loop bound {bound}")
            hi = bound[3] if bound[1] == "<" else ("bin", "+", bound[3], ("const", 1, None))
            self.eat(";")
            while not self.at(")"):               # the increment `v++` / `v = v + 1`
                self.next()
            self.eat(")")
            body = self.parse_stmt()
            return ("for", var, lo, hi, body)      # hi is the EXCLUSIVE upper bound
        if self.at("if"):
            self.eat("if")
            self.eat("(")
            cond = self.parse_expr()
            self.eat(")")
            then = self.parse_stmt()
            els = None
            if self.at("else"):
                self.eat("else")
                els = self.parse_stmt()
            return ("if", cond, then, els)
        if self.at("case"):
            self.eat("case")
            self.eat("(")
            sel = self.parse_expr()
            self.eat(")")
            items, default = [], None
            while not self.at("endcase"):
                if self.at("default"):
                    self.eat("default")
                    if self.at(":"):
                        self.eat(":")
                    default = self.parse_stmt()
                else:
                    labels = [self.parse_expr()]
                    while self.at(","):
                        self.eat(",")
                        labels.append(self.parse_expr())
                    self.eat(":")
                    items.append((labels, self.parse_stmt()))
            self.eat("endcase")
            return ("case", sel, items, default)
        # assignment: lhvalue =/<= expr ;   or a method-call statement q.push_back(x);
        lhs = self._parse_lvalue()
        if self.at("(") and isinstance(lhs, str) and "." in lhs:
            base, meth = lhs.rsplit(".", 1)
            args = self._args()
            self.eat(";")
            return ("qcall", base, meth, args)
        op = self.next()[1]
        if op not in ("=", "<="):
            raise SyntaxError(f"expected assignment, got {op!r}")
        e = self.parse_expr()
        self.eat(";")
        return ("assign", lhs, e, op == "<=")      # 4th field: nonblocking?

    def parse_call_stmt(self):
        """A bare method/task call used as a statement: q.pop_front()."""
        lhs = self._parse_lvalue()
        if self.at("(") and isinstance(lhs, str) and "." in lhs:
            base, meth = lhs.rsplit(".", 1)
            return ("qcall", base, meth, self._args())
        raise SyntaxError(f"expected a method call, got {lhs!r}")

    # ---- expressions (precedence climbing) ----
    def parse_expr(self, min_prec=1):
        lhs = self.parse_unary()
        while True:
            op = self.peek()[1]
            prec = _PREC.get(op)
            if prec is None or prec < min_prec:
                break
            self.next()
            if op == "?":                       # ternary, right-assoc
                then = self.parse_expr(1)
                self.eat(":")
                els = self.parse_expr(1)
                lhs = ("?:", lhs, then, els)
            else:
                rhs = self.parse_expr(prec + 1)
                lhs = ("bin", op, lhs, rhs)
        return lhs

    def parse_unary(self):
        op = self.peek()[1]
        if op in ("~", "!", "-", "|", "&", "^"):     # incl. reduction-OR/AND/XOR
            self.next()
            return ("un", op, self.parse_unary())
        return self.parse_primary()

    def parse_primary(self):
        k, v = self.next()
        if v == "(":
            e = self.parse_expr()
            self.eat(")")
            if self.at("'"):                    # (const-expr)'(x) -- computed-width cast
                self.next()
                self.eat("(")
                inner = self.parse_expr()
                self.eat(")")
                return ("cast", self._const_of(e), inner)
            return e
        if v == "{":                            # concatenation {a, b, ...} (MSB-first)
            if self.at("}"):                    # `{}` -- the empty queue literal
                self.eat("}")
                return ("qempty",)
            parts = [self.parse_expr()]
            while self.at(","):
                self.eat(",")
                parts.append(self.parse_expr())
            self.eat("}")
            return ("concat", parts)
        if k == "sized":
            val, w = _const_value_width(v)
            return ("const", val, w)
        if k == "unsized":                      # '0 / '1 / 'x / 'z  (unsized fill)
            return ("fill", 1 if v[1] in "1" else 0)
        if k == "pattern":                      # '{field: val, ...} assignment pattern
            fields = {}
            while not self.at("}"):
                first = self.parse_expr()
                if self.at(":"):
                    self.eat(":")
                    fname = first[1] if first[0] == "id" else "default"
                    fields[fname] = self.parse_expr()
                if self.at(","):
                    self.eat(",")
            self.eat("}")
            return ("pattern", fields)
        if k == "num":
            return ("const", int(v), None)
        if k == "cast":                              # N'(expr) -- width cast, e.g. 2'(w+1)
            w = int(v[:-1])
            self.eat("(")
            e = self.parse_expr()
            self.eat(")")
            return ("cast", w, e)
        if k == "id" and self.at("::"):              # pkg::NAME -- the package is inlined,
            self.eat("::")                           # so the scoped member is a bare name
            v = self.next()[1]
        if k == "id" and self.at("'"):               # PARAM'(x) -- named-width cast
            self.next()
            self.eat("(")
            inner = self.parse_expr()
            self.eat(")")
            return ("cast", self._const_of(("id", v)), inner)
        if k in ("id", "sysid"):
            # id/system-id followed by `(` is a call -- $past(x), arch_read(a)
            e = self._suffix(("call", v, self._args()) if self.at("(")
                             else ("id", v))
            return e
        raise SyntaxError(f"unexpected token {v!r} in expression")

    def _args(self):
        """Parse a parenthesized, comma-separated argument list."""
        self.eat("(")
        args = []
        if not self.at(")"):
            args.append(self.parse_expr())
            while self.at(","):
                self.eat(",")
                args.append(self.parse_expr())
        self.eat(")")
        return args

    def _suffix(self, base):
        """Attach [i] bit-select, [hi:lo] part-select, .field accesses, and
        .method(...) calls (a queue's .size() / a user function on a struct)."""
        while True:
            if self.at("["):
                self.eat("[")
                hi = self.parse_expr()
                if self.at(":"):
                    self.eat(":")
                    lo = self.parse_expr()
                    self.eat("]")
                    base = ("slice", base, hi, lo)
                else:
                    self.eat("]")
                    base = ("bit2", base, hi)
            elif self.at("."):
                self.eat(".")
                name = self.next()[1]
                if self.at("("):                 # a method call: q.size()
                    base = ("mcall", base, name, self._args())
                else:
                    base = ("field", base, name)
            else:
                return base

    def _parse_lvalue(self):
        """An assignment target: a name, a `.field` chain (a flat "sig.field" name),
        a bit-select name[i], a part-select name[hi:lo], or a concatenation {a, b}."""
        if self.at("{"):                          # concatenation target {msb, ..., lsb}
            self.eat("{")
            parts = [self._parse_lvalue()]
            while self.at(","):
                self.eat(",")
                parts.append(self._parse_lvalue())
            self.eat("}")
            return ("lconcat", parts)
        t = self.next()[1]
        while self.at(".") or self.at("["):
            if self.at("."):
                self.eat(".")
                fld = self.next()[1]
                t = f"{t}.{fld}" if isinstance(t, str) else ("field", t, fld)
            else:
                self.eat("[")
                idx = self.parse_expr()
                if self.at(":"):                  # part-select [hi:lo] -- constant bounds
                    self.eat(":")
                    lo = self._const_of(self.parse_expr())
                    self.eat("]")
                    t = ("partsel", t, self._const_of(idx), lo)
                else:
                    self.eat("]")
                    try:
                        t = ("bit", t, self._const_of(idx))     # constant bit-select
                    except SyntaxError:
                        t = ("index", t, idx)                   # dynamic index (a memory write)
        return t


def _reset_signal(cond):
    """The reset signal named in `if (rst)` or `if (!rst_n)`."""
    if cond[0] == "id":
        return cond[1]
    if cond[0] == "un" and cond[1] == "!" and cond[2][0] == "id":
        return cond[2][1]
    raise SyntaxError(f"unsupported reset condition {cond}")


def _looks_like_reset(name):
    """A synchronous-reset name convention: the identifier reads as a reset
    (`rst`, `rst_n`, `reset`, `arst_n`, ...). Used only to accept a bare outer
    `if (id)` as reset when the signal is not in the async sensitivity list."""
    n = name.lower()
    return "rst" in n or "reset" in n


def _stmts(s):
    """Flatten a statement (block or leaf) to a list, for merging blocks."""
    if not s:
        return []
    return list(s[1]) if s[0] == "block" else [s]


# ---------------------------------------------------------------------------
# Fold a procedural block into functional per-signal expressions.
#   env: {signal name -> current-value expr AST}.  if/case merge branches with
#   ternaries; blocking read-after-write substitutes the running value.
# ---------------------------------------------------------------------------
def _subst(ast, env):
    tag = ast[0]
    if tag == "id":
        return env.get(ast[1], ast)
    if tag in ("const", "bit", "fill"):
        return ast
    if tag == "un":
        return ("un", ast[1], _subst(ast[2], env))
    if tag == "bin":
        return ("bin", ast[1], _subst(ast[2], env), _subst(ast[3], env))
    if tag == "?:":
        return ("?:", _subst(ast[1], env), _subst(ast[2], env), _subst(ast[3], env))
    if tag in ("bit2", "field"):                # base is an expr, index/field is data
        return (tag, _subst(ast[1], env)) + ast[2:]
    if tag == "slice":
        return ("slice", _subst(ast[1], env), ast[2], ast[3])
    if tag == "concat":
        return ("concat", [_subst(p, env) for p in ast[1]])
    if tag == "call":
        return ("call", ast[1], [_subst(a, env) for a in ast[2]])
    if tag == "setbit":                         # ("setbit", base, k, v)
        return ("setbit", _subst(ast[1], env), ast[2], _subst(ast[3], env))
    if tag == "astore":                         # ("astore", base_mem, idx, v)
        return ("astore", _subst(ast[1], env), _subst(ast[2], env), _subst(ast[3], env))
    return ast


def _merge(cond, then_env, else_env, base):
    # Union the two branches' assigned signals in a DETERMINISTIC order (then-branch
    # order, then the else-branch's new keys). A `set()` union here would iterate in
    # hash order, which Python randomizes per process -- that leaks into the state-bit
    # order and makes the committed proof traces churn run-to-run.
    out = dict(base)
    seen, keys = set(), []
    for src in (then_env, else_env):
        for k in src:
            if k not in seen:
                seen.add(k)
                keys.append(k)
    for k in keys:
        tv = then_env.get(k, base.get(k, ("id", k)))
        ev = else_env.get(k, base.get(k, ("id", k)))
        out[k] = tv if tv == ev else ("?:", cond, tv, ev)
    return out


def _eq_any(sel, labels, base):
    conds = [("bin", "==", sel, _subst(l, base)) for l in labels]
    c = conds[0]
    for x in conds[1:]:
        c = ("bin", "||", c, x)
    return c


# ---------------------------------------------------------------------------
# Compile-time expansion of finite/static arrays: the Chapter 2 cache has no dynamic
# structures -- its sizes are all compile-time known -- so we unroll every for-loop,
# flatten each unpacked array to one scalar signal per element (per struct field), and
# rewrite each access to a scalar (a constant index) or a mux over the finite index
# range (a dynamic index). After this the module has no arrays and no loops, and the
# ordinary elaborator + IC3 prove it.
# ---------------------------------------------------------------------------
import itertools as _it


def _cfold(ast, env, consts):
    """Fold a constant expression using loop-var bindings `env` and module `consts`."""
    t = ast[0]
    if t == "const":
        return ast[1]
    if t == "id":
        if ast[1] in env:
            return env[ast[1]]
        if ast[1] in consts:
            return consts[ast[1]][0]
        raise ValueError(ast)
    if t == "cast":
        return _cfold(ast[2], env, consts) & ((1 << ast[1]) - 1)
    if t == "un" and ast[1] == "-":
        return -_cfold(ast[2], env, consts)
    if t == "bin":
        a, b = _cfold(ast[2], env, consts), _cfold(ast[3], env, consts)
        return {"+": a + b, "-": a - b, "*": a * b, "<<": a << b, ">>": a >> b,
                "/": a // b}[ast[1]]
    raise ValueError(ast)


def _try_const(ast, env, consts):
    try:
        return _cfold(ast, env, consts)
    except (ValueError, KeyError, ZeroDivisionError):
        return None


def _arr_ref(ast):
    """If `ast` reads an array element -- name[i]...[j] or name[i]...[j].field -- return
    (name, [index_asts], field_or_None); else None. `name` is the root string id."""
    if ast[0] == "field":
        inner = _arr_ref(ast[1])
        return (inner[0], inner[1], ast[2]) if inner else None
    idxs, node = [], ast
    while node[0] in ("bit2", "bit", "index"):
        idxs.append(node[2] if node[0] != "bit" else ("const", node[2], None))
        node = node[1]
    root = node[1] if node[0] == "id" else (node if isinstance(node, str) else None)
    return (root, list(reversed(idxs)), None) if idxs and isinstance(root, str) else None


def _lref(lhs):
    """The lvalue form of _arr_ref: peel .field and [idx]/index chains to the root name."""
    if isinstance(lhs, tuple) and lhs[0] == "field":
        inner = _lref(lhs[1])
        return (inner[0], inner[1], lhs[2]) if inner else None
    idxs, node = [], lhs
    while isinstance(node, tuple) and node[0] in ("index", "bit"):
        idxs.append(node[2] if node[0] != "bit" else ("const", node[2], None))
        node = node[1]
    return (node, list(reversed(idxs)), None) if idxs and isinstance(node, str) else None


def _elem(name, combo, field):
    return name + "".join(f".{c}" for c in combo) + (f".{field}" if field else "")


def _mux_read(name, idxs, field, env, consts, ad):
    """A read name[idxs].field -> a scalar (all-const indices) or a mux over the range."""
    dims = ad[name]
    resolved = [_try_const(i, env, consts) for i in idxs]
    folded = [_ax_expr(i, env, consts, ad) for i in idxs]
    combos = list(_it.product(*[range(d) for d in dims]))
    result = None
    for combo in reversed(combos):                       # last surviving combo is the default
        guards, skip = [], False
        for r, c, fo in zip(resolved, combo, folded):
            if r is not None:
                if r != c:
                    skip = True
                    break
            else:
                guards.append(("bin", "==", fo, ("const", c, None)))
        if skip:
            continue
        val = ("id", _elem(name, combo, field))
        if not guards:
            return val                                   # exact constant index
        g = guards[0]
        for x in guards[1:]:
            g = ("bin", "&&", g, x)
        result = val if result is None else ("?:", g, val, result)
    return result if result is not None else ("const", 0, None)


def _ax_expr(ast, env, consts, ad):
    ref = _arr_ref(ast)
    if ref and ref[0] in ad:
        return _mux_read(ref[0], ref[1], ref[2], env, consts, ad)
    t = ast[0]
    if t == "id":
        return ("const", env[ast[1]], None) if ast[1] in env else ast
    if t in ("const", "fill"):
        return ast
    if t == "un":
        return ("un", ast[1], _ax_expr(ast[2], env, consts, ad))
    if t == "bin":
        return ("bin", ast[1], _ax_expr(ast[2], env, consts, ad), _ax_expr(ast[3], env, consts, ad))
    if t == "?:":
        return ("?:", _ax_expr(ast[1], env, consts, ad), _ax_expr(ast[2], env, consts, ad),
                _ax_expr(ast[3], env, consts, ad))
    if t == "cast":
        return ("cast", ast[1], _ax_expr(ast[2], env, consts, ad))
    if t in ("bit2", "slice"):                           # a vector bit/part-select (non-array)
        return (t, _ax_expr(ast[1], env, consts, ad)) + tuple(
            _ax_expr(a, env, consts, ad) for a in ast[2:])
    if t == "field":
        return ("field", _ax_expr(ast[1], env, consts, ad), ast[2])
    if t == "concat":
        return ("concat", [_ax_expr(p, env, consts, ad) for p in ast[1]])
    if t == "call":
        return ("call", ast[1], [_ax_expr(a, env, consts, ad) for a in ast[2]])
    return ast


def _rw_lhs(lhs, env, consts, ad):
    """Rewrite a NON-array lvalue: substitute loop vars in an index and fold it, so a
    vector bit-write `vec[w] <= ..` under an unrolled loop becomes a constant bit-select
    `("bit", vec, k)` (not a spurious memory store)."""
    if isinstance(lhs, tuple) and lhs[0] == "index":
        base, idx = lhs[1], lhs[2]
        base = base if isinstance(base, str) else _rw_lhs(base, env, consts, ad)
        cv = _try_const(idx, env, consts)
        return ("bit", base, cv) if cv is not None else ("index", base, _ax_expr(idx, env, consts, ad))
    if isinstance(lhs, tuple) and lhs[0] == "field":
        return ("field", _rw_lhs(lhs[1], env, consts, ad), lhs[2])
    return lhs


def _ax_assign(lhs, rhs, env, consts, ad, rest=()):
    ref = _lref(lhs)
    rhs2 = _ax_expr(rhs, env, consts, ad)
    if not (ref and ref[0] in ad):
        return ("assign", _rw_lhs(lhs, env, consts, ad), rhs2) + tuple(rest)
    name, idxs, field = ref
    dims = ad[name]
    resolved = [_try_const(i, env, consts) for i in idxs]
    folded = [_ax_expr(i, env, consts, ad) for i in idxs]
    outs = []
    for combo in _it.product(*[range(d) for d in dims]):
        guards, skip = [], False
        for r, c, fo in zip(resolved, combo, folded):
            if r is not None:
                if r != c:
                    skip = True
                    break
            else:
                guards.append(("bin", "==", fo, ("const", c, None)))
        if skip:
            continue
        a = ("assign", _elem(name, combo, field), rhs2) + tuple(rest)
        if guards:
            g = guards[0]
            for x in guards[1:]:
                g = ("bin", "&&", g, x)
            a = ("if", g, a, None)
        outs.append(a)
    return ("block", outs)


def _ax_stmt(stmt, env, consts, ad):
    if stmt is None:
        return None
    t = stmt[0]
    if t == "for":
        _, var, lo, hi, body = stmt
        lo, hi = _cfold(lo, env, consts), _cfold(hi, env, consts)
        out = []
        for v in range(lo, hi):
            e2 = dict(env); e2[var] = v
            out.append(_ax_stmt(body, e2, consts, ad))
        return ("block", out)
    if t == "block":
        return ("block", [_ax_stmt(s, env, consts, ad) for s in stmt[1]])
    if t == "if":
        return ("if", _ax_expr(stmt[1], env, consts, ad), _ax_stmt(stmt[2], env, consts, ad),
                _ax_stmt(stmt[3], env, consts, ad) if stmt[3] else None)
    if t == "case":
        return ("case", _ax_expr(stmt[1], env, consts, ad),
                [(labs, _ax_stmt(s, env, consts, ad)) for labs, s in stmt[2]],
                _ax_stmt(stmt[3], env, consts, ad) if stmt[3] else None)
    if t == "assign":
        return _ax_assign(stmt[1], stmt[2], env, consts, ad, stmt[3:])
    if t == "passert":
        return ("passert", _ax_expr(stmt[1], env, consts, ad))
    return stmt


def _support(sig, acc):
    """Collect the VAR leaf names a Sig DAG depends on."""
    stack, seen = [sig], set()
    while stack:
        s = stack.pop()
        if id(s) in seen:
            continue
        seen.add(id(s))
        if s.kind == "var":
            acc.add(s.name)
        else:
            stack.extend(s.args)


def _coi_reduce(ts):
    """Cone-of-influence: drop state bits the property (bad / liveness / assumptions) does
    not transitively depend on. Sound for reachability -- a bit outside the cone cannot
    change whether `bad` is reachable -- and it keeps IC3 off a datapath the contract never
    reads (e.g. the MSI cache's 32-bit data words vs its single-residence tag/state law)."""
    state = set(ts.state)
    seed = set()
    if ts.bad is not None:
        _support(ts.bad, seed)
    for a, b in ts.liveness:
        _support(a, seed); _support(b, seed)
    for a in ts.assumptions:
        _support(a, seed)
    for x in getattr(ts, "covers", []):
        _support(x, seed)
    keep, work = set(), [s for s in seed if s in state]
    keep.update(work)
    while work:
        sup = set()
        _support(ts.next[work.pop()], sup)
        for n in sup:
            if n in state and n not in keep:
                keep.add(n); work.append(n)
    if len(keep) != len(state):
        ts.state = [s for s in ts.state if s in keep]
        ts.next = {s: ts.next[s] for s in ts.state}
        ts.init = {s: ts.init[s] for s in ts.state}
    # also drop inputs no surviving next-function / property reads (e.g. a 32-bit wdata
    # that fed only the pruned data words) -- fewer free variables, faster search.
    used = set(seed)
    for s in ts.state:
        _support(ts.next[s], used)
    if any(i not in used for i in ts.inputs):
        ts.inputs = [i for i in ts.inputs if i in used]
    return ts


def _expand_arrays(mod):
    """Rewrite `mod` in place: unroll loops, flatten arrays to scalars, expand accesses."""
    if not mod.arrays:
        return mod
    ad = {n: dims for n, (dims, _, _) in mod.arrays.items()}
    for name, (dims, ew, estype) in mod.arrays.items():
        d = mod.signals.get(name, {}).get("dir")
        for combo in _it.product(*[range(x) for x in dims]):
            base = _elem(name, combo, None)
            if estype and estype in mod.structs:
                for f, fw in mod.structs[estype]:
                    mod.signals[f"{base}.{f}"] = {"dir": d, "width": fw}
            else:
                mod.signals[base] = {"dir": d, "width": ew}
    c = mod.consts
    mod.assigns = [(_lref_lhs(l, c, ad), _ax_expr(e, {}, c, ad)) for l, e in mod.assigns]
    mod.comb_stmts = [_ax_stmt(s, {}, c, ad) for s in mod.comb_stmts]
    mod.next_stmt = _ax_stmt(mod.next_stmt, {}, c, ad)
    mod.reset_stmt = _ax_stmt(mod.reset_stmt, {}, c, ad)
    if mod.prop is not None:
        mod.prop = _ax_expr(mod.prop, {}, c, ad)
    mod.assumptions = [_ax_expr(a, {}, c, ad) for a in mod.assumptions]
    mod.liveness = [(_ax_expr(a, {}, c, ad), _ax_expr(b, {}, c, ad)) for a, b in mod.liveness]
    mod.covers = [_ax_expr(x, {}, c, ad) for x in mod.covers]
    mod.arrays = {}
    return mod


def _lref_lhs(lhs, consts, ad):
    """Rewrite a continuous-assign lvalue (`assign lru...` never indexes an array here, but
    keep it total): array-indexed continuous assigns are not used, so pass scalars through."""
    return lhs


def _andg(g, c):
    return c if g is None else ("bin", "&&", g, c)


def _fold(stmt, env, pa=None, guard=None):
    """Fold a procedural block to per-signal final-value expressions.

    Two maps ride through the walk. `cur` holds the values a later read IN THE
    SAME BLOCK sees: only a BLOCKING assign (`=`) updates it, so reading a
    register written earlier with `<=` yields its pre-edge value -- exactly
    IEEE-1800 semantics. `nxt` holds every assigned signal's final value (what
    the register latches / the comb signal drives) and is what is returned.
    Book RTL (pure `<=`, no read-after-write) never sees the difference; the
    synthesized $past/window monitor chains and a checker's blocking queue
    bookkeeping each depend on their side of it.

    `pa`, when given, collects procedural immediate assertions as implications
    guarded by their if/case path condition: `if (v) assert (x != y);`
    contributes `!v || x != y` -- a safety property like any other."""
    cur, nxt = _fold2(stmt, dict(env), dict(env), pa, guard)
    return nxt


def _fold2(stmt, cur, nxt, pa, guard):
    if stmt is None:
        return cur, nxt
    tag = stmt[0]
    if tag == "passert":
        if pa is not None:
            cond = _subst(stmt[1], cur)
            pa.append(cond if guard is None
                      else ("bin", "||", ("un", "!", guard), cond))
        return cur, nxt
    if tag == "assign":
        lhs, e = stmt[1], stmt[2]
        nb = len(stmt) < 4 or stmt[3]            # nonblocking unless tagged `=`
        if isinstance(lhs, tuple) and lhs[0] == "index":     # mem[idx] <= e  (memory write)
            _, base, idx = lhs
            name = base[1] if base[0] == "id" else base       # base is ("id", memname)
            prev = nxt.get(name, ("id", name))
            val = ("astore", prev, _subst(idx, cur), _subst(e, cur))
        elif isinstance(lhs, tuple) and lhs[0] == "bit":      # vec[k] <= e  (procedural bit-write)
            name = lhs[1]                                      # keep `vec` a whole-signal key so
            prev = nxt.get(name, ("id", name))                # _merge sees a string, not a tuple
            val = ("setbit", prev, lhs[2], _subst(e, cur))
        else:
            name, val = lhs, _subst(e, cur)
        nxt[name] = val
        if not nb:
            cur[name] = val
        return cur, nxt
    if tag == "block":
        for s in stmt[1]:
            cur, nxt = _fold2(s, cur, nxt, pa, guard)
        return cur, nxt
    if tag == "if":
        _, cond, then_s, els_s = stmt
        c = _subst(cond, cur)
        tc, tn = _fold2(then_s, dict(cur), dict(nxt), pa, _andg(guard, c))
        if els_s:
            ec, en = _fold2(els_s, dict(cur), dict(nxt), pa,
                            _andg(guard, ("un", "!", c)))
        else:
            ec, en = cur, nxt
        return _merge(c, tc, ec, cur), _merge(c, tn, en, nxt)
    if tag == "case":
        _, sel, items, default = stmt
        s = _subst(sel, cur)
        gs = [_eq_any(s, labels, cur) for labels, _ in items]
        if default:
            gd = guard
            for g in gs:
                gd = _andg(gd, ("un", "!", g))
            rc, rn = _fold2(default, dict(cur), dict(nxt), pa, gd)
        else:
            rc, rn = cur, nxt
        for (labels, st), g in zip(reversed(items), reversed(gs)):
            tc, tn = _fold2(st, dict(cur), dict(nxt), pa, _andg(guard, g))
            rc, rn = _merge(g, tc, rc, cur), _merge(g, tn, rn, nxt)
        return rc, rn
    raise ValueError(stmt)


# ---------------------------------------------------------------------------
# Elaboration: AST -> TransitionSystem
# ---------------------------------------------------------------------------
def _reduce_or(bv: BV) -> Sig:
    return OR(*bv.bits) if bv.bits else FALSE


def _fit(bv: BV, w: int) -> BV:
    bits = bv.bits[:w] + [FALSE] * (w - bv.width)
    return BV(bits)


class _Elaborator:
    def __init__(self, mod: Module):
        self.mod = mod
        self.consts = mod.consts
        self.width = {n: s["width"] for n, s in mod.signals.items()}
        # comb wires: continuous assigns (whole-signal, and per-bit/part drivers) plus
        # folded always_comb blocks. Underhood a vector is its bits, so a signal is
        # assembled per-bit from whichever driver covers each bit.
        self.assign = {}                         # whole-signal (string) -> expr
        self.bitdrv = {}                         # name -> [(lo, hi, expr)] partial drivers
        for lhs, e in mod.assigns:
            self._add_driver(lhs, e)
        # procedural blocks: normalize concat / whole-struct LHS, then fold to per-signal;
        # procedural immediate asserts fall out as path-guarded safety conditions.
        self.passerts = []
        for stmt in mod.comb_stmts:
            for sig, e in _fold(self._expand(stmt), {}, pa=self.passerts).items():
                self._add_driver(sig, e)
        # pa=self.passerts on the sequential folds too, so an immediate
        # assert(...) inside a clocked or reset block is collected as a
        # path-guarded safety condition rather than silently dropped.
        self.next_ast = _fold(self._expand(mod.next_stmt), {}, pa=self.passerts) if mod.next_stmt else {}
        self.reset_env = _fold(self._expand(mod.reset_stmt), {}, pa=self.passerts) if mod.reset_stmt else {}
        self.regs = list(self.next_ast.keys())
        self.memo = {}                                       # comb-wire name -> BV (shared!)

    def _add_driver(self, lhs, e):
        if isinstance(lhs, str):
            self.assign[lhs] = e
        elif lhs[0] == "bit":
            self.bitdrv.setdefault(lhs[1], []).append((lhs[2], lhs[2], e))
        elif lhs[0] == "partsel":
            self.bitdrv.setdefault(lhs[1], []).append((lhs[3], lhs[2], e))       # (lo, hi)
        else:
            raise SyntaxError(f"unsupported assignment target {lhs}")

    def _lwidth(self, lv):
        if isinstance(lv, str):
            return self.width.get(lv, 1)
        if lv[0] == "bit":
            return 1
        if lv[0] == "partsel":
            return lv[2] - lv[3] + 1
        if lv[0] == "lconcat":
            return sum(self._lwidth(p) for p in lv[1])
        raise SyntaxError(f"width of lvalue {lv}")

    def _expand(self, stmt):
        """Rewrite concat / whole-struct LHS assigns into per-target assigns."""
        if stmt is None:
            return None
        tag = stmt[0]
        if tag == "assign":
            return self._expand_assign(stmt[1], stmt[2], stmt[3:])
        if tag == "block":
            return ("block", [self._expand(s) for s in stmt[1]])
        if tag == "if":
            return ("if", stmt[1], self._expand(stmt[2]),
                    self._expand(stmt[3]) if stmt[3] else None)
        if tag == "case":
            return ("case", stmt[1],
                    [(labs, self._expand(s)) for labs, s in stmt[2]],
                    self._expand(stmt[3]) if stmt[3] else None)
        return stmt

    def _expand_assign(self, lhs, e, rest=()):
        if isinstance(lhs, tuple) and lhs[0] == "lconcat":       # {a, b, ...} <= e
            outs, off = [], self._lwidth(lhs)
            for p in lhs[1]:                                     # MSB-first
                w = self._lwidth(p)
                off -= w
                slc = (("bit2", e, ("const", off, None)) if w == 1
                       else ("slice", e, ("const", off + w - 1, None), ("const", off, None)))
                outs.append(self._expand_assign(p, slc, rest))
            return ("block", outs)
        if isinstance(lhs, str) and self._is_struct(lhs):        # whole-struct <= e
            stype = self.mod.signals[lhs]["stype"]
            outs = [self._expand_assign(f"{lhs}.{f}", self._proj(e, f), rest)
                    for f, _ in self.mod.structs[stype]]
            return ("block", outs)
        return ("assign", lhs, e) + tuple(rest)

    def leaf(self, name) -> BV:
        """Current-state value of a signal as VAR leaves."""
        w = self.width[name]
        if w == 1:
            return BV([VAR(name)])
        return BV([VAR(f"{name}[{i}]") for i in range(w)])

    def value(self, name) -> BV:
        """Resolve a name to a BV: enum/localparam names are constants;
        registers/inputs are leaves; assigns are their (memoized, shared) RHS."""
        if name in self.consts:
            v, w = self.consts[name]
            return bv_const(v, w)
        if name in self.bitdrv and name not in self.regs:
            if name not in self.memo:
                w = self.width.get(name, 1)
                bits = (_fit(self.eval(self.assign[name]), w).bits if name in self.assign
                        else list(self.leaf(name).bits))          # undriven bits stay leaves
                for lo, hi, e in self.bitdrv[name]:
                    ev = _fit(self.eval(e), hi - lo + 1).bits
                    for i in range(lo, hi + 1):
                        bits[i] = ev[i - lo]
                self.memo[name] = BV(bits)
            return self.memo[name]
        if name in self.assign and name not in self.regs:
            if name not in self.memo:
                self.memo[name] = _fit(self.eval(self.assign[name]), self.width.get(name, 1))
            return self.memo[name]
        return self.leaf(name)

    def eval(self, ast) -> BV:
        tag = ast[0]
        if tag == "const":
            # Unsized literal: width must at least hold the value, or it is
            # silently truncated (an unsized 20 masked to 4 bits reads 4).
            # Values < 16 keep width 4 (unchanged); larger ones grow to fit.
            val, w = ast[1], ast[2] if ast[2] else max(4, ast[1].bit_length())
            return bv_const(val, w)
        if tag == "id":
            return self.value(ast[1])
        if tag == "fill":                           # '0 / '1 (fit expands to the target width)
            return BV([TRUE if ast[1] else FALSE])
        if tag == "bit":                            # legacy ("bit", name, const_idx)
            return BV([self.value(ast[1]).bits[ast[2]]])
        if tag == "bit2":                           # ("bit2", base_expr, idx_expr)
            base = self.eval(ast[1])
            return BV([base.bits[self._cint(ast[2])]])
        if tag == "slice":                          # ("slice", base, hi, lo)
            base = self.eval(ast[1])
            hi, lo = self._cint(ast[2]), self._cint(ast[3])
            return BV(base.bits[lo:hi + 1])
        if tag == "concat":                         # ("concat", [MSB, ..., LSB])
            bits = []
            for p in reversed(ast[1]):
                bits += self.eval(p).bits
            return BV(bits)
        if tag == "field":                          # ("field", base_expr, field_name)
            return self._eval_field(ast[1], ast[2])
        if tag == "call":                           # system/user function call
            return self._eval_call(ast[1], ast[2])
        if tag == "un":
            _, op, a = ast
            x = self.eval(a)
            if op == "~":
                return BV([NOT(b) for b in x.bits])
            if op == "!":
                return BV([NOT(_reduce_or(x))])
            if op == "-":
                return bv_sub(bv_const(0, x.width), x, x.width)
            if op == "|":                              # reduction OR / AND / XOR
                return BV([_reduce_or(x)])
            if op == "&":
                return BV([AND(*x.bits)])
            if op == "^":
                return BV([XOR(*x.bits)])
        if tag == "cast":                           # N'(expr): fit expr to N bits
            return _fit(self.eval(ast[2]), ast[1])
        if tag == "setbit":                         # ("setbit", base, k, v): base with bit k := v
            base = self.eval(ast[1])
            bits = list(base.bits)
            bits[ast[2]] = _reduce_or(self.eval(ast[3]))
            return BV(bits)
        if tag == "?:":
            _, c, t, e = ast
            cond = _reduce_or(self.eval(c))
            tb, eb = self.eval(t), self.eval(e)
            w = max(tb.width, eb.width)
            return bv_ite(cond, _fit(tb, w), _fit(eb, w))
        if tag == "bin":
            return self.eval_bin(ast[1], self.eval(ast[2]), self.eval(ast[3]))
        raise ValueError(ast)

    def eval_bin(self, op, a: BV, b: BV) -> BV:
        w = max(a.width, b.width)
        if op in ("&", "&&"):
            if op == "&&" or w == 1:
                return BV([AND(_reduce_or(a), _reduce_or(b))])
            a, b = _fit(a, w), _fit(b, w)
            return BV([AND(x, y) for x, y in zip(a.bits, b.bits)])
        if op in ("|", "||"):
            if op == "||" or w == 1:
                return BV([OR(_reduce_or(a), _reduce_or(b))])
            a, b = _fit(a, w), _fit(b, w)
            return BV([OR(x, y) for x, y in zip(a.bits, b.bits)])
        if op == "^":
            a, b = _fit(a, w), _fit(b, w)
            return BV([XOR(x, y) for x, y in zip(a.bits, b.bits)])
        if op == "==":
            return BV([bv_eq(_fit(a, w), _fit(b, w))])
        if op == "!=":
            return BV([NOT(bv_eq(_fit(a, w), _fit(b, w)))])
        if op == "+":
            return bv_add(a, b, w)
        if op == "-":
            return bv_sub(a, b, w)
        if op in ("<", "<=", ">", ">="):
            return BV([self._cmp(op, a, b)])
        # `*`, `<<`, `>>` on non-constant operands are not lowered (constant
        # folds are handled earlier by _cint). Fail with a clear message
        # rather than a bare ValueError traceback.
        raise SyntaxError(
            f"operator {op!r} is only supported on constant operands "
            f"(non-constant multiply/shift is not lowered)")

    def _cmp(self, op, a: BV, b: BV) -> Sig:
        """Unsigned compare. The DUTs compare against constants, which is all the
        engines need; ge/le reduce to the circuit's bv_ge_const."""
        kb = _const_int(b)
        ka = _const_int(a)
        if kb is not None:
            if op == ">=":
                return bv_ge_const(a, kb)
            if op == "<":
                return NOT(bv_ge_const(a, kb))
            if op == "<=":
                return NOT(bv_ge_const(a, kb + 1))
            if op == ">":
                return bv_ge_const(a, kb + 1)
        if ka is not None:                      # constant on the left: flip
            return self._cmp({"<": ">", ">": "<", "<=": ">=", ">=": "<="}[op], b,
                             bv_const(ka, b.width))
        raise SyntaxError("only comparisons against a constant are supported")

    def _const_of_ast(self, ast) -> int:
        if ast[0] in ("const", "fill"):
            return ast[1] if ast[0] == "const" else 0
        if ast[0] == "id" and ast[1] in self.consts:
            return self.consts[ast[1]][0]
        try:
            return self._cint(ast)
        except SyntaxError:
            raise SyntaxError(f"reset value must be a constant, got {ast}")

    def _cint(self, ast) -> int:
        """Fold a constant integer expression: literals, params, $clog2, +-*."""
        tag = ast[0]
        if tag == "const":
            return ast[1]
        if tag == "fill":
            return ast[1]
        if tag == "id" and ast[1] in self.consts:
            return self.consts[ast[1]][0]
        if tag == "bin":
            a, b = self._cint(ast[2]), self._cint(ast[3])
            return {"+": a + b, "-": a - b, "*": a * b, "/": a // b}[ast[1]]
        if tag == "un" and ast[1] == "-":
            return -self._cint(ast[2])
        if tag == "call" and ast[1] in ("$clog2", "clog2"):
            n = self._cint(ast[2][0])
            return 0 if n <= 1 else (n - 1).bit_length()
        if tag == "cast":                                    # W'(const)
            return self._cint(ast[2]) & ((1 << ast[1]) - 1)
        if tag == "bit2":                                    # (const)[i]
            return (self._cint(ast[1]) >> self._cint(ast[2])) & 1
        if tag == "slice":                                   # (const)[hi:lo]
            base, hi, lo = self._cint(ast[1]), self._cint(ast[2]), self._cint(ast[3])
            return (base >> lo) & ((1 << (hi - lo + 1)) - 1)
        raise SyntaxError(f"non-constant expression where an integer was needed: {ast}")

    def _eval_field(self, base_ast, field):
        """A struct field read: with fields flattened, sig.field is its own signal."""
        if base_ast[0] == "id":
            return self.value(f"{base_ast[1]}.{field}")
        raise SyntaxError(f"unsupported field access {base_ast}.{field}")

    def _is_struct(self, name):
        return bool(self.mod.signals.get(name, {}).get("stype"))

    def _proj(self, e, field):
        """Project a struct-valued RHS to one field: a copy (rhs.field), a fill, or a
        member of an assignment pattern."""
        if e[0] == "fill":
            return e
        if e[0] == "pattern":
            return e[1].get(field, e[1].get("default", ("fill", 0)))
        return ("field", e, field)             # struct-to-struct: rhs.field

    def _eval_call(self, name, args):
        if name in ("$onehot0", "$onehot"):
            x = self.eval(args[0]).bits
            pairs = [AND(x[i], x[j]) for i in range(len(x)) for j in range(i + 1, len(x))]
            atmost1 = NOT(OR(*pairs)) if pairs else TRUE          # at most one bit set
            if name == "$onehot":
                return BV([AND(atmost1, OR(*x))])                 # exactly one bit set
            return BV([atmost1])
        raise SyntaxError(f"function {name} not yet supported in an expression")

    def build(self) -> TransitionSystem:
        ts = TransitionSystem(self.mod.name)
        regset = set(self.regs)
        for n, s in self.mod.signals.items():
            if n in regset:                      # a written register is state, never an
                continue                         # input, whatever a port direction says
            if s["dir"] == "input" and n not in (self.mod.clock, self.mod.reset):
                w = s["width"]
                if w == 1:
                    ts.add_input(n)
                else:
                    for i in range(w):
                        ts.add_input(f"{n}[{i}]")
        reset_env = self.reset_env
        for r in self.regs:
            w = self.width[r]
            nxt = _fit(self.eval(self.next_ast[r]), w)
            # LIMITATION: an unreset register (no assignment in the reset
            # block) is initialized to 0 here, whereas a fully sound tool
            # would leave its power-up value FREE -- this TransitionSystem
            # carries concrete inits only. The default under-approximates the
            # initial state, so a property that depends on an unreset
            # register's power-up value could be proven unsoundly. This never
            # bites the designs here: every such register (e.g. the FIFO's
            # memory) is cone-of-influence-removed before the proof, and a
            # well-formed property must not rely on undefined power-up state.
            initv = self._const_of_ast(reset_env[r]) if r in reset_env else 0
            if w == 1:
                ts.add_state_bit(r, initv & 1, nxt.bits[0])
            else:
                ts.add_state_bv(r, self.leaf(r), initv, nxt)
        # safety property (if any): bad = its negation, conjoined with every
        # path-guarded procedural assert. A liveness-only module has no safety
        # violation, so bad = FALSE (the safety engines see nothing to break).
        parts = []
        if self.mod.prop is not None:
            parts.append(_reduce_or(self.eval(self.mod.prop)))
        for pa in self.passerts:
            parts.append(_reduce_or(self.eval(pa)))
        ts.bad = NOT(AND(*parts)) if parts else FALSE
        ts.liveness = [(_reduce_or(self.eval(a)), _reduce_or(self.eval(b)))
                       for a, b in self.mod.liveness]
        ts.assumptions = [_reduce_or(self.eval(a)) for a in self.mod.assumptions]
        ts.covers = [_reduce_or(self.eval(x)) for x in self.mod.covers]
        # an undriven internal wire (a formal free variable -- Wolper's symbolic
        # token) is a primary input the solver chooses: any leaf the model reads
        # that is neither state nor input nor driven becomes an input.
        used = set()
        _support(ts.bad, used)
        for a, b in ts.liveness:
            _support(a, used)
            _support(b, used)
        for a in ts.assumptions:
            _support(a, used)
        for x in ts.covers:
            _support(x, used)
        for s in ts.state:
            _support(ts.next[s], used)
        known = set(ts.state) | set(ts.inputs)
        for n in sorted(used - known):
            ts.add_input(n)
        return ts


def _const_int(bv: BV):
    """If every bit of bv is a literal constant, return its integer value."""
    val = 0
    for i, b in enumerate(bv.bits):
        if getattr(b, "kind", None) != "const":
            return None
        if b.val:
            val |= (1 << i)
    return val


def parse(src: str) -> Module:
    # we ARE the formal tool: `ifdef FORMAL takes the formal branch here
    return Parser(tokenize(preprocess(src, defines=("FORMAL",)))).parse_module()


def _rw_expr(ast, fn):
    """Bottom-up expression rewrite: rebuild with children rewritten, then apply
    `fn` (which returns a replacement, or the node unchanged)."""
    if not isinstance(ast, tuple):
        return ast
    t = ast[0]
    if t == "un":
        out = ("un", ast[1], _rw_expr(ast[2], fn))
    elif t == "bin":
        out = ("bin", ast[1], _rw_expr(ast[2], fn), _rw_expr(ast[3], fn))
    elif t == "?:":
        out = ("?:", _rw_expr(ast[1], fn), _rw_expr(ast[2], fn), _rw_expr(ast[3], fn))
    elif t == "cast":
        out = ("cast", ast[1], _rw_expr(ast[2], fn))
    elif t in ("bit2", "slice"):
        out = (t, _rw_expr(ast[1], fn)) + tuple(_rw_expr(a, fn) for a in ast[2:])
    elif t == "field":
        out = ("field", _rw_expr(ast[1], fn), ast[2])
    elif t == "concat":
        out = ("concat", [_rw_expr(p, fn) for p in ast[1]])
    elif t == "pattern":
        out = ("pattern", {k: _rw_expr(v, fn) for k, v in ast[1].items()})
    elif t == "call":
        out = ("call", ast[1], [_rw_expr(a, fn) for a in ast[2]])
    elif t == "mcall":
        out = ("mcall", _rw_expr(ast[1], fn), ast[2], [_rw_expr(a, fn) for a in ast[3]])
    elif t == "sticky":
        out = ("sticky", ast[1], _rw_expr(ast[2], fn), _rw_expr(ast[3], fn))
    elif t in ("setbit", "astore"):
        out = (t,) + tuple(_rw_expr(a, fn) if isinstance(a, tuple) else a for a in ast[1:])
    else:                                   # id / const / fill / bit / qempty / ...
        out = ast
    return fn(out)


def _rw_stmt(stmt, fn):
    """Apply an expression rewrite to every expression a statement contains."""
    if stmt is None:
        return None
    t = stmt[0]
    if t == "assign":
        lhs = stmt[1]
        if isinstance(lhs, tuple) and lhs[0] == "index":
            lhs = ("index", lhs[1], _rw_expr(lhs[2], fn))
        return ("assign", lhs, _rw_expr(stmt[2], fn)) + tuple(stmt[3:])
    if t == "block":
        return ("block", [_rw_stmt(s, fn) for s in stmt[1]])
    if t == "if":
        return ("if", _rw_expr(stmt[1], fn), _rw_stmt(stmt[2], fn),
                _rw_stmt(stmt[3], fn) if stmt[3] else None)
    if t == "case":
        return ("case", _rw_expr(stmt[1], fn),
                [(labs, _rw_stmt(s, fn)) for labs, s in stmt[2]],
                _rw_stmt(stmt[3], fn) if stmt[3] else None)
    if t == "for":
        return ("for", stmt[1], stmt[2], stmt[3], _rw_stmt(stmt[4], fn))
    if t == "passert":
        return ("passert", _rw_expr(stmt[1], fn))
    if t == "qcall":
        return ("qcall", stmt[1], stmt[2], [_rw_expr(a, fn) for a in stmt[3]])
    if t == "return":
        return ("return", _rw_expr(stmt[1], fn))
    return stmt


def _rw_module(mod: Module, fn):
    """Apply an expression rewrite everywhere a module holds expressions. The
    sequential statements go FIRST so a rewriter that synthesizes aux registers
    (appending to next/reset) sees its additions survive."""
    mod.next_stmt = _rw_stmt(mod.next_stmt, fn)
    mod.reset_stmt = _rw_stmt(mod.reset_stmt, fn)
    mod.assigns = [(l, _rw_expr(e, fn)) for l, e in mod.assigns]
    mod.comb_stmts = [_rw_stmt(s, fn) for s in mod.comb_stmts]
    if mod.prop is not None:
        mod.prop = _rw_expr(mod.prop, fn)
    mod.assumptions = [_rw_expr(a, fn) for a in mod.assumptions]
    mod.liveness = [(_rw_expr(a, fn), _rw_expr(b, fn)) for a, b in mod.liveness]
    mod.next_props = [(_rw_expr(a, fn), _rw_expr(c, fn), s) for a, c, s in mod.next_props]
    mod.windows = [(lo, hi, _rw_expr(a, fn), _rw_expr(c, fn), s)
                   for lo, hi, a, c, s in mod.windows]
    mod.covers = [_rw_expr(c, fn) for c in mod.covers]


def _subst_ids(ast, env):
    return _rw_expr(ast, lambda a: env.get(a[1], a) if a[0] == "id" else a)


def _inline_functions(mod: Module):
    """Replace every user-function call with its body, arguments substituted --
    an `if (c) return e;` chain was already folded to ternaries at parse."""
    if not mod.functions:
        return

    def fn(ast):
        if ast[0] == "call" and ast[1] in mod.functions:
            argn, body = mod.functions[ast[1]]
            return _rw_expr(_subst_ids(body, dict(zip(argn, ast[2]))), fn)
        return ast
    _rw_module(mod, fn)


def _desugar_sticky(mod: Module):
    """Lower each ("sticky", lo, a, b) node -- the sequence-antecedent match set
    "some earlier a, now b" -- to (saw_a && b), where saw_a is a one-bit register
    that latches once a has occurred (reset 0). lo==0 also admits a and b in the
    same cycle. Nested stickies compose bottom-up, which is how a cover sequence
    chain a ##[1:$] b ##[1:$] c becomes one boolean over two monitor bits."""
    created = {}
    idx = [0]

    def mk(lo, a, b):
        key = (repr(a),)
        if key in created:
            reg = created[key]
        else:
            reg = f"__saw{idx[0]}"
            idx[0] += 1
            mod.signals[reg] = {"dir": None, "width": 1}
            mod.next_stmt = ("block", _stmts(mod.next_stmt)
                             + [("assign", reg, ("bin", "||", ("id", reg), a))])
            mod.reset_stmt = ("block", _stmts(mod.reset_stmt)
                              + [("assign", reg, ("const", 0, None))])
            created[key] = reg
        seen = ("id", reg) if lo == 1 else ("bin", "||", ("id", reg), a)
        return ("bin", "&&", seen, b)

    def fn(ast):
        if ast[0] == "sticky":
            return mk(ast[1], ast[2], ast[3])
        return ast
    _rw_module(mod, fn)


def _desugar_queues(mod: Module):
    """Lower each bounded SV queue to an element array + an occupancy counter.
    The queue is finite state only because the checker BOUNDS it (push guarded by
    .size() < DEPTH), so the bound is taken from the DEPTH parameter. Methods
    become ordinary blocking assigns -- .push_back(x) writes data[__n] and bumps
    the counter, .pop_front() shifts toward the head, `= {}` clears the counter,
    .size() reads it -- and the ordinary blocking-substitution fold then gives the
    exact sequential (pop-then-push, read-after-write) semantics."""
    if not mod.queues:
        return
    for q, (w, stype) in mod.queues.items():
        if "DEPTH" not in mod.consts:
            raise SyntaxError(f"queue {q}: no DEPTH parameter to bound it by")
        bound = mod.consts["DEPTH"][0]
        mod.arrays[q] = ([bound], w, stype)
        mod.signals[f"{q}__n"] = {"dir": None, "width": max(1, bound.bit_length())}

    def fn(ast):
        if (ast[0] == "mcall" and ast[1][0] == "id" and ast[1][1] in mod.queues
                and ast[2] == "size"):
            return ("id", f"{ast[1][1]}__n")
        return ast
    _rw_module(mod, fn)

    def lower(stmt):
        if stmt is None:
            return None
        t = stmt[0]
        if t == "qcall" and stmt[1] in mod.queues:
            q, meth, args = stmt[1], stmt[2], stmt[3]
            n = ("id", f"{q}__n")
            one = ("const", 1, None)
            if meth == "pop_front":
                b = mod.arrays[q][0][0]
                shifts = [("assign", ("index", q, ("const", i, None)),
                           ("bit2", ("id", q), ("const", i + 1, None)), False)
                          for i in range(b - 1)]
                return ("block", shifts + [("assign", f"{q}__n",
                                            ("bin", "-", n, one), False)])
            if meth == "push_back":
                return ("block", [("assign", ("index", q, n), args[0], False),
                                  ("assign", f"{q}__n", ("bin", "+", n, one), False)])
            raise SyntaxError(f"queue method {meth} not supported")
        if (t == "assign" and isinstance(stmt[1], str) and stmt[1] in mod.queues
                and stmt[2] == ("qempty",)):
            return ("assign", f"{stmt[1]}__n", ("const", 0, None), False)
        if t == "block":
            return ("block", [lower(s) for s in stmt[1]])
        if t == "if":
            return ("if", stmt[1], lower(stmt[2]), lower(stmt[3]) if stmt[3] else None)
        if t == "case":
            return ("case", stmt[1], [(labs, lower(s)) for labs, s in stmt[2]],
                    lower(stmt[3]) if stmt[3] else None)
        if t == "for":
            return ("for", stmt[1], stmt[2], stmt[3], lower(stmt[4]))
        return stmt
    mod.comb_stmts = [lower(s) for s in mod.comb_stmts]
    mod.next_stmt = lower(mod.next_stmt)
    mod.reset_stmt = lower(mod.reset_stmt)
    mod.queues = {}


def _desugar_past(mod: Module):
    """Synthesize the shadow registers behind $past(e[, N]) and $stable(e): a
    chain of N registers per distinct sampled expression -- verification state,
    exactly what a formal tool builds. $stable(e) is e == $past(e)."""
    created = {}
    counter = [0]

    def widthof(ast):
        t = ast[0]
        if t == "id":
            if ast[1] in mod.signals:
                return mod.signals[ast[1]]["width"]
            if ast[1] in mod.consts:
                return mod.consts[ast[1]][1]
        if t == "field" and ast[1][0] == "id":
            nm = f"{ast[1][1]}.{ast[2]}"
            if nm in mod.signals:
                return mod.signals[nm]["width"]
        if t == "bit2":
            base = ast[1]
            if base[0] == "id" and base[1] in mod.arrays:
                return mod.arrays[base[1]][1]         # an ARRAY ELEMENT, not a bit
            return 1
        if t == "cast":
            return ast[1]
        if t == "bin" and ast[1] in ("==", "!=", "<", "<=", ">", ">=", "&&", "||"):
            return 1
        raise SyntaxError(f"cannot infer the width of $past({ast})")

    def mkpast(e, depth):
        key = (repr(e), depth)
        if key in created:
            return ("id", created[key])
        w = widthof(e)
        idx = counter[0]
        counter[0] += 1
        prev = None
        for k in range(1, depth + 1):
            nm = f"__pv{idx}_{k}"
            mod.signals[nm] = {"dir": None, "width": w}
            src = e if k == 1 else ("id", prev)
            mod.next_stmt = ("block", _stmts(mod.next_stmt) + [("assign", nm, src)])
            mod.reset_stmt = ("block", _stmts(mod.reset_stmt)
                              + [("assign", nm, ("const", 0, None))])
            prev = nm
        created[key] = prev
        return ("id", prev)

    def pvalid():
        """A once-armed bit: 0 at the first cycle, 1 ever after. $stable has no
        'before time 0' -- its first evaluation is vacuously true, NOT a compare
        against the shadow register's reset value (which would silently pin a
        free-but-stable variable to 0)."""
        if "__pvalid" not in mod.signals:
            mod.signals["__pvalid"] = {"dir": None, "width": 1}
            mod.next_stmt = ("block", _stmts(mod.next_stmt)
                             + [("assign", "__pvalid", ("const", 1, None))])
            mod.reset_stmt = ("block", _stmts(mod.reset_stmt)
                              + [("assign", "__pvalid", ("const", 0, None))])
        return ("id", "__pvalid")

    def fn(ast):
        if ast[0] == "call" and ast[1] == "$past":
            depth = 1
            if len(ast[2]) > 1:
                d = ast[2][1]
                depth = d[1] if d[0] == "const" else mod.consts[d[1]][0]
            return mkpast(ast[2][0], depth)
        if ast[0] == "call" and ast[1] == "$stable":
            e = ast[2][0]
            return ("bin", "||", ("un", "!", pvalid()),
                    ("bin", "==", e, mkpast(e, 1)))
        return ast
    _rw_module(mod, fn)


def _desugar_windows(mod: Module):
    """Lower `p |-> ##[lo:hi] q` EXACTLY, as safety: a chain of hi aux bits where
    bit k means "an attempt is k cycles old and q has not yet discharged it inside
    the window". Every antecedent occurrence spawns its own attempt (overlap is
    handled by the chain itself), an attempt aged k in [lo, hi) dies when q holds,
    and the property is that an attempt never sits at age hi with q still false.
    This is the monitor a formal tool synthesizes for a bounded SVA delay."""
    for i, (lo, hi, ante, cons, is_assume) in enumerate(mod.windows):
        if hi == 0:                                  # ##0: same-cycle implication
            con = ("bin", "||", ("un", "!", ante), cons)
        else:
            prev = None
            for k in range(1, hi + 1):
                nm = f"__win{i}_{k}"
                mod.signals[nm] = {"dir": None, "width": 1}
                if k == 1:
                    src = ante if lo > 0 else ("bin", "&&", ante, ("un", "!", cons))
                else:
                    src = ("id", prev)
                    if k - 1 >= lo:                  # discharged inside the window
                        src = ("bin", "&&", src, ("un", "!", cons))
                mod.next_stmt = ("block", _stmts(mod.next_stmt) + [("assign", nm, src)])
                mod.reset_stmt = ("block", _stmts(mod.reset_stmt)
                                  + [("assign", nm, ("const", 0, None))])
                prev = nm
            con = ("bin", "||", ("un", "!", ("id", prev)), cons)
        if is_assume:
            mod.assumptions.append(con)
        else:
            mod.prop = con if mod.prop is None else ("bin", "&&", mod.prop, con)
    mod.windows = []


def _desugar_temporal(mod: Module):
    """Rewrite each `p |=> q` into an aux register `__past = p` plus a combinational
    constraint `¬__past ∨ q` -- the standard next-cycle-implication lowering."""
    for i, (ante, cons, is_assume) in enumerate(mod.next_props):
        reg = f"__past{i}"
        mod.signals[reg] = {"dir": None, "width": 1}
        mod.next_stmt = ("block", _stmts(mod.next_stmt) + [("assign", reg, ante)])
        mod.reset_stmt = ("block", _stmts(mod.reset_stmt) + [("assign", reg, ("const", 0, None))])
        con = ("bin", "||", ("un", "!", ("id", reg)), cons)
        if is_assume:
            mod.assumptions.append(con)
        else:
            mod.prop = con if mod.prop is None else ("bin", "&&", mod.prop, con)
    mod.next_props = []


def _merge_checker(design: Module, checker: Module):
    """Merge a bound checker into its target design (connect .* by name): the checker's
    internal signals / logic / properties join the design, its ports are the interface."""
    iface = set(checker.ports) | {s for p in checker.ports for s in checker.signals
                                  if s.startswith(p + ".")}
    for n, s in checker.signals.items():
        if n not in iface:
            design.signals.setdefault(n, s)
    # a checker port with no matching design signal OR ARRAY is left unconnected by
    # `.*` -> it becomes a free primary input (e.g. the single-residence checker's
    # `probe_set`). An array port (a checker probing the design's memory) matches
    # the design's array by name and must NOT be freed.
    for p in checker.ports:
        if (p not in design.signals and p not in design.arrays
                and p in checker.signals):
            design.signals[p] = dict(checker.signals[p], dir="input")
    design.consts.update(checker.consts)
    design.types.update(checker.types)
    design.structs.update(checker.structs)
    for n, a in checker.arrays.items():      # a checker's own array (not an array PORT,
        if n not in checker.ports:           # which probes the design's array by name)
            design.arrays.setdefault(n, a)
    design.queues.update(checker.queues)
    design.functions.update(checker.functions)
    design.windows += checker.windows
    design.covers += checker.covers
    design.assigns += checker.assigns
    design.comb_stmts += checker.comb_stmts
    if checker.next_stmt is not None:
        design.next_stmt = (checker.next_stmt if design.next_stmt is None
                            else ("block", _stmts(design.next_stmt) + _stmts(checker.next_stmt)))
        design.reset_stmt = (checker.reset_stmt if design.reset_stmt is None
                             else ("block", _stmts(design.reset_stmt) + _stmts(checker.reset_stmt)))
        design.reset = design.reset or checker.reset
    if checker.prop is not None:
        design.prop = (checker.prop if design.prop is None
                       else ("bin", "&&", design.prop, checker.prop))
    design.liveness += checker.liveness
    design.assumptions += checker.assumptions
    design.next_props += checker.next_props


def build_multi(texts, params=None) -> TransitionSystem:
    """Parse one or more source texts (design + checker + package), merge each bound
    checker into its target, and elaborate the (single) design under verification.
    `params` forces reduced parameter values (a small-config proof). Files feed one
    compilation unit IN ORDER (package before design before checker), so a later
    file's ports and parameter defaults resolve the earlier files' types."""
    mods, binds = {}, []
    unit = {"consts": {}, "types": {}, "structs": {}}
    for text in texts:
        p = Parser(tokenize(preprocess(text, defines=("FORMAL",))),
                   overrides=params, unit=unit)
        while not p.at_eof():
            if p.at("bind"):
                binds.append(p.parse_bind())
            else:
                m = p.parse_module()
                if m.name:
                    mods[m.name] = m
                unit["consts"].update(m.consts)
                unit["types"].update(m.types)
                unit["structs"].update(m.structs)
    # package/$unit scope is global: give every module the consts/types/structs it lacks,
    # so a separately-parsed checker resolves the design's enums (I, ...) and widths.
    for m in mods.values():
        for k, v in unit["consts"].items():
            m.consts.setdefault(k, v)
        for k, v in unit["types"].items():
            m.types.setdefault(k, v)
        for k, v in unit["structs"].items():
            m.structs.setdefault(k, v)
    for target, checker in binds:
        if target in mods and checker in mods:
            _merge_checker(mods[target], mods[checker])
    targets = [t for t, _ in binds if t in mods]
    main = mods[targets[0]] if targets else next(iter(mods.values()))
    _inline_functions(main)       # user functions -> their bodies, args substituted
    _desugar_sticky(main)         # sequence antecedents / covers -> saw-registers
    _desugar_queues(main)         # bounded queues -> element array + occupancy counter
    _desugar_past(main)           # $past/$stable -> shadow-register chains
    _desugar_windows(main)        # ##[lo:hi] windows -> exact aux-bit monitors (safety)
    _desugar_temporal(main)
    _expand_arrays(main)          # unroll loops + flatten finite arrays to scalars (no-op if none)
    return _coi_reduce(_Elaborator(main).build())    # drop state the property never reads


def build(src: str, params=None) -> TransitionSystem:
    return build_multi([src], params)


def load(*paths, params=None) -> TransitionSystem:
    """Load and prove one design; extra paths (its checker, its package) are merged in.
    `load('d.sv')` or `load('d.sv', 'd_checker.sv', params={'SETS': 2})`."""
    if len(paths) == 1 and isinstance(paths[0], (list, tuple)):
        paths = tuple(paths[0])
    texts = []
    for p in paths:
        with open(p) as f:
            texts.append(f.read())
    return build_multi(texts, params)


def example(dirname: str) -> TransitionSystem:
    """Load the single .sv DUT in a sibling example directory, e.g.
    example('02_elevator_proof'). Resolved relative to this file, so it works
    from any working directory."""
    import os
    import glob
    here = os.path.dirname(os.path.abspath(__file__))
    matches = sorted(glob.glob(os.path.join(here, "..", dirname, "*.sv")))
    if not matches:
        raise FileNotFoundError(f"no .sv DUT found in {dirname}")
    return load(matches[0])


if __name__ == "__main__":
    # smoke 1: the original flat form still elaborates (regression).
    toggle = """
    module toggle (input logic clk, input logic rst, output logic q);
      always_ff @(posedge clk)
        if (rst) q <= 1'b0;
        else     q <= ~q;
      assert property (@(posedge clk) disable iff (rst) (q == 1'b0) || (q == 1'b1));
    endmodule
    """
    ts = build(toggle)
    assert ts.state == ["q"] and ts.init["q"] is False and ts.inputs == []
    print("[frontend] smoke 1 (flat always_ff):", ts.state, ts.init)

    # smoke 2: the new FSM subset -- enum + case + if in always_comb + async reset.
    fsm = """
    module fsm (input logic clk, input logic rst_n, input logic go, output logic done);
      typedef enum logic [1:0] {A=0, B=1, C=2} st_t;
      st_t state, next_state;
      always_comb begin
        next_state = state;
        done       = 1'b0;
        case (state)
          A: if (go) next_state = B;
          B: next_state = C;
          C: begin done = 1'b1; next_state = A; end
        endcase
      end
      always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) state <= A;
        else        state <= next_state;
      assert property (@(posedge clk) disable iff (!rst_n) (state <= 2'd2));
    endmodule
    """
    ts2 = build(fsm)
    assert ts2.state == ["state[0]", "state[1]"], ts2.state
    assert ts2.inputs == ["go"], ts2.inputs
    print("[frontend] smoke 2 (enum+case+async reset):", ts2.state, "inputs", ts2.inputs)
    print("[frontend] OK")
