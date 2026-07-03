# 05_lean_certified / L9: the sampler is uniform (injective), certified

`lean/Uniform.lean` (imports L2 `Sampler`). `LEAN_PATH=. lean Uniform.lean` (exit 0, **0
sorries**; propext/Quot.sound). Book `main.tex` untouched.

## The third property

L2 certified the unrank sampler **sound** (every draw legal) and **complete** (every legal value
reachable). The property that makes it a *good* CRV sampler is **uniformity**: a uniform random
index must give a uniform random solution — no legal assignment over- or under-sampled. That is
exactly `unrank` being **injective**, which holds iff the enumerated legal list is duplicate-free:

```lean
theorem unrank_inj : (legal P doms).Nodup → ∀ r₁ r₂, (unrank … r₁).val = (unrank … r₂).val → r₁ = r₂
```

So with the three together (`unrank_bijective`):

> **sound (L2) ∧ complete (L2) ∧ uniform (L9) ⇒ `unrank` is a bijection `Fin N ≃ legal-set`** —
> every legal assignment is hit *exactly once*.

The `Nodup` hypothesis is now a **proven structural lemma**, not a `decide`:
`legal_nodup : (∀ d ∈ doms, d.Nodup) → (legal P doms).Nodup` (built in `Uniform.lean` from
`nodup_append` — core lacks `List.Nodup.map`/`.flatMap` — plus `filter` is a sublist). So the
per-instance discharge is just the tiny **per-domain** nodup. `pinst_uniform` is therefore
axiom-clean (`propext/Quot.sound`, no `native_decide`), and the same `legal_nodup` keeps L13's
840-entry uniformity clean. This certifies the zero-rejection *and* uniform-coverage property
02_constructive_samplers's Tier-1 sampler claimed.

## Reproduce

```sh
export PATH=$HOME/.elan/bin:$PATH
cd 05_lean_certified/lean
lean -o Sampler.olean Sampler.lean && LEAN_PATH=. lean Uniform.lean   # exit 0; prints true (nodup ⇒ uniform)
```
