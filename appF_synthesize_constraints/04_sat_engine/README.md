# 04_sat_engine POC(1): synthesizable DPLL residue solver — measured

The first build of the `DESIGN.md` architecture. A finite-domain **DPLL** engine that
runs **search on the fabric** for the R3 residue, and the load-bearing measurement it was
built to produce: **cycles/sample** against the emulation budget. Book `main.tex` untouched.

## The constraint (chosen to *need* search)

```
5 variables v0..v4, each in [1,9]
all-different(v0..v4)            <- disequality web: the search driver
v0 + v1 + v2 + v3 + v4 == 25     <- LIA budget: bound propagation (the "free bulk")
v0 < v1                          <- one LIA ordering
```

Bounds/all-different propagation alone does **not** close this — it genuinely branches and
backtracks. `solve_ref.py` enumerates the exact legal set: **720 solutions** (12 distinct
5-subsets × 60 orderings), every emitted sample must be one of them.

## The engine (the `DESIGN.md` architecture, built)

- **bitset domains** (9 b/var) — all-different propagated Sudoku-style (extends `sudoku_net`)
- **LIA sum bound-propagation** reasoned over the `[min,max]` of each bitset — constant-
  coefficient datapath (coeffs are 1 here → pure add; a general `a_i` is a shift-add, *no
  general multiplier*)
- **Boolean shell**: decide (LFSR picks **both** variable and value) + trail + chronological
  backtrack; **model-finding only**, reseeded each sample
- emits one legal assignment per search; the LFSR seed *is* the replay trace

## Results

| measurement | value |
|---|---|
| **soundness** | **200,000 samples, 0 illegal** (every sample satisfies all-different ∧ sum==25 ∧ v0<v1) |
| **cycles/sample** | **mean 20.6, max 28** (clock-independent search cost) |
| **backtracks/sample** | **mean 0.31, max 4** — the search is *shallow* |
| **coverage** | **685 / 720 distinct** open-loop (95%); see the bias note |
| **substrate-identity** | SV form ≡ Verilog-2005 synth model, **bit-for-bit** (20.6 cyc, 685 distinct) |
| **fabric (iCE40 HX8K)** | **4519 logic cells (58%)**, 2867 LUT4 / ~537 DFF / 1628 carry; **Fmax ≈ 16 MHz** |

### What the numbers say

1. **DPLL alone closes this residue.** Mean **0.31** backtracks/sample, max 4 — the search
   tree is shallow, exactly the regime `DESIGN.md §8` predicted. The expensive CDCL
   machinery (clause learning, VSIDS) would never amortize here. **POC (4) is not needed for
   this class.** Measure-then-build, confirmed.
2. **It is sound by construction, and a real bug was caught.** The first build emitted two
   `9`s — a single propagation round can pin two variables to the same value via the
   sum-bound, and the all-different check in that round used the *pre-round* singletons. The
   fix is correct DPLL discipline: **emit only on a clean fixpoint** (`!changed`), so a
   duplicate surfaces as the next round's conflict. After the fix: 200k samples, 0 illegal.
3. **Substrate-identity holds for a *searching* actor**, not just a sampler. The SV class
   form and the Verilog-2005 synth model reproduce each other bit-for-bit — the same engine,
   two renderings, as the thesis requires.
4. **Coverage vs. legality, exactly as flagged.** 685/720 open-loop, and the *same* 685
   recur at both 5k and 200k samples — a deterministic orbit (the seed is the trace).
   The 35 unreached are first-solution bias of the randomized-restart labeling, not
   unsoundness. Legality is load-bearing and total; uniform coverage is the optional knob,
   closable with coverage feedback (exclude-seen — the `dist`/coverage-actor mechanism).

### Fabric area, Fmax, and the budget — honestly

4519 LC / ~16 MHz on the **smallest no-DSP iCE40**. The critical path is the **single-cycle
combinational propagation round** (all propagators + the min/max priority encoders +
range-mask comparators in one cycle). Reconciling with the budget two ways, kept separate:

- **Cycle budget (clock-independent):** the search costs **20.6 cyc/sample** vs the
  ~240-cycle reference (a 49 MHz target / 2 MHz DUT × ~10 DUT-cyc/transaction) → **~12× under
  in cycles**. This is a property of the *search depth*, and it is the headline DPLL fact.
- **Wall-clock at this part:** at the measured **16 MHz**, 20.6 cyc/sample = **~0.78 M legal
  samples/s**. A 1–2 MHz SoC DUT taking *transaction-granular* residue stimulus demands
  ≲0.1–0.2 M/s, so even unoptimized on the tiniest fabric there is **~4–8× throughput
  headroom** — the residue solver is not the bottleneck.

The gap between the ~12×-in-cycles and ~4×-in-wall-clock is entirely the 16 MHz vs 49 MHz
clock, and it is the obvious **Fmax-first lever**: **pipeline the propagation round**
(register min/max separately from the bound/mask stage), the same move that took Tier-1 from
44.8 → 97 MHz. On a real emulation FPGA (DSP blocks, fast fabric) this 16 MHz floor lifts
substantially on its own. Fmax optimization is deferred — POC (1)'s job was the cycles/sample
number, and that is in.

## What this decides downstream

- **POC (3) is the next headline**: wire a **Tier-2 divider in as a nonlinear theory
  propagator** (`A*B<LIMIT ∧ linear bounds`) — DPLL(**T**), Bryant honored, certified `(T)`.
- **POC (4) (CDCL learning) stays deferred** — this residue is shallow; learning has nothing
  to amortize. It returns only if a residue shows recurring deep conflicts.
- A clean **Fmax pass** (pipeline the propagation round) is the one engineering follow-up if
  the wall-clock margin ever needs to be the full 12×.

## Reproduce

```sh
./run.sh                 # ref set + SV sim + substrate-identity + iCE40 area/Fmax
K=5000 ./run.sh          # shorter sample count
python3 solve_ref.py     # the exact 720-solution reference
```

Files: `dpll_solver.sv` (the engine), `dpll_solver_syn.v` (bit-identical Verilog-2005 synth
model), `tb_dpll.sv` (self-checking measurement harness), `solve_ref.py` (exact reference),
`synth.ys` (yosys script), `DESIGN.md` (the architecture this builds).
