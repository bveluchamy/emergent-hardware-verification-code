# Chapter 3 examples — run them yourself

Self-contained, runnable companions for Chapter 3 (*Formal Verification*). The
proof-engine examples read a real SystemVerilog DUT, build its transition system
through a small frontend, Tseitin-encode it, and prove the property — the path a
real formal tool takes. Each example reproduces a result the chapter states.

| dir | what | run it |
|-----|------|--------|
| `01_proof_engines` | the **common code**: a from-scratch CDCL solver, the gate/bit-vector DSL + Tseitin, the SystemVerilog and SMT-LIB frontends, and the engines (BMC, k-induction, IC3/PDR, Craig interpolation, DPLL(T)) | imported by the examples; `python3 demo.py` runs the whole escalation |
| `02_elevator_proof` | `elevator.sv` — the interlock (safe for a *local* reason; 1-inductive) | `cd 02_elevator_proof && make` |
| `03_fifo_proof` | `fifo.sv` — the overflow guard (safe for a *global* reason; needs the hidden invariant) | `cd 03_fifo_proof && make` |
| `04_adder_equiv_smt_proof` | `*.smt2` — the §"SMT" worked example: a rebalanced adder tree (and the bvmul multiplier wall), proven equivalent by DPLL(T) | `cd 04_adder_equiv_smt_proof && make` |
| `05_booth_lean_proof` | the §"Theorem Proving" worked example — a Booth multiplier identity proved in Lean 4, kernel-checked | `cd 05_booth_lean_proof && lake build` |

The flow:

```
elevator.sv / fifo.sv  ──frontend──▶  TransitionSystem  ──Tseitin──▶  CNF  ──▶  CDCL → BMC → k-induction → IC3 → interpolation
```

`01_proof_engines` is pure Python, no dependencies; every engine module's
`__main__` reads the two DUTs and asserts the chapter's verdict, so running a file
is its test. Each example directory has a `Makefile`: `make` runs the full
escalation on that DUT, `make ic3` runs a single engine, `make check` asserts the
property is proven. `04_adder_equiv_smt_proof` proves a datapath equivalence
miter with DPLL(T) instead (`make`). `05_booth_lean_proof` is the prebuilt
`BoothProof` Lean project; `lake build` runs the kernel over every theorem. See
each directory's own `README.md` for detail.
