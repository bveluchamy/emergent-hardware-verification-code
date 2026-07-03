# 04_sat_engine POC(4e): the wide engine — reaching the deep-search regime, and the irreducible role of first-UIP

POC(4d) showed that at fabric scale (N≤16) full propagation keeps coloring shallow, so the
learning-beats-DPLL regime needs N≫16. This is that experiment: a **wide engine (N=64)** on
**planted** 3-colouring instances (SAT by construction), to finally reach deep search and try
the flip. Book `main.tex` untouched. (Sim experiment; the wide engine targets emulator-class
resources, not the iCE40 part.)

## We reached the regime

`color_wide.sv` (N=64, K=3, adjacency via `$readmemh` so density sweeps need no rebuild) on a
planted threshold instance (`gen5.py 150 1`: 64 nodes, 150 edges, avg degree 4.69, SAT):

> **DPLL: 78.6 backtracks/sample (max 960), 515 cycles/sample** — all proper colorings.

That is genuinely deep search (vs ~2 at N=16) **even with full unit propagation** — the
regime where clause learning is supposed to win. The N≫16 prediction from POC(4d) holds.

## The flip attempt — and a conclusive negative that explains *why CDCL is built the way it is*

Same instance, four configurations:

| configuration | backtracks/sample | cycles/sample | outcome |
|---|---|---|---|
| **DPLL** (LEARN=0, BJUMP=0) | 78.6 | 515 | baseline |
| **clause-BCP, chronological** (LEARN=1) | 75.6 (−4%) | 956 (+85%) | BCP cost ≫ savings |
| **backjump-to-max** (BJUMP, jump to deepest reason) | 78.6 | 515 | **no effect** |
| **antecedent clause + backjump-to-2nd-highest** | — | — | **thrashes / loops** (can't finish 20 samples) |

Each simpler variant fails, and each failure names the missing piece:

1. **Clause-BCP with chronological backtrack barely helps.** The antecedent nogoods (the ≤K
   neighbours that wiped node x) are narrow but the *sequential BCP cost* (reads/sample)
   exceeds the ~4% backtracks they save. Learning's BCP is **not** the lever.
2. **Backjump-to-max has no effect.** The conflict is detected right after the current
   decision, so the *deepest* reason is always the current level — jumping "to the deepest
   reason" is a no-op. The real CDCL target is the **second-highest** level.
3. **Antecedent clause + backjump-to-2nd-highest *loops*.** This is the crux. Jumping to the
   second-highest level undoes the current decision — but the **antecedent clause is not
   *asserting*** (it can contain several current-level literals), so after the jump the search
   simply **re-derives the same conflict and loops.** It cannot finish even 20 samples.

## What this *means* — first-UIP is load-bearing, not an optimization

A **first-UIP (1-UIP)** clause has, by construction, **exactly one literal at the current
decision level** (the unique implication point). That single property is what makes
backjump-to-second-highest *work*: after the jump, the clause is **unit** on that one literal,
so BCP immediately **forces it to flip** — the search makes guaranteed progress instead of
re-deriving the conflict. The thrashing above is precisely what happens *without* 1-UIP. So the
hardware experiment is an empirical proof of why every real CDCL solver computes 1-UIP:

> **Non-chronological backjump is sound and terminating only with an *asserting* (1-UIP)
> learned clause.** Clause learning and backjumping are not separable features — the UIP is the
> bridge that makes them work together.

## Honest verdict on the flip

**Reached the deep-search regime; did not flip the cycle verdict.** The flip requires the *full*
first-UIP CDCL, and the irreducible remaining work is **true 1-UIP conflict analysis in
hardware** — backward resolution over the implication graph (per-assignment reason storage +
a resolution loop that resolves until one current-level literal remains). That is a major,
correctness-sensitive FSM, and it belongs on emulator-class resources where the wide engine
itself lives. The antecedent (one-step) cut is a tempting shortcut that **provably loops**;
there is no cheaper substitute for 1-UIP.

## The whole CDCL line, concluded

Across arithmetic (4c) and coloring (4d/4e), at fabric-representable scale: the tier samplers
cover 76–87%, **DPLL(T) closes the shallow remainder cheaply**, and **CDCL learning is a
deep-residue backstop** whose *correct* hardware form requires 1-UIP conflict analysis — now
precisely localized as the single remaining mechanism, with hardware evidence that every weaker
variant (clause-BCP-only, backjump-without-1-UIP) fails. The DRAM cache (4b) and pipelined BCP
(4c) are the right *substrate*; 1-UIP is the missing *brain*. For the actual emulation residue
the question is settled (tiers + DPLL(T)); the wide first-UIP engine is open research, not a
needed step.

## Files

`color_wide.sv` (N=64 engine; `LEARN`/`BJUMP` params expose the four configurations above —
note LEARN+BJUMP together thrashes by design, the documented finding), `tb_wide.sv`,
`gen5.py` (planted-instance generator → `nbr.hex`), `nbr.hex` (the committed N=64 instance).

## Reproduce

```sh
python3 gen5.py 150 1                 # regenerate nbr.hex (planted, SAT)
V="verilator --binary -j 0 --timing -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT --top-module tb_top"
$V -GLEARN=0 -GBJUMP=0 tb_wide.sv color_wide.sv && ./obj_dir/Vtb_top +K=300   # DPLL: deep search
# LEARN=1/BJUMP=1 (full antecedent CDCL) thrashes -- the first-UIP finding
```
