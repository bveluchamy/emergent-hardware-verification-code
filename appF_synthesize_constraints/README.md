# appF_synthesize_constraints/ — companion code for Appendix F

Runnable code behind **Appendix F, "Synthesizing Constrained-Random Stimulus"** (and Chapter 4
§"Implementing the Constraint Solver") of *Emergent Hardware Verification*. Every sampler and engine
here runs in Verilator and synthesizes with Yosys — the appendix's claim is that a constraint solver
can be compiled to hardware, and this is that compilation, built and checked.

## The directories (in the order Chapter 4 §4.4 walks them)

| directory | what it is |
|---|---|
| `01_constraint_compiler/` | the **frontend**: parses real SystemVerilog constraints (`frontend.py`) and compiles them through a BDD (`csc.py`) to a search-free sampler. Includes the vendored riscv-dv corpus it reads (`corpus/riscv-dv/`, pinned — see `VENDORED_COMMIT.txt`). |
| `02_constructive_samplers/` | the first **Tier-0/1 constructive samplers** — a constraint compiled directly to a datapath. |
| `03_reactive_constraints/` | **reactive** constraints (config-dependent legal sets) and a Sudoku-style propagation network. |
| `04_sat_engine/` | the hard tier, runnable: a **DPLL → DPLL(T) → 1-UIP CDCL** satisfiability engine on the fabric. |
| `05_lean_certified/` | the **Lean 4** certification layer — sound/complete/uniform samplers, certified code generation, and a Lehmer allocator proved smaller and faster than the hand-written one. |
| `06_riscvdv_capstone/` | the **riscv-dv capstone** — every constraint shape synthesized and checked both directions against the reference solver, plus the integrated generator, the pipelined selector, and the UVM oracle. |

## Building and running

Each directory has its own short `README` (and `run.sh` / `Makefile`) with the exact commands. Quick starts:

```sh
cd 05_lean_certified   && ./run.sh                    # the Lean proofs (0 sorries)
cd 04_sat_engine       && make && ./obj_dir/Vtb_dpll  # the SAT engine on the fabric
cd 06_riscvdv_capstone && cat README.md               # the capstone run instructions
```

Tools: `verilator` 5.049 (rand/constraint/randomize + UVM 1.2), `yosys` (`synth_ice40`), `nextpnr-ice40`,
`lean` 4.x. The riscv-dv corpus is vendored (pinned), so the examples build without a separate clone. The
book PDF builds separately (`latexmk` at the repo root); the code here is its runnable companion.
