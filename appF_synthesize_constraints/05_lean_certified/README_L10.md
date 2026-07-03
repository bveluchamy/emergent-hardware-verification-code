# 05_lean_certified / L10: the sub-linear storage win, demonstrated (count-DAG)

`lean/CompressedDAG.lean` — pure Lean 4 core, `lean CompressedDAG.lean` (exit 0, **0 sorries**;
the DAG-unrank-reproduces-enumeration checks are `native_decide`). Book `main.tex` untouched.

## What it closes (L8's storage frontier)

L8 certified the count-annotated unrank *walk*, but a tree with N leaves still has ≥N nodes — real
compression needs **DAG sharing**. L10 demonstrates it.

**The structural fact (why subtrees merge).** Under all-different, the set of legal completions
from a prefix depends *only on the set of values already used* — not their order or positions. So
every prefix with the same used-set has the **same completion subtree** ⇒ one shared DAG node per
used-set (a `Nat` bitmask). The number of distinct used-sets is `2^D`; the number of legal
assignments (leaves) is the falling factorial. So:

```
DAG nodes = 2^D     ≪     leaves = D·(D-1)···(D-NV+1)
```

Measured (`#eval`, all-different permutations of [0,D)):

| D=NV | DAG nodes (2^D) | permutations (D!) | storage |
|---|---|---|---|
| 6 | **64** | 720 | 8.9% |
| 7 | **128** | 5040 | 2.5% |
| 8 | **256** | 40320 | **0.63%** |
| 10 (projection) | 1024 | 3 628 800 | **0.028%** |

The compression **improves with scale** (2^D grows far slower than D!), so this is the bridge
toward the emulator-scale regime L5's flat ROM could not reach. The count-walk over the shared DAG
is L8's `cget`, unchanged — and `native_decide` confirms the DAG unrank reproduces the flat
enumeration exactly (D=4,5) and that every emitted assignment is a genuine permutation.

## Proved / demonstrated / frontier — stated sharply

- **Proved (L8):** the count-walk returns the R-th solution (`cget_eq`).
- **Demonstrated (L10):** the shared DAG has `2^D` nodes for `D!` leaves (measured), and its unrank
  reproduces the enumeration (`native_decide` on D=4,5). The *storage win is real and measured.*
- **L12 closes one half:** the general (non-`native_decide`) proof that the shared-DAG walk equals
  the enumeration *for all D* is now done — `unrankP_eq`/`dag_unrank_correct` (see `README_L12.md`).
- **Frontier (sole remaining):** **canonicity** — a formal proof that this shared DAG is *the*
  minimal/canonical reduced form (the reduced-BDD uniqueness theorem). A real theorem needing the
  ROBDD (Finset/Fintype-level) framework, stated honestly as the remaining multi-session research,
  in the spirit of the 04_sat_engine negatives.

## Reproduce

```sh
export PATH=$HOME/.elan/bin:$PATH
cd 05_lean_certified/lean && lean CompressedDAG.lean   # prints 64/720, 128/5040, 256/40320
```
