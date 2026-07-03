"""
prove.py -- read a SystemVerilog DUT, build its transition system through the
frontend, Tseitin-encode it, and run the Chapter 3 proof engines on it.

    python3 prove.py ../02_elevator_proof/elevator.sv            # the full escalation
    python3 prove.py ../03_fifo_proof/fifo.sv --engine ic3       # one engine
    python3 prove.py ../03_fifo_proof/fifo.sv --check            # assert the expected verdict

The example Makefiles call this; it is the front door from RTL to a proof.
"""

from __future__ import annotations
import argparse
import sys

import frontend
from kinduction import one_step_inductive, k_induction
from bmc import bmc
from ic3 import IC3
from interp import itp_mc
from trace import T
from circuit import sig_str


def _short(sig, n=72):
    """A one-line label for a property. A liveness antecedent/consequent lowered from a
    book checker can be an enormous boolean expression; the full form is not useful in a
    header, so cap it -- the verdict below, not the label, is what carries the proof."""
    s = sig_str(sig)
    return s if len(s) <= n else s[:n] + " …"


def _decode(solver, env, ts) -> dict:
    """Group a frame's state bits back into named (multi-bit) values."""
    out, seen = {}, set()
    for st in ts.state:
        base = st.split("[")[0]
        if "[" in st:
            if base in seen:
                continue
            seen.add(base)
            w = sum(1 for x in ts.state if x.startswith(base + "["))
            out[base] = sum((1 << i) for i in range(w)
                            if solver.get_value(env[f"{base}[{i}]"]))
        else:
            out[st] = int(solver.get_value(env[st]))
    return out


def run(paths, engines, kmax_bmc=12, kmax_ind=8, params=None):
    import os
    from circuit import FALSE
    from liveness import apply_assumptions, liveness_to_safety
    if isinstance(paths, str):
        paths = [paths]
    ts = frontend.load(*paths, params=params)
    print(f"DUT: {' + '.join(os.path.basename(p) for p in paths)}")
    print(f"  {len(ts.state)} state bit(s), {len(ts.inputs)} input(s)"
          + (f", {len(ts.liveness)} liveness" if ts.liveness else "")
          + (f", {len(ts.assumptions)} assumption(s)" if ts.assumptions else ""))
    verdicts = {}
    has_safety = ts.bad is not FALSE
    if has_safety:
        print("  --- safety ---")
        target = apply_assumptions(ts)          # guard bad by the environment assumptions
        if T.on:
            import explain
            explain.explain_ts(target)
            explain.explain_encoding(target)
            T.say("")
        verdicts.update(_escalate(target, engines, kmax_bmc, kmax_ind))
    for i, cv in enumerate(getattr(ts, "covers", [])):
        # A cover is a reachability SANITY: BMC hunts a state where the lowered
        # sequence completes. Missing it within the bound is a vacuity warning,
        # never a proof failure -- covers do not gate --check.
        from circuit import TransitionSystem as _TS
        t3 = _TS(ts.name + "+cover")
        t3.state, t3.inputs = list(ts.state), list(ts.inputs)
        t3.next, t3.init = dict(ts.next), dict(ts.init)
        t3.assumptions = list(ts.assumptions)
        t3.bad = cv
        r = bmc(apply_assumptions(t3), kmax_bmc)
        if r["result"] == "CEX":
            print(f"  [cover {i}      ] COVERED at depth {r['depth']} -> the sequence is reachable (assumptions non-vacuous)")
        else:
            print(f"  [cover {i}      ] NOT reached to depth {kmax_bmc} -> vacuity warning (informational)")
    for i in range(len(ts.liveness)):
        a, b = ts.liveness[i]
        print(f"  --- liveness {i}: ({_short(a)}) |-> s_eventually ({_short(b)}) ---")
        L = liveness_to_safety(ts, i)
        if bmc(L, kmax_bmc)["result"] == "CEX":
            print("  [liveness      ] FAILS -> a starvation lasso is reachable")
            verdicts[f"live{i}"] = "FAILS"
            continue
        r = IC3(L).solve()
        holds = r["result"] == "SAFE"
        print(f"  [liveness      ] {'HOLDS' if holds else 'FAILS'} -> "
              + ("no starvation lasso is reachable" if holds else "a counterexample was found"))
        verdicts[f"live{i}"] = "HOLDS" if holds else "FAILS"
    return ts, verdicts


