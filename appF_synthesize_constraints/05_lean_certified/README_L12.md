# 05_lean_certified / L12: the DAG unrank is correct for all D (general proof)

`lean/CompressedDAGProof.lean` (imports L10 `CompressedDAG`). `LEAN_PATH=. lean
CompressedDAGProof.lean` after `lean -o CompressedDAG.olean CompressedDAG.lean` (exit 0, **0
sorries**; propext/Quot.sound). Book `main.tex` untouched.

## What it upgrades

L10 *measured* the storage win (2^D nodes / D! leaves) and `native_decide`-validated the DAG
unrank on D=4,5. L12 turns that validation into a **theorem for all D**:

```lean
theorem unrankP_eq : R < cntP D used rem → (perms D used rem)[R]? = some (unrankP D used rem R)
```

The count-walk over the shared used-set-keyed DAG returns **exactly the R-th completion**, for
every D, used, rem, R — L8's correctness, now over the `flatMap`-structured enumeration L10
shares. Proved by mutual induction (`unrankP_eq` with `pickV_eq`) plus the count recurrence
`cnt_rec : cntP D used (rem+1) = Σ children`, using the core `getElem?_append_{left,right}`,
`getElem?_map`, and `length_flatMap` lemmas — the same shape as L8's tree proof, lifted to the
shared DAG.

## Frontier, now narrowed to one item

L10 left two open pieces; **L12 closes the second** (the general array-walk = enumeration proof).
The remaining frontier is a single hard theorem: **reduced-BDD canonicity** — that L10's shared
DAG is *the* minimal/canonical reduced form (uniqueness up to the variable order). That needs the
reduced-ordered-BDD framework (Finset/Fintype-level machinery) and is the genuine multi-session
research item, stated honestly rather than forced.

## Reproduce

```sh
export PATH=$HOME/.elan/bin:$PATH
cd 05_lean_certified/lean
lean -o CompressedDAG.olean CompressedDAG.lean && LEAN_PATH=. lean CompressedDAGProof.lean   # exit 0
```
