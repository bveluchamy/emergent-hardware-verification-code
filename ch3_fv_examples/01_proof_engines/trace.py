"""
trace.py -- a tiny tracing facility that turns every engine into a narrated,
step-by-step teaching artifact.

These solvers are written to be *understood*, not to be fast. With tracing on,
running a single example prints exactly what the solver does and why: the Tseitin
clauses it emits, every CDCL decision / propagation / conflict / learned clause,
each BMC frame, each k-induction query, each IC3 proof obligation and the literals
it drops when generalizing, each interpolant it carves -- and, when a solver cannot
finish, the concrete reason it is stuck. A reader learns the algorithm by watching
it run one example.

Tracing is OFF by default and costs almost nothing then (one boolean test at each
trace point). Turn it on with `prove.py <dut> --engine ic3 --trace`, or in code:

    from trace import T
    T.on = True

Literals are printed by name. The Tseitin encoder and the frame builders register
`solver.names[var] = "state[0]@2"` / `"g47"`, so a raw CNF variable shows up as the
signal (and time frame) it stands for instead of an opaque integer.
"""

from __future__ import annotations
import sys


def fmt_lit(lit: int, names: dict | None = None) -> str:
    v = abs(lit)
    nm = (names or {}).get(v, f"x{v}")
    return nm if lit > 0 else f"¬{nm}"


def fmt_clause(lits, names: dict | None = None) -> str:
    if not lits:
        return "⊥ (empty clause)"
    return "(" + " ∨ ".join(fmt_lit(l, names) for l in lits) + ")"


class _Section:
    def __init__(self, tracer, title):
        self.tracer, self.title = tracer, title

    def __enter__(self):
        if self.title:
            self.tracer.say(self.title)
        self.tracer.depth += 1
        return self.tracer

    def __exit__(self, *exc):
        self.tracer.depth -= 1
        return False


class Tracer:
    """A global, indentation-aware narrator. `on` gates all output."""

    def __init__(self):
        self.on = False
        self.deep = False        # also narrate the CDCL search under each engine query
        self.depth = 0
        self.out = sys.stdout

    # ---- primitives ---------------------------------------------------------
    def say(self, msg: str = ""):
        if not self.on:
            return
        pad = "  " * self.depth
        for line in str(msg).split("\n"):
            self.out.write(pad + line + "\n")

    def rule(self, title: str = ""):
        """A titled horizontal rule at the current indent -- a phase boundary."""
        if not self.on:
            return
        pad = "  " * self.depth
        bar = "─" * max(3, 64 - len(title) - 3 - len(pad))
        self.out.write(f"{pad}── {title} {bar}\n" if title else f"{pad}{'─' * 64}\n")

    def section(self, title: str = "") -> _Section:
        """`with T.section('title'):` -- prints the title then indents its body."""
        return _Section(self, title)

    # ---- literal / clause pretty-printing (name-aware) ----------------------
    def lit(self, lit: int, names: dict | None = None) -> str:
        return fmt_lit(lit, names)

    def clause(self, lits, names: dict | None = None) -> str:
        return fmt_clause(lits, names)


# The single shared narrator every engine imports.
T = Tracer()
