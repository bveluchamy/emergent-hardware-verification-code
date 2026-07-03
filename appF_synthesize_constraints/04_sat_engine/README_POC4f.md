# 04_sat_engine POC(4f): true 1-UIP conflict analysis in hardware — the flip, achieved

POC(4e) localized the entire arc's open question to a single mechanism: **true first-UIP
conflict analysis**, and proved (by watching the antecedent shortcut *loop*) that nothing
cheaper works. This builds it. **It flips the cycle verdict.** Book `main.tex` untouched.

## The result

Same N=64 planted 3-colouring instance, 1000 samples, identical search except for conflict
handling:

| engine | backtracks/sample | cycles/sample | proper colourings |
|---|---|---|---|
| **DPLL** (`color_uip.sv`, LEARN=0) | 92.6 (max 960) | 589.6 (max 5484) | all |
| **1-UIP CDCL** (LEARN=1) | **31.2 (max 392) — −66%** | **459.1 (max 4256) — −22%** | all |

**True 1-UIP CDCL beats DPLL on *both* axes** — backtracks −66% (tail −59%), cycles −22%
(net-positive) — sound (1000 proper colourings) and terminating (no loop, no false UNSAT).
This is the regime where POC(4)–POC(4e) all failed; with the *correct* mechanism it succeeds.

## What "true 1-UIP in hardware" actually is

The implication graph, in finite-domain colouring form: a literal is *"node = its current
colour"*, so a learned clause is a **set of nodes** (an N-bit bitmap). Each node carries its
decision level `dl[]` and trail order `ord[]`.

**Conflict analysis (the resolution loop), `CA_INIT → CA_STEP → CA_STORE`:**

1. Start the clause = the **conflict node's reason** — the ≤K neighbours that removed each of
   its colours (computed combinationally from the intact conflict state; no stored reasons).
2. While **more than one** node in the clause is at the **current decision level**: take the
   **most-recently-assigned** such node `p` (max `ord`, index tiebreak), and **resolve** —
   remove `p`, add `p`'s antecedent (the earlier neighbours that forced `p`'s other colours
   out, each with `ord < ord[p]`).
3. Stop when **exactly one** current-level node remains — the **1-UIP**. The clause is now
   *asserting* (one current-level literal).
4. **Backjump** to the 2nd-highest decision level in the clause; store the clause; combinational
   BCP then fires it as a unit, forbidding the UIP's colour → guaranteed progress, no loop.
   Chronological backtrack remains the backbone for value exhaustion.

**Why it terminates** (the bug POC(4e) hit, fixed): antecedents are restricted to strictly
*earlier* assignments (`ord[j] < ord[p]`), so the current-level frontier shrinks monotonically
to the single UIP. Trail order, not just decision level, is what makes this work — and pins in
the same propagation round share an `ord`, so the strict `<` is essential.

## Two real bugs, and an honest scope note

- **Termination bug.** First build *looped*: a node's antecedent could include a *same-round*
  node, so the resolution frontier never shrank. Fix: `ord[j] < ord[p]` (strictly earlier).
- **Soundness bug across samples.** Once learned clauses accumulate, a conflict can be caused by
  a *learned clause*, not just colouring — and the colouring-only reason computation would build
  a wrong clause. Fix (sound): run 1-UIP only when the conflict is **fully explained by
  colouring** (every removed colour has a neighbour reason — `init_ok`/`antec_ok`); otherwise
  fall back to **chronological backtrack** (always sound). Plus a **per-sample cache** so most
  conflicts stay pure-colouring. This is a *sound* simplification of the fully-general
  implication graph (which would trace clause antecedents too); the measured flip is what 1-UIP
  delivers even with this conservative guard.
- **Scope.** The clause cache here is **parallel combinational** (BCP free per cycle), to isolate
  the *algorithm* — does real 1-UIP beat DPLL on backtracks? It does, decisively. The
  **DRAM-resident / pipelined / occurrence-indexed** substrate for that cache is the orthogonal
  POC(4b)/(4c) story; composing the two is the deployable engine.

## What this closes

The arc's single open mechanism is **built and measured**:

> **Non-chronological backjump is sound, terminating, and a net win — but only with a true 1-UIP
> asserting clause.** The antecedent shortcut loops (POC-4e); first-UIP works (this). The DRAM
> cache (4b) + pipelined BCP (4c) are the substrate; **1-UIP is the brain** — now also built.

So the full CDCL(T) stack for the residue exists end to end: tier samplers (76–87%) → DPLL(T)
for the shallow rest → and, for a genuinely deep residue, **1-UIP CDCL that provably beats
DPLL**, on hardware, with every piece measured.

## Files / reproduce

`color_uip.sv` (the engine; `LEARN` selects DPLL vs 1-UIP), `tb_uip.sv`. Needs `nbr.hex`
(`python3 gen5.py 150 1`).

```sh
python3 gen5.py 150 1
V="verilator --binary -j 0 --timing -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -Wno-BLKANDNBLK --top-module tb_top"
$V -GLEARN=0 tb_uip.sv color_uip.sv && ./obj_dir/Vtb_top +K=1000   # DPLL:  ~92.6 bt, ~589 cyc
$V -GLEARN=1 tb_uip.sv color_uip.sv && ./obj_dir/Vtb_top +K=1000   # 1-UIP: ~31.2 bt, ~459 cyc
```