def _escalate(ts, engines, kmax_bmc=12, kmax_ind=8):
    verdicts = {}

    if "cdcl" in engines:
        sat, (s, env0) = one_step_inductive(ts)
        if sat:
            wit = _decode(s, env0, ts)
            print(f"  [CDCL one-step ] SAT   -> the property is NOT 1-inductive; "
                  f"witness {wit} steps to a violation (reachable? CDCL cannot say)")
        else:
            print(f"  [CDCL one-step ] UNSAT -> the property is 1-inductive "
                  f"(settled in one combinational query)")
        verdicts["cdcl"] = "SAT" if sat else "UNSAT"

    if "bmc" in engines:
        r = bmc(ts, kmax_bmc)
        if r["result"] == "CEX":
            print(f"  [BMC           ] CEX at depth {r['depth']} -> a real bug from reset")
        else:
            print(f"  [BMC           ] no counterexample to depth {kmax_bmc} "
                  f"(bug finder, not yet a proof)")
        verdicts["bmc"] = r["result"]

    if "kind" in engines:
        r = k_induction(ts, kmax_ind)
        if r["result"] == "PROVED":
            print(f"  [k-induction   ] PROVED at k={r['k']} -> {r['k']}-inductive")
        elif r["result"] == "CEX":
            print(f"  [k-induction   ] CEX -> a real counterexample")
        else:
            cti = r["cti"][-2] if r.get("cti") else None
            print(f"  [k-induction   ] STALLED to k={r['kmax']} -> loses at every k "
                  f"on the recurring CTI {cti}")
        verdicts["kind"] = r["result"]

    if "ic3" in engines:
        eng = IC3(ts)
        r = eng.solve()
        if r["result"] == "SAFE":
            inv = sorted(r.get("invariant", []), key=lambda c: sorted(c, key=abs))
            print(f"  [IC3/PDR       ] SAFE in {r.get('frames')} frames -> "
                  f"discovered a {len(inv)}-clause inductive invariant:")
            for cl in inv:
                print(f"                     {eng.clause_str(cl)}")
        else:
            print(f"  [IC3/PDR       ] {r['result']} -> a real counterexample")
        verdicts["ic3"] = r["result"]

    if "interp" in engines:
        r = itp_mc(ts)
        tail = {"SAFE": "invariant carved from refutation proofs",
                "UNSAFE": "a real counterexample (reachable from reset)"}.get(
                    r["result"], r.get("reason", ""))
        print(f"  [interpolation ] {r['result']} -> {tail}")
        verdicts["interp"] = r["result"]

    return verdicts


def run_liveness(ts, engines, kmax_bmc=12, kmax_ind=8):
    """Prove a liveness property `a |-> s_eventually b` by reducing it to the
    unreachability of a lasso (liveness.py), then running the safety engines on the
    augmented system. SAFE ⇒ no p-avoiding loop ⇒ the liveness holds."""
    from liveness import liveness_to_safety
    a, b = ts.liveness[0]
    print(f"  liveness property: (a |-> s_eventually b)")
    print(f"    a = {sig_str(a)}")
    print(f"    b = {sig_str(b)}")
    if ts.assumptions:
        print(f"  under {len(ts.assumptions)} environment assumption(s)")
    L = liveness_to_safety(ts)
    print(f"  liveness→safety: {len(ts.state)} design bits → {len(L.state)} bits "
          f"(+pending/saved/shadow/triggered), bad = a p-avoiding lasso\n")
    if T.on:
        import explain
        T.rule("Liveness → safety reduction (lasso detection)")
        T.say("bad(augmented) is reachable  ⟺  the design has a reachable loop in which")
        T.say("the good event p = ¬pending never occurs — i.e. a starvation lasso.")
        explain.explain_ts(L)
        T.say("")
    # only the safety engines that give a proof/refutation are meaningful here
    live_engines = [e for e in engines if e in ("bmc", "kind", "ic3", "interp")] or ["bmc", "ic3"]
    verdicts = _escalate(L, live_engines, kmax_bmc, kmax_ind)
    holds = verdicts.get("ic3") == "SAFE"
    lasso = (verdicts.get("ic3") == "UNSAFE" or verdicts.get("bmc") == "CEX"
             or verdicts.get("kind") == "CEX")
    print("\n  LIVENESS " + ("HOLDS: no starvation lasso is reachable — the obligation is"
                             " always eventually met."
                             if holds and not lasso else
                             "FAILS: a starvation lasso is reachable (the good event never"
                             " comes on that loop)." if lasso else
                             "UNKNOWN (no engine settled the augmented safety question)."))
    verdicts["liveness"] = "HOLDS" if (holds and not lasso) else ("FAILS" if lasso else "UNKNOWN")
    return L, verdicts


