# 05_lean_certified / L8: the certified count-annotated unrank (BDD-unrank, proved)

`lean/Compressed.lean` — pure Lean 4 core, `lean Compressed.lean` (exit 0, **0 sorries**; axioms
propext/Quot.sound). Book `main.tex` untouched.

## What it certifies

L5's flat ROM stores all N legal assignments — storage grows with N. The classic fix
(02_constructive_samplers's Tier-1, every BDD-unrank) is a **count-annotated structure**: each node carries its
subtree's leaf-count, and unrank walks root→leaf comparing the index R to subtree counts,
touching **O(depth) nodes** instead of scanning N. L8 proves that walk correct:

```lean
theorem cget_eq : R < count t → (toList t)[R]? = some (cget t R)
```

`cget` (the counted walk) returns **exactly the R-th leaf** of the enumeration `toList t` the tree
represents — for every R — proved by mutual induction with `count_len` (`count t = (toList
t).length`) over the tree/forest, using the list-append `getElem?` lemmas. The demo tree
`{[1,2,3],[1,3,2] | [2,3,1]}` (grouped by first value, the BDD shape) `#eval`s:

```
count demo  = 3
toList demo = [[1,2,3],[1,3,2],[2,3,1]]                 -- = the L2 legal set
(range 3).map (cget demo) = toList demo                 -- unranked via counts only; native_decide-checked
```

So the **BDD-unrank algorithm** — the heart of Tier-1 compression — is now a checked theorem, not
an assertion: random access to the R-th solution by counts, certified.

## What is certified, and the honest frontier

- **Certified:** the count-walk gives **O(depth) random access** to the R-th solution and returns
  the correct one (`cget_eq`). This is the navigation property 02_constructive_samplers's hardware unrank relies
  on.
- **Sub-linear STORAGE — done in L10/L12:** a tree with N leaves still has ≥ N nodes. Real
  compression comes from **DAG sharing** — merging isomorphic subtrees, as a reduced BDD does —
  which makes storage ≪ N. The walk above is *unchanged* by sharing (it only reads counts and
  children). **L10 realizes exactly this** (a used-set-keyed count-DAG: 2^D nodes for D! solutions,
  measured) and **L12 proves the shared-DAG walk correct for all D**. The sole remaining open step
  is **reduced-BDD canonicity** (uniqueness of the minimal form — needs the ROBDD framework), stated
  honestly in the spirit of the 04_sat_engine negatives.

This is the bridge toward the emulator-scale regime L5's flat ROM can't reach: certified O(depth)
unrank (L8), the storage win measured (L10), the shared-DAG walk proved for all D (L12) — canonicity
the sole frontier.

## Reproduce

```sh
export PATH=$HOME/.elan/bin:$PATH
cd 05_lean_certified/lean && lean Compressed.lean   # exit 0; prints 3 / the set / the unranked seq
```
