# 05_lean_certified / L2: the constructive certified sampler

`lean/Sampler.lean` — pure Lean 4 core, `lean Sampler.lean` (exit 0, **0 sorries**; the
theorems depend only on `propext` — not even `Quot.sound` or `Classical.choice`, so this is
maximally constructive). Book `main.tex` untouched.

## The thesis, made concrete

A constraint is a decidable Bool predicate `P : Asn → Bool` — **this is the checker**, already
synthesizable. L2 turns it into a **certified sampler**:

```
unrank : Fin N → { a : Asn // P a = true }
```

The result is a **subtype**: every emitted assignment *carries its own legality proof*. So —

| property | how | in the file |
|---|---|---|
| **soundness** | by construction (you cannot extract `a` without `P a`) | `unrank_sound` (it is the subtype's `.property`) |
| **completeness** | every legal assignment in the box is some index's image | `unrank_complete` |
| **reachable = legal** | the `mem_filter` characterization | `mem_legal` |

This is 02_constructive_samplers's Tier-1 BDD-unrank property — *zero rejection, reachable-set =
solution-set* — but **derived and certified in Lean** instead of asserted and bit-compared.
We used only construction (∃-introduction); never refutation. (DESIGN.md §0: the model-finding
half.)

## It actually solves — verified

Instance: 3 vars in [1,4], all-different, `sum==6`, `v0<v1`. Lean enumerates the legal set at
compile time and `#eval`s it:

```
card  = 3
legal = [[1,2,3], [1,3,2], [2,3,1]]        -- (only the set {1,2,3} sums to 6; 3 perms satisfy v0<v1)
sample 0 = [1,2,3]   sample 1 = [1,3,2]     -- the extracted sampler, runtime-evaluated
```

and `example : ∀ i, Pinst (unrank … i).val = true := by decide` confirms soundness
computationally across the whole index range, on top of the by-construction proof.

## What this is, and what L3 attacks

L2 inhabits the sampler by **enumeration** (filter the cartesian box). That is the right
certified core for Tier-1 (Boolean/relational, small box), and it maps directly to RTL: the
`legal` list is a ROM, `unrank` is an indexed read. But enumeration blows up for **arithmetic**
(`A*B<LIMIT`: the box is 2⁶⁴). L3 unifies the tiers under one constructive interface so the
witness can also be built by a **certified inverse** (the 02_constructive_samplers divider, `MulSampler.lean`)
— *without enumerating* — i.e. harder constraint solving, still as a certified constructive
witness. See `DESIGN.md` §4 and `README_L3.md`.

## Reproduce

```sh
export PATH=$HOME/.elan/bin:$PATH
cd 05_lean_certified/lean && lean Sampler.lean   # exit 0; prints 3 / the legal set / samples
```