def prove_smt(path, check=False):
    """Read an SMT-LIB QF_BV equivalence miter and decide it with DPLL(T)."""
    import smt
    import smt_frontend
    with open(path) as f:
        atoms, cnf, W = smt_frontend.read(f.read())
    print(f"SMT-LIB: {path}")
    print(f"  {len(atoms)} equality atom(s), {W}-bit bit-vectors\n")

    r = smt.solve(atoms, cnf, W, allow_bitblast=False)         # word-level, no bit-blasting
    a0 = atoms[0]
    _, nclauses = smt.bitblast_equiv(a0.t1, a0.t2, W, count_only=True)

    if r[0] == "UNSAT":
        print(f"  [DPLL(T) word-level] UNSAT in {len(r[1])} theory lemma(s) "
              f"-> the two designs are EQUIVALENT")
    elif r[0] == "SAT-bb":
        print(f"  [DPLL(T) word-level] SAT -> NOT equivalent; witness {r[1]}")
    else:
        print(f"  [DPLL(T) word-level] {r[0]}")
    print(f"  [eager bit-blast    ] the same miter is {nclauses} CNF clauses "
          f"-- word-level decided it without paying that (the multiplier wall)")

    if check:
        ok = r[0] == "UNSAT"
        print("\nEQUIVALENCE " + ("HOLDS: the designs compute the same function for every input."
                                 if ok else "FAILS."))
        sys.exit(0 if ok else 1)


