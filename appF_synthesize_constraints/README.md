# appF_synthesize_constraints/ — companion code for Appendix F

Runnable result code behind **Appendix F, "Synthesizing Constrained-Random Stimulus"** (and Chapter 4
§"Implementing the Constraint Solver") of *Emergent Hardware Verification*. Every sampler and engine here
is the exact source validated in Verilator and synthesized in Yosys.

> Want the full research record — the from-scratch derivations, the design notes, every proof-of-concept
> and negative result? That lives in **[`../synthesize_constraints/`](../synthesize_constraints/)**
> (`PAPER.md`, `JOURNEY.md`, per-example `DESIGN.md`). This directory is the curated, build-and-experiment
> version.

## The directories (in the order Chapter 4 §4.4 walks them)

| directory | what it is |
|---|---|
| `01_constraint_compiler/` | the **frontend**: parses real SystemVerilog constraints (`frontend.py`) and compiles them through a BDD (`csc.py`) to a search-free sampler. Includes the vendored riscv-dv corpus it reads (`corpus/riscv-dv/`, pinned — see `VENDORED_COMMIT.txt`). |
| `02_constructive_samplers/` | the first **Tier-0/1 constructive samplers** — a constraint compiled directly to a datapath. |
| `03_reactive_constraints/` | **reactive** constraints (config-dependent legal sets) and a Sudoku-style propagation network. |
| `04_sat_engine/` | the hard tier, runnable: a **DPLL → DPLL(T) → 1-UIP CDCL** satisfiability engine on the fabric. |
| `05_lean_certified/` | the **Lean 4** certification arc — sound/complete/uniform samplers, certified codegen, and a Lehmer allocator proved smaller and faster than the hand-written one. |
| `06_riscvdv_capstone/` | the **riscv-dv capstone** — every constraint shape synthesized and checked both directions against the reference solver, the integrated generator, the pipelined selector, and the UVM oracle. |

## Building / experimenting

Each directory has its own short `README` (and `run.sh` / `Makefile`) with the exact commands. Quick starts:

```sh
cd 05_lean_certified   && ./run.sh                 # the Lean arc, all 0 sorries
cd 04_sat_engine       && make && ./obj_dir/Vtb_dpll   # the SAT engine on the fabric
cd 06_riscvdv_capstone && cat README.md            # per-slice run instructions
```

Tools: `verilator` 5.049 (rand/constraint/randomize + UVM 1.2), `yosys` (`synth_ice40`), `nextpnr-ice40`,
`lean` 4.x. The riscv-dv corpus is vendored (pinned), so the examples build without a separate clone. The
book itself is built separately (`latexmk` at the repo root); this directory is not part of that build.
