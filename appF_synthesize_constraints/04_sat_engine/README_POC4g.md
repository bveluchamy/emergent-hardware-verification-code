# 04_sat_engine POC(4g): the deployable engine — 1-UIP brain on the DRAM substrate

The arc built the two halves separately. **POC-4f** = the *brain* (true 1-UIP conflict
analysis + non-chronological backjump), which flipped the verdict but used a
parallel-combinational clause cache (free cycles, O(NG) LUTs — the POC-4 blow-up).
**POC-4b/4c** = the *substrate* (a DRAM-resident, occurrence-indexed, pipelined sequential
clause cache: flat logic, depth in memory). This composes them. Book `main.tex` untouched.

## What changed from POC-4f

The 1-UIP analysis is **unchanged**. Only how the learned clauses are *stored* and
*propagated* moves to memory:

- **Storage → memory.** POC-4f's `cl_node[NG][LMAX]`/`cl_col[NG][LMAX]` register arrays are
  replaced by `occ_rec[]`, a memory (the DRAM stand-in), with each learned 1-UIP clause
  **denormalized** into the per-literal occurrence lists indexed by `(node,colour)`.
- **BCP → pipelined sequential sweep.** POC-4f checked *every* clause *every* cycle in
  parallel combinational logic. Here a decision pinning `node=colour` triggers a **pipelined
  sweep** of only `occ[(node,colour)]` — one record/cycle, forbid-only.
- The asserting clause is applied **directly** after the backjump (`ngf[uip]`); the stored
  clause gives cross-branch pruning via the sweep. Per-sample cache clear keeps the conflict
  reasons pure (the POC-4f soundness guard).

## Result (N=64 planted 3-colouring, 500 samples, same instance)

| engine | backtracks/sample | cycles/sample | clause cache |
|---|---|---|---|
| DPLL (LEARN=0) | 92.3 (max 960) | 587.7 | — |
| POC-4f (1-UIP, **parallel** cache) | 31.2 (−66%) | 459.1 (**−22%**) | O(NG) LUTs (blows up) |
| **POC-4g (1-UIP, DRAM cache)** | **24.3 (−74%)** | 591.7 (~flat) | **in memory, flat logic** |

All proper colourings, terminating. Two readings of this:

1. **The algorithmic win survives the substrate swap — in full.** Backtracks −74% (better
   than POC-4f's −66%). The **backjump** is what cuts backtracks, and it does not care
   whether the cache is parallel logic or sequential memory.
2. **The cycle win is traded for the area win — exactly the POC-4b/4c tradeoff.** POC-4f's
   −22% cycles came from its parallel cache firing *constantly* (64,909 fires) and pruning the
   search hard. The DRAM sweep fires *sparsely* (1,022 fires — decided-literal-only,
   best-effort), so cycles go neutral (+0.7%). You buy flat logic with cycles.

## Why the DRAM form is the one that ships

- **Logic is flat in cache depth — proven by construction.** `color_uip_dram_syn.v` is a
  Verilog-2005 model of the engine, verified **bit-identical** to the SystemVerilog (same
  instance, same 23.03 backtracks/sample / 1158 learned / 231 fires / 1409 reads). In it, the
  cache-depth parameter `OCCMAX` appears in **exactly five places**: the parameter declaration,
  the `occ_rec[NLIT*OCCMAX]` **memory array**, and three address/compare expressions
  (`occ_raddr<=dlit*OCCMAX+…`, `occ_cnt<OCCMAX`). It sizes **nothing but the memory** — every
  logic element (1-UIP analysis, coloring propagation, sweep engine, FSM, registers) is
  independent of it. So the logic is flat in cache depth *for all depths*, structurally, and the
  cache scales as **memory** (BRAM → DRAM). POC-4b *measured* this exact cache substrate (LUTs
  flat 3849→3882 for a 4× deeper cache, BRAM growing); the composition adds the fixed-size 1-UIP
  analysis on top of it.

  **The absolute full-engine LUT number is not measured here**, and the reason is itself worth
  recording: yosys could not synthesize (or even *elaborate*) the engine in the available time —
  it timed out at N=64, N=16, and N=8, isolated, with long limits. The bottleneck is the
  **combinational 1-UIP analysis**: `reason_of`/`covered` scan the neighbour and domain memories
  O(N²) and are *unrolled* into one giant combinational cloud per conflict-analysis step —
  abc-hostile, and heavy even to elaborate. The flat-in-depth claim (the actual question) does
  not need that number — it is by construction. The clear engineering fix to make the *whole*
  engine synth-tractable is to **sequentialize the CA's internal scans** (the conflict analysis
  is already a multi-cycle FSM; iterating `reason_of`/`covered` over neighbours *across cycles*
  instead of one combinational blob keeps the same area while taming the combinational explosion).
  That is the next step for a clean end-to-end synth/Fmax number. **(Update — done: POC-4h
  sequentialized the CA, POC-4i moved the trail to a sequential BRAM and root-caused the real
  blocker (a `read_verilog` parse-time loop unroll at the default `N`); with a small default `N`
  the composed engine then synthesizes — N=8 → 2522 LUT + 4 BRAM, +3.4% LUT for a 4× deeper cache.
  See `README_POC4i.md`.)**
- **Cycle-neutral is fine here.** A real SoC emulates at 1–2 MHz; the stimulus solver has
  25–50× headroom (Part IV). Trading the cycle win for flat logic is the right call when DRAM
  is abundant and cycles are not the constraint — which is exactly the emulation setting.
- **Both knobs remain.** Want the cycle win back? Sweep on *every* newly-pinned literal (not
  just the decision) for denser firing, at more memory traffic — the same area↔cycle dial
  POC-4b/4c exposed.

## What this closes

> The full residue stack now exists **as one composed, deployable engine**: tier samplers
> (76–87%) → DPLL(T) for the shallow rest → and for a genuinely deep residue, **1-UIP CDCL
> whose backtrack win (−74% vs DPLL) rides a flat-logic, DRAM-resident clause cache.** Brain
> and substrate, built separately and now together.

## Files / reproduce

`color_uip_dram.sv` (the composed engine; `LEARN` selects DPLL vs 1-UIP+DRAM), `tb_uipd.sv`,
`gen5.py` → `nbr.hex`.

```sh
python3 gen5.py 150 1
V="verilator --binary -j 0 --timing -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -Wno-BLKANDNBLK --top-module tb_top"
$V -GLEARN=0 tb_uipd.sv color_uip_dram.sv && ./obj_dir/Vtb_top +K=500   # DPLL:  ~92 bt
$V -GLEARN=1 tb_uipd.sv color_uip_dram.sv && ./obj_dir/Vtb_top +K=500   # 1-UIP+DRAM: ~24 bt
```
