# 05_lean_certified / L1: a proved step bound for the POC-1 residue solver

`lean/Bound.lean` — pure Lean 4 core (no Mathlib), checks standalone:
`lean Bound.lean` (exit 0, **0 sorries**; axioms = `propext`, `Quot.sound` only — *not*
`Classical.choice`, so the proofs are constructive). Book `main.tex` untouched.

## What it proves, and why it matters

04_sat_engine POC-1 **measured** 20.6 cycles/sample (max 28); because that was an observation,
DESIGN.md §6/§7 had to add a cycle-budget **watchdog + host-fallback seam**. L1 starts
converting the observation into a theorem.

**The modeling move.** Chronological backtracking — "for each value in this variable's
domain, recurse on the remaining variables" — is **structural recursion on the variable
list**. So Lean accepts it as terminating *with no well-founded measure*, and that very
structurality is the synthesizability fact: a structurally-recursive search **unrolls to a
bounded circuit**. We never prove a ∀-theorem about a solver; we *bound a construction* —
the model-finding half (see `DESIGN.md` §0).

| theorem | statement | meaning |
|---|---|---|
| `searchNodes_le` | every domain ≤ B ⇒ nodes ≤ `gsum B NV` = 1+B+···+Bᴺⱽ | **bounded ⇒ synthesizable** (the gate) |
| `allDiff_bounded` | all-different per-level shrink ⇒ every domain ≤ DW | the propagation invariant |
| `leaves_ffact_le` | under all-different, leaves ≤ DW·(DW−1)···(DW−NV+1) | the **falling-factorial** improvement |

Concrete for POC-1 (NV=5, DW=9), all `#eval`-computed in the file:

| bound | value | vs the ~240-cycle budget |
|---|---|---|
| generic `gsum 9 5` | **66430** | the gate: proves bounded/synthesizable, loose |
| all-different `ffact 9 5` = 9·8·7·6·5 | **15120** | propagation tightens it ~4×, still ≫ budget |
| **measured** (04_sat_engine) | ≈1.3 leaves (0.31 backtracks) | the true tree is tiny |

## The honest gap (where the prover earns its keep)

Both proved bounds are ≫ 240; the measured tree is ~1.3 leaves. The gap is **propagation
strength**: sum==25 and v0<v1, conjoined with all-different, make bounds-propagation nearly
complete, collapsing the tree. Closing L1 to a *guaranteed* ≤ budget needs a
**propagation-completeness lemma** for the conjunction (stated in the file as `BudgetGap`,
OPEN):

> ∀ partial assignment consistent with (allDifferent ∧ sum==S ∧ v0<v1), bounds-propagation
> leaves each free domain of size ≤ c, for small c.

That is a theorem about the *constraint*, not the engine — the kind of deep reasoning a
dependent-type prover supplies and a hand bound cannot. `searchNodes_le` + `leaves_ffact_le`
are the proved floor it stands on. This is the L1 frontier; the arc continues at L2 (the
constructive sampler) per `DESIGN.md`.

## Reproduce

```sh
export PATH=$HOME/.elan/bin:$PATH
cd 05_lean_certified/lean && lean Bound.lean    # exit 0, prints 66430 / 15120 / 16 / 6
```
