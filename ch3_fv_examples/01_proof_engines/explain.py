"""
explain.py -- the narrated preamble for --trace.

Before any engine runs, this prints what the frontend actually built from the RTL
(the transition system: state bits, inputs, next-state functions, reset, and the
`bad` predicate that is the property's negation) and then walks the Tseitin
encoding of `bad` into CNF gate by gate -- the "how it turns the circuit into
clauses" step the chapter describes. Large datapath predicates are summarized
rather than dumped (the point is to see the mechanism on a small example).
"""

from __future__ import annotations
from cdcl import Solver
from circuit import fresh_frame, tseitin, sig_str, count_gates
from trace import T, fmt_clause


def explain_ts(ts):
    """Narrate the transition system the frontend produced."""
    T.rule("Transition system (frontend output: RTL → state machine)")
    T.say(f"state bits ({len(ts.state)}): {', '.join(ts.state)}")
    T.say(f"inputs     ({len(ts.inputs)}): {', '.join(ts.inputs) or '(none)'}")
    with T.section("next-state functions  s' = f(s, inputs):"):
        for s in ts.state:
            T.say(f"{s}' = {sig_str(ts.next[s])}")
    T.say("reset state: " + ", ".join(f"{s}={int(ts.init[s])}" for s in ts.state))
    T.say(f"property holds when NOT bad, where  bad = {sig_str(ts.bad)}")


def explain_encoding(ts, cap=24):
    """Walk the Tseitin encoding of `bad` into CNF. One fresh Boolean per gate;
    three (or four) clauses force aux ⇔ gate. Small predicates are shown in full;
    a large datapath predicate is summarized with its gate/clause counts."""
    ng = count_gates(ts.bad)
    T.rule("Tseitin encoding of `bad` → CNF (the V8's fuel)")
    s = Solver()
    env = fresh_frame(s, ts, 0)                 # named leaves: state/input @0
    if ng <= cap:
        T.say("introduce one Boolean per gate; each gate's clauses force aux ⇔ gate:")
        s._echo_enc = True
        top = tseitin(s, ts.bad, env, {})
        s._echo_enc = False
        T.say(f"finally assert the top gate: {fmt_clause([top], s.names)}")
        T.say(f"→ {s.n_vars} variables, {len(s.clauses)} multi-literal clauses in this encoding")
    else:
        top = tseitin(s, ts.bad, env, {})
        T.say(f"`bad` is a {ng}-gate datapath predicate; encoding it yields "
              f"{s.n_vars} variables and {len(s.clauses)} clauses.")
        T.say("(gate-by-gate output is elided here -- run a small FSM example to watch every")
        T.say(" clause emitted; the mechanism is identical, just shorter.)")
