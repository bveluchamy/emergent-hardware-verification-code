# 04_sat_engine POC(4c): pipelined BCP + the deep-search verdict

Two things, per the plan: **(1)** pipeline the DRAM-backed nogood BCP (3→1 cycle/nogood),
and **(2)** find a deep-search instance and see whether sequential BCP can be net-positive on
cycles. Book `main.tex` untouched.

---

## Part 1 — Pipelined BCP (built, validated): ~3× on the BCP portion

Two changes, both "spend abundant DRAM to buy cycles":

- **Denormalize** — store the nogood **records** directly in each literal's occurrence list
  (`occ_rec`), not IDs. One memory hop instead of two (occ→id→ngmem→record collapses to
  occ→record). A nogood sits in each of its literals' lists (~3× the DRAM — free on an emulator).
- **Pipeline** — issue the read for occurrence `i` while checking the record from `i−1`. One
  record/cycle after a 1-cycle fill.

**Measured (NV=5 instance, OCCMAX=16, apples-to-apples — same ~41 reads/sample):**

| engine | cyc/sample | reads/sample | bt/sample | legal |
|---|---|---|---|---|
| unpipelined (POC4b, `cdclt_dram`) | 154.08 | 41.5 | 0.612 | 100% |
| **pipelined (`cdclt_dram_p`)** | **72.53** | 41.8 | 0.506 | 100% |

**2.1× overall**, and ~**3× on the BCP portion** (subtract the ~30-cycle non-BCP base: 124 →
42 cyc of BCP). Sound throughout. OCCMAX is a clean **prune-vs-cost knob** (deeper per-literal
lists catch more but cost more reads):

| OCCMAX | cyc/sample | reads/sample | bt/sample |
|---|---|---|---|
| 16 | 72.5  | 42  | 0.506 |
| 32 | 108.2 | 79  | 0.253 |
| 64 | 170.4 | 142 | 0.113 |

(Pipelining is the throughput win; OCCMAX trades pruning for memory traffic.)

---

## Part 2 — The deep-search instance, and an honest negative result

A deep-search **SAT** instance exists in this family: **NV=8, DW=9, sum==40, v2*v3<20**,
all-different. With learning off (DPLL(T)):

> **311 backtracks/sample (max 3320), 1291 cycles/sample (max 13,495)** — ~270× deeper than
> the NV=5 residue, and satisfiable (all samples legal).

That is exactly the regime where backtracks are expensive — where learning *should* pay for its
BCP cost. **It does not, with decision nogoods:**

| config | backtracks/sample | cycles/sample |
|---|---|---|
| DPLL(T) (LEARN=0) | 311.2 | 1291.5 |
| CDCL(T) parallel, NGMAX=256 | 412.6 (**worse**) | 1702.1 |
| CDCL(T) parallel, NGMAX=1024 | 298.3 (−4%) | 1235.6 |
| NGMAX ≥ 4096 | — *can't even simulate* (parallel cache too large) | — |

**Why it fails — the deep-think result.** This instance's conflicts are **broad**: the global
all-different and the sum couple all 8 variables, so the conflict reason is most of the
assignment. A **decision nogood** (the negation of the whole decision prefix — here ~8 literals)
is therefore **non-minimal**: it almost never matches again, so it rarely fires and, when it
does, only perturbs the search (NGMAX=256 made it *worse*). A deeper cache barely helps (−4% at
1024) and is infeasible past that with parallel BCP. **No amount of *decision*-nogood caching
wins on a broad-conflict problem.**

**The consequence for the cycle verdict (stated plainly):** even with the 3× pipelining, the
DRAM-CDCL is **net-negative on cycles on every instance in this family** — shallow (NV=5:
learning barely helps, DPLL is already ~20 cyc) and deep-broad (NV=8: decision nogoods don't
prune). **I did not flip the verdict.** The pipelining is real and necessary, but it is *not*
the missing piece.

## What would flip it (data-motivated, not hand-waved)

1. **Minimal (first-UIP) nogoods**, via reason tracking — learn the *few* decisions actually
   responsible for the conflict, not the whole prefix. Reusable, so they fire and prune. This is
   precisely why real CDCL uses first-UIP clauses, and the NV=8 result is the measured reason.
2. **A sparse-conflict instance** — a disequality/graph-coloring structure where conflicts
   involve a *few* variables (narrow reasons), so even minimal nogoods stay short and recur.
   The global all-different here is the opposite (a clique → broad reasons).

Both are real next steps; together they are the standard recipe under which clause learning
beats plain DPLL. The DRAM **architecture** (flat area, deep cache, pipelined sequential BCP) is
the right substrate for them — what's missing is **nogood quality**, not the cache mechanism.

## Files

`cdclt_dram_p.sv` (pipelined denormalized engine), `tb_dramp.sv`, `tb_deep.sv` (generic
instance-hunting harness). Validated with verilator; the engine is single-memory + fixed-FSM, so
it inherits POC(4b)'s flat-area property (synth deferred — same structure as `cdclt_dram_syn.v`).

## Reproduce

```sh
# pipelined, apples-to-apples vs POC4b
verilator --binary -j 0 --timing -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
  --top-module tb_top -GNV=5 -GSUM=25 -GOCCMAX=16 tb_dramp.sv cdclt_dram_p.sv && ./obj_dir/Vtb_top +K=50000
# the deep instance, DPLL vs decision-nogood CDCL
verilator ... -GNV=8 -GDW=9 -GSUM=40 -GPLIMIT=20 -GLEARN=0 tb_deep.sv cdclt_solver.sv && ./obj_dir/Vtb_top +K=5000
```