def main():
    ap = argparse.ArgumentParser(description="prove a SystemVerilog DUT with the Chapter 3 engines")
    ap.add_argument("dut", nargs="+", help="design .sv (plus its checker / package / env .sv)")
    ap.add_argument("--engine", default="all",
                    help="all | cdcl | bmc | kind | ic3 | interp (comma-separated)")
    ap.add_argument("--check", action="store_true",
                    help="exit non-zero unless IC3 proves SAFE and no engine refutes")
    # Quiet verdicts by default; the teaching narration is OPT-IN. These solvers
    # exist to be understood, so when you want to watch them think, --trace
    # narrates the transition system, the Tseitin encoding, and every engine step,
    # and --deep additionally narrates the CDCL search under each query.
    # (--no_trace/--no_deep are kept so older recipes still run; they are the default.)
    ap.add_argument("--trace", dest="trace", action="store_true",
                    help="narrate the transition system, the Tseitin encoding, and every "
                         "engine step, literals by name (off by default)")
    ap.add_argument("--no_trace", "--no-trace", dest="trace", action="store_false",
                    help="quiet: print only the per-engine verdicts (the default)")
    ap.add_argument("--deep", dest="deep", action="store_true",
                    help="also narrate the CDCL search under each engine query -- decisions, "
                         "propagations, conflicts, learned clauses (implies --trace)")
    ap.add_argument("--no_deep", "--no-deep", dest="deep", action="store_false",
                    help="skip the CDCL search narration (the default)")
    ap.add_argument("--word", action="store_true",
                    help="read the design(s) WORD-LEVEL (memory as an array) and prove with "
                         "word.py k-induction -- the address stays symbolic, never bit-blasted")
    ap.add_argument("--param", action="append", default=[], metavar="NAME=VAL",
                    help="force a reduced parameter value for a small-config proof "
                         "(repeatable), e.g. --param SETS=2 --param TAG_W=2")
    ap.add_argument("--bmc-depth", dest="bmc_depth", type=int, default=0,
                    help="run only a BOUNDED BMC check to this depth (no unbounded proof) -- "
                         "for a design whose full proof is out of the from-scratch engine's reach")
    ap.add_argument("--cegar", action="store_true",
                    help="prove safety by CEGAR localization (abstract / check / replay / "
                         "refine) -- for a design whose full state defeats a direct IC3 run "
                         "but whose property depends on a few bits of it")
    ap.set_defaults(trace=False, deep=False)
    args = ap.parse_args()

    if args.deep:                            # --deep alone means "show me everything"
        args.trace = True
    T.on = args.trace
    T.deep = args.deep
    params = {kv.split("=")[0]: int(kv.split("=")[1]) for kv in args.param} or None

    if args.bmc_depth:                       # bounded BMC only (full-book read + no shallow CEX)
        ts = frontend.load(*args.dut, params=params)
        print(f"DUT: {' + '.join(__import__('os').path.basename(p) for p in args.dut)} "
              f"({len(ts.state)} state, {len(ts.inputs)} inputs)")
        r = bmc(ts, args.bmc_depth)
        safe = r["result"] != "CEX"
        print(f"  [BMC depth {args.bmc_depth}] "
              + (f"SAFE-UP-TO {args.bmc_depth} -> no property violation within the bound"
                 if safe else f"CEX at depth {r.get('depth', '?')} -> a real violation"))
        if args.check:
            sys.exit(0 if safe else 1)
        return

    if args.cegar:                           # CEGAR localization: abstract/check/replay/refine
        from cegar import cegar
        from liveness import apply_assumptions
        ts = frontend.load(*args.dut, params=params)
        print(f"DUT: {' + '.join(__import__('os').path.basename(p) for p in args.dut)} "
              f"({len(ts.state)} state, {len(ts.inputs)} inputs)")
        print("  --- safety, by CEGAR localization ---")
        r = cegar(apply_assumptions(ts))
        if r["result"] == "SAFE":
            print(f"PROOF HOLDS: SAFE after {r['rounds']} round(s) -- the property depends on "
                  f"{len(r['kept'])} of {len(ts.state)} state bits; the rest stayed cut free.")
        elif r["result"] == "UNSAFE":
            print(f"REFUTED: a real counterexample, {r['depth']} cycle(s) from reset "
                  f"(replayed concretely in round {r['rounds']}).")
        else:
            print("UNKNOWN: the CEGAR loop did not settle the property.")
        if args.check:
            sys.exit(0 if r["result"] == "SAFE" else 1)
        return

    if args.word:                            # word-level path: RTL -> WordTS -> k-induction
        from word_frontend import build_word
        from word import w_kinduction
        ts = build_word(*args.dut)
        nmem = sum(1 for n in ts.state if isinstance(ts.widths[n], tuple))
        print(f"DUT: {' + '.join(__import__('os').path.basename(p) for p in args.dut)} "
              f"(word-level: {len(ts.state)} state, {nmem} memory kept symbolic)")
        r = w_kinduction(ts, 1)
        holds = r[0] == "SAFE"
        print(f"  [word k-induction] {'HOLDS' if holds else 'REFUTED'} -> "
              + ("proved with the memory address symbolic (array theory), never bit-blasted"
                 if holds else "a counterexample exists (the memory contract fails)"))
        print("PROOF HOLDS: the memory contract holds word-level." if holds
              else "REFUTED: the word-level engine broke the memory contract.")
        if args.check:
            sys.exit(0 if holds else 1)
        return

    if len(args.dut) == 1 and args.dut[0] in ("sec", "sec-bug"):   # pipelined-ALU SEC miter
        from sec import prove_sec
        bug = "no_mem_fwd" if args.dut[0] == "sec-bug" else None
        print("DUT: pipelined ALU"
              + (" MUTATION (the MEM-stage forwarding path is removed)" if bug else "")
              + " -- sequential equivalence vs in-order reference\n")
        r = prove_sec(bug=bug)
        print(f"\nSEQUENTIAL EQUIVALENCE: the pipeline is {r} to the in-order reference"
              + (" for every operand value (word-level)." if r == "EQUIVALENT"
                 else " -- a forwarding hazard is mishandled (the operands that expose it are above)."))
        if args.check:
            sys.exit(0 if r == "EQUIVALENT" else 1)
        return

    if len(args.dut) == 1 and args.dut[0] in ("mem", "mem-bug"):   # word-level array-theory memory
        from memproof import prove_mem
        bug = args.dut[0] == "mem-bug"
        ok = prove_mem(w=12, bug=bug)
        if args.check:
            sys.exit(0 if ok else 1)
        return

    if args.dut[0].endswith(".smt2"):        # an SMT-LIB equivalence miter, not RTL
        prove_smt(args.dut[0], args.check)
        return

    order = ["cdcl", "bmc", "kind", "ic3", "interp"]
    engines = order if args.engine == "all" else [e.strip() for e in args.engine.split(",")]
    _, verdicts = run(args.dut, engines, params=params)

    if args.check:
        # Safety: IC3 (sound + complete here) proves SAFE and no engine refutes; a
        # too-deep interpolation UNKNOWN is incompleteness, not a refutation. Liveness:
        # every obligation HOLDS. The overall proof holds iff both do.
        refuted = (verdicts.get("bmc") == "CEX" or verdicts.get("kind") == "CEX"
                   or verdicts.get("ic3") == "UNSAFE" or verdicts.get("interp") == "UNSAFE")
        safety_ok = "ic3" not in verdicts or (verdicts.get("ic3") == "SAFE" and not refuted)
        live_ok = all(v == "HOLDS" for k, v in verdicts.items() if k.startswith("live"))
        ok = safety_ok and live_ok
        print("\nPROOF " + ("HOLDS: every contract (safety and liveness) is proven."
                            if ok else "FAILED."))
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
