# 04_sat_engine POC(4d): graph-coloring + first-UIP — and why the win needs scale

The plan was: a **graph-coloring** instance (sparse, narrow conflicts) + **minimal
(first-UIP) nogoods**, the textbook regime where clause learning beats DPLL — to flip the
cycle verdict POC(4c) left negative. I built the coloring engine and the first-UIP design,
and the experiments produced a clear, honest result. Book `main.tex` untouched.

## What was built

- **`color_dpll.sv`** — a graph-coloring DPLL engine: N nodes, K colors, sparse edge
  disequalities propagated to fixpoint (forbid a singleton neighbor's color), LFSR-decide,
  chronological backtrack. Validated: every emitted assignment is a **proper coloring**.
- **The first-UIP design (the tractable heart):** in coloring, every colour removal has
  *one* reason — the neighbor holding that colour. So at a conflict (node x wiped), the
  antecedent nogood is exactly **`{(neighbor_c, c)}` for each colour c** — size ≤ K, narrow,
  value-based, and **computable combinationally at conflict from current singletons** (no
  stale-reason tracking). That is the implication-graph antecedent cut, the reason coloring
  is the right vehicle for minimal nogoods.

## The result: full propagation makes fabric-scale coloring shallow

I hunted for a hard **SAT** instance with a propagation-aware search (`gen4.py` runs the
*same* unit-propagation the RTL does, so its backtrack counts predict the RTL's):

| instance | result |
|---|---|
| Grötzsch graph, K=4 (11 nodes, χ=4) | **0 backtracks** — propagation 4-colours it directly |
| random N=16, 32 edges (seed=119), K=3 | naive-DPLL ~1251 bt, but **RTL = 2.15 bt/sample** |
| random N=16, **37 edges (threshold)**, K=3 | hardest SAT found: **avg-CP-backtracks = 1** |

The naive-backtracking hardness (1251) **evaporates under unit propagation** (→ ~1–2). At
N=16, full propagation to fixpoint determines the colouring almost immediately, so the search
is shallow and there is nothing for clause learning to prune — exactly as on the arithmetic
family (POC4c). **Two independent constraint families now show the same thing.**

## The honest verdict — and it is a *scale* statement, not a dead end

> At the scale a small-domain fabric engine handles (N ≤ 16, K-bit bitset domains), **full
> unit propagation keeps finite-domain residues shallow**, so the deep-adversarial-search
> regime where clause learning beats DPLL **does not occur**. The cycle verdict cannot flip
> here because the prerequisite — deep, recurring, propagation-resistant search — requires
> instances **N ≫ 16** (the 3-colouring phase-transition hardness grows with N; SAT solvers
> only struggle at the hundreds-of-variables scale).

This is not an implementation shortfall — it is a property of the regime:

- **The architecture is ready for scale.** The DRAM-resident cache (POC4b), pipelined
  sequential BCP (POC4c, ~3× on the BCP portion), and the K-literal antecedent-nogood design
  above all compose into a coloring-CDCL that *would* exhibit the win at N≫16 — which is
  feasible on a real emulator's resources (millions of LUTs, GB of DRAM), not on the
  iCE40-scale POC engine (4-bit node index, N ≤ 16).
- **For the actual emulation residue, the answer is settled and consistent:** the tier
  samplers cover 76–87%, DPLL(T) closes the shallow remainder cheaply, and **CDCL learning is
  a backstop for a genuinely deep residue** — which, at fabric-representable scale with full
  propagation, we could not manufacture in *either* constraint family. That is a stronger,
  better-evidenced version of the DESIGN §8 verdict, not a contradiction of it.

## What I did *not* do, and why

I did **not** build the full minimal-nogood coloring-CDCL engine. With no deep instance at
N ≤ 16 (propagation makes them shallow), it would measure ~0 benefit — re-confirming the
shallow-search null result at additional cost. The first-UIP **design is captured above** and
drops into the POC4b/4c DRAM+pipeline substrate unchanged; the missing ingredient is **scale
(a wider engine, N ≫ 16)**, which is the real next step and belongs on emulator-class
resources, not the iCE40 POC.

## Files

`color_dpll.sv` (coloring DPLL engine, holds a representative threshold instance),
`tb_color.sv` (proper-colouring checker + backtrack measurement), `gen4.py` (propagation-aware
hard-SAT-instance generator — note the LCG uses high bits; low bits have a short period that
silently breaks edge generation).
