# 04_sat_engine POC(3)+(4): DPLL(T) and CDCL(T) — measured

Extends POC(1)'s DPLL engine (see `README.md`) with the two pieces the residue solver
needs to be a real lazy-SMT model-finder: **(3)** a Tier-2 nonlinear *theory* propagator,
and **(4)** conflict-driven clause (nogood) **learning** — the CDCL of Chapter 3, kept to
**model-finding** (no refutation). Book `main.tex` untouched.

---

## POC(3): DPLL(T) — the Tier-2 theory propagator

Constraint gains a genuinely nonlinear term:

```
5 vars in [1,9], all-different, sum==25, v0<v1,  AND  v2 * v3 < 20
```

The multiply **never becomes Boolean clauses** (Bryant 1991: no poly-size BDD for a
multiplier bit). It stays an opaque theory atom whose propagator is the **inverse**:
`v3_max = floor((PLIMIT-1) / v2_min)` — *invert, don't bit-blast*. For `[1,9]` the division
is a 9-entry **compile-time table** (solving is compile-time); for large domains the
03_reactive_constraints pipelined divider is the identical drop-in. The multiplier is only the checker;
its inverse (the divider) is the generator.

**Result** (`dpllt_solver.sv`, 200,000 samples): **all legal incl. the nonlinear
`v2*v3<20`** — the Tier-2 `(T)` is sound, never bit-blasted. 360 legal solutions (the
product removed half of POC(1)'s 720), 358 covered. **cycles/sample 22.8, backtracks 1.15**
(up from POC(1)'s 0.31 — the nonlinear coupling adds real search, max 26 backtracks).

---

## POC(4): CDCL(T) — conflict nogood learning, model-finding only

On each conflict, learn a **nogood** = negation of the current decision set
`¬(v_a==x ∧ v_b==y ∧ …)`. Because our constraints are **static**, every nogood is
**globally valid**, so the cache is **run-warmed** and persists across samples. Learned
nogoods do **unit propagation** (BCP on learned clauses); backtrack stays **chronological**
so completeness is guaranteed by the underlying search. The cache is **bounded** (FIFO
eviction) — sound because correctness rests on the search, not on retaining a refutation.

**The simplification you asked for, made precise:** model-finding needs no UNSAT proof, so
there is **no proof logging, no clause-minimality, no unbounded DB** — exactly the
refutation machinery that makes a proof-producing solver hard is dropped. A satisfiable
instance always yields a model; an unsatisfiable *live state* would be **withhold**, not a
solver event.

`LEARN` is a build knob, so the same instance measures DPLL(T) vs CDCL(T):

| cache (NGMAX) | backtracks/sample | cycles/sample | worst case (max cyc) |
|---|---|---|---|
| **LEARN=0** (DPLL(T)) | 1.145 | 22.80 | 105 |
| 16  | 0.956 (−16%) | 22.10 | 111 |
| 64  | 0.590 (−48%) | 20.62 | 93 |
| **256** | **0.200 (−83%)** | **19.01 (−17%)** | **66 (−37%)** |

(A second instance, `v2*v3<12`, behaves the same: NGMAX=256 → backtracks −85%, cycles −17%.)

**Findings:**

1. **Learning works on the fabric** — sound (200k legal), complete (coverage maintained, no
   false UNSAT), and **actively pruning** (at NGMAX=16: 180,966 nogoods learned, 384,572 BCP
   fires). With a deep-enough cache it cuts backtracks **83%**, mean cycles **17%**, and the
   **worst-case tail 37%**.
2. **Cache size is the lever.** At NGMAX=16, 180,966 nogoods churn through 16 slots
   (~11,000× eviction) → most are evicted before reuse → modest win. Deepening the cache
   recovers the benefit. This *is* DESIGN's "learned-clause DB → emulator DRAM," measured.
3. **This refines, not contradicts, the POC(1) shallow-search finding.** Even on shallow
   search, learning helps *a lot* with a deep cache — because the nogoods are **static**
   (run-warmed), so the amortization horizon is the **whole emulation run**, not one solve.
   That is exactly the "incremental SAT under assumptions, compile-warmable cache" prediction
   in `DESIGN.md §8`.

---

## The honest catch: area cost of learning

Synthesized on iCE40 HX8K (yosys), via the bit-identical `cdclt_syn.v`:

| config | SB_LUT4 | vs DPLL(T) |
|---|---|---|
| **LEARN=0** (DPLL(T)+Tier-2) | **2466** | — |
| **LEARN=1, NGMAX=16** | **9350** | **+6884 (3.8×)** |
| **LEARN=1, NGMAX=64** | **29855** | **+27389 (12×)** |

Learning as implemented — **parallel combinational nogood-BCP** (NGMAX×NV onehot
comparators + variable-index forbid-accumulation) — costs **~430 LUT per cached nogood**, so
it grows **linearly with cache depth**: 2466 base + 16 entries → 9350, + 64 entries → 29,855
(already **~4× the 7680-LUT part**). The *deep* cache that gave the 83% win is exactly where
this is most ruinous — which is why POC(4b) moves the cache to DRAM, where the logic stays
**flat** (~3900 LUT) and depth costs BRAM instead. This is precisely **why DESIGN puts the learned-clause DB in emulator DRAM with
*sequential* BCP** — trading area for cycles, which the 25–50× headroom affords. The
parallel-comb POC proves the **algorithm and the win**; the **DRAM form is the deployable
one.** So POC(4) doesn't just demonstrate CDCL on the fabric — it **measures the cost of the
naive (logic) form** and thereby substantiates the DRAM recommendation.

**Substrate-identity:** the Verilog-2005 `cdclt_syn.v` reproduces the SV `cdclt_solver.sv`
bit-for-bit (LEARN=1/NGMAX=16: 22.10 cyc, 0.956 bt, 180,966 learned, 384,572 fires).

---

## What POC(3)+(4) decide

- **DPLL(T) is real**: the Tier-2 inverse propagator integrates into the search loop, honors
  Bryant (no bit-blast), and stays sound — a synthesizable lazy-SMT theory solver.
- **CDCL(T) is real and measured**: learning is sound + complete and cuts backtracks up to
  83% — but its value is gated by **cache depth**, which belongs in **DRAM**, not LUTs.
  Revised verdict vs DESIGN §8: CDCL learning is **not "never worth it"** — it is **worth it
  where cache memory exists** (an emulator's DRAM), with a now-quantified area/cycle tradeoff.
- The **model-finding framing holds end to end**: sound learned clauses, bounded cache,
  UNSAT = withhold, no refutation machinery — the easy half of SMT, on the fabric.

## Reproduce

```sh
./run_cdcl.sh        # POC(3) run + POC(4) cache sweep + substrate-identity + area
python3 solve_ref_t.py 20
```

Files: `dpllt_solver.sv` (POC3), `cdclt_solver.sv` (POC4, `LEARN`/`NGMAX` params),
`cdclt_syn.v` (Verilog-2005 synth model), `tb_dpllt.sv` / `tb_cdclt.sv`, `solve_ref_t.py`.
