# Appendix F — A SAT engine on the fabric (the hard tier)

Companion code for Appendix F, "Synthesizing Constrained-Random Stimulus." Most
constrained-random stimulus can be produced by *direct construction* — a sampler that
builds a legal value with no search (the soft tiers, in the other Appendix F
directories). A few constraints genuinely need a search: an all-different web plus a sum
budget, a dense graph colouring near its threshold. This directory is the **hard tier** —
a satisfiability engine, **DPLL → DPLL(T) → 1-UIP CDCL**, written as ordinary synthesizable
RTL so the search runs *on the same fabric as the design under test*. That is the point the
appendix makes here: even when a constraint needs a solver, the method never quietly hands
off to a software solver on the host. The solver is hardware too.

## The two instances (chosen to *need* search)

Propagation alone closes neither — both genuinely branch and backtrack.

- **Residue** (`dpll_solver.sv` and up): five variables `v0..v4`, each in `[1,9]`,
  `all-different`, `v0+v1+v2+v3+v4 == 25`, `v0 < v1`. `solve_ref.py` enumerates the exact
  legal set (720 assignments) so every emitted sample can be cross-checked. The `dpllt` /
  `cdclt` engines add one *nonlinear* atom, `v2*v3 < PLIMIT` (`solve_ref_t.py` is its
  reference).
- **Colouring** (`color_*.sv`): a 64-node graph, 3 colours, generated dense and planted-SAT
  near the 3-colouring threshold (`gen5.py` writes the adjacency into `nbr.hex`). At this
  density the search is deep even with full unit propagation — the regime where clause
  learning earns its keep.

## The engines — one synthesizable FSM each

| file | engine | what it adds |
|---|---|---|
| `dpll_solver.sv` | **DPLL** | bitset domains; all-different + LIA sum bound-propagation to a fixpoint; a Boolean shell (LFSR decision, trail, chronological backtrack). Model-finding only — it emits one legal assignment per search and reseeds; the 16-bit LFSR seed *is* the replay trace. |
| `dpllt_solver.sv` | **DPLL(T)** | a nonlinear theory atom `v2*v3 < PLIMIT`, propagated by its *inverse* (a compile-time division table) instead of bit-blasted into Boolean clauses — "invert, don't bit-blast." The multiplier is only the checker; its inverse is the generator. |
| `cdclt_solver.sv` | **CDCL(T)** | conflict-driven clause learning: each conflict records a *nogood* (the negation of the current decision set) that then does unit propagation on later branches. `LEARN=0` reduces it to plain DPLL(T) on the same instance. Backtracking stays chronological, so completeness comes from the search, not the learned database. |
| `color_uip.sv` | **1-UIP CDCL** | true first-UIP conflict analysis — resolve back along the implication graph to the unique implication point — plus non-chronological backjump to the asserting level. `LEARN=0` is the plain-DPLL baseline on the same graph. |

`color_dpll.sv` (a small triangle-free instance) and `color_wide.sv` (the 64-node graph)
are the DPLL baselines the 1-UIP engine is compared against.

## Where the learned clauses live — gates, then DRAM

A learned-clause store is the one part that does not want to be logic. `cdclt_solver.sv`
and `color_uip.sv` keep the cache in registers and check every nogood in parallel
combinational logic each cycle: free per cycle, but the area grows with the cache depth,
so a deep cache will not fit. An emulator has the opposite resource — abundant, under-used
memory. `cdclt_dram.sv` and `color_uip_dram.sv` move the store into memory and make BCP
*sequential and indexed*: a per-literal occurrence list means a decision walks only the
handful of nogoods that mention the literal it just pinned, read from memory over a bounded
number of cycles. Area moves off the LUTs (which were exploding) onto memory bits (flat and
cheap), so the cache can be deep. `cdclt_dram_p.sv` pipelines that sweep to one record per
cycle. The store only prunes — the underlying search is complete — so a late or evicted
nogood costs search effort, never a wrong answer.

## Same source, two renderings

Each residue engine ships with a Verilog-2005 twin (`dpll_solver_syn.v`, `cdclt_syn.v`,
`cdclt_dram_syn.v`) — the *same* engine expressed for a plain synthesis flow. `run.sh` runs
the SystemVerilog form and the Verilog form and checks they reproduce each other bit-for-bit,
then pushes the Verilog through yosys + nextpnr-ice40 for iCE40 HX8K area and Fmax. One
authored engine, one behaviour, whether it renders as a simulation class or as gates on the
fabric — the appendix's substrate point, applied to a *searching* engine.

## Running

Requires `verilator` (5.x). `run.sh` / `run_cdcl.sh` also use `yosys` and `nextpnr-ice40`
for the area / Fmax steps (skipped cleanly if absent). The colouring sims read `nbr.hex`,
so run them from this directory. Every harness has top module `tb_top` and takes
`+K=<samples>`.

```sh
./run.sh                 # DPLL residue: reference set, sim, SV=Verilog check, iCE40 area/Fmax
K=5000 ./run.sh          # the same, fewer samples

./run_cdcl.sh            # DPLL(T) + CDCL(T): learning on/off, nogood-cache sweep, area of learning

# the engines without a wrapper script (same flags the scripts use):
VF="--binary -j 0 --timing -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --top-module tb_top"
verilator $VF tb_uip.sv  color_uip.sv  && ./obj_dir/Vtb_top +K=300      # 1-UIP CDCL colouring (-GLEARN=0 = DPLL baseline)
verilator $VF tb_dram.sv cdclt_dram.sv && ./obj_dir/Vtb_top +K=200000  # DRAM-backed nogood cache
```

Each harness asserts that *every* emitted sample satisfies all constraints (an illegal
sample aborts the run) and reports cycles/sample, backtracks/sample, and the distinct-
solution count. The legality check is the key correctness property: the engine is a
model-finder, so a satisfiable instance always yields a legal assignment, and an
unsatisfiable state would be "withhold," never a wrong sample.

## What to read

- The four solver files in order — `dpll_solver.sv`, `dpllt_solver.sv`, `cdclt_solver.sv`,
  `color_uip.sv` — are the escalation from propagation, to theory propagation without
  bit-blasting, to clause learning, to real 1-UIP analysis with backjump, each a
  self-contained synthesizable FSM.
- `cdclt_dram.sv` / `color_uip_dram.sv` next to their register-cache siblings show *where*
  a learned-clause store belongs on an emulator: in memory, reached by a bounded sequential
  sweep, not in a wall of LUTs.
- The `*_syn.v` twins and `run.sh`'s iCE40 pass show the same authored engine landing on
  gates.
