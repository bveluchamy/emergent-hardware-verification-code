# 05_lean_certified / L3: the tiers, unified — and the harder constraint without enumeration

`lean/Tiers.lean` — pure Lean 4 core, imports the L2 `Sampler` (compile `Sampler.olean`
first), then `LEAN_PATH=. lean Tiers.lean` (exit 0, **0 sorries**; axioms propext/Quot.sound).
Book `main.tex` untouched.

## One interface, both tiers

```lean
structure CSampler (P : Asn → Bool) where
  Seed : Type
  draw : Seed → { a : Asn // P a = true }     -- SOUND by type: every draw is legal
```

A `CSampler P` is a **sound seeded witness producer**. The 02_constructive_samplers *tier framework* is then
literally a set of instances over this one interface — **the tiers are ways to inhabit
`Seed → {a // P a}`, i.e. constructive type inhabitation:**

| tier | `Seed` | `draw` | how it solves | completeness |
|---|---|---|---|---|
| **Tier-1** `enumCS` | `Fin N` | the L2 unrank | enumerate a finite box, index it | `enumCS_complete` |
| **Tier-2** `mulCS` | `ℕ × ℕ` | the certified **divider** | invert `A*B<LIMIT`, **no enumeration** | `mulCS_complete` |

## The harder constraint, synthesized without enumeration

`A*B < LIMIT` is the BDD-killer: its box is ≈2⁶⁴ pairs — un-enumerable, no poly BDD (Bryant).
Tier-1 cannot touch it. **Tier-2 does, in O(1)**, because the witness is *constructed* by the
inverse (`B := Braw mod ((LIMIT-1)/A + 1)`) and proved legal by `mul_sound` — the same algebra
as `02_constructive_samplers/lean/MulSampler.lean`, re-proved inline (never bit-blasting the multiply:
Bryant honoured on the proof side). `#eval`, all certified legal, no box built:

```
(mulCS 10⁶).draw (777, 123456789)  = [777, 701]     -- 777·701 = 544677 < 10⁶  ✓
(mulCS 10⁶).draw (1000, 999999999) = [1000, 999]    -- 1000·999 = 999000 < 10⁶ ✓
Pmul 10⁶ [777,701] = true                            -- the checker agrees
```

So **"harder constraint solving" is synthesized by replacing enumeration with a certified
inverse** — the prover's algebraic reasoning standing in for a search that cannot be run. Both
tiers inhabit one type; the proof is the program. This is the deep point of the arc: the
02_constructive_samplers tiers, the 04_sat_engine residue, and this all sit under *one* constructive-witness
abstraction, and the prover certifies each instance sound (+ complete) with no refutation.

## What L4 closes

L3 is all compile-time/Lean. L4 extracts a `CSampler` to **SystemVerilog** and verilator-
validates it bit-identical to the Lean semantics — the SV-constraint→FPGA loop, certified end
to end. Tier-1 extracts to a ROM + indexed read; Tier-2 extracts to the divider datapath
(02_constructive_samplers's `mul_constraint_sampler.sv`, already verilator-validated). See `README_L4.md`.

## Reproduce

```sh
export PATH=$HOME/.elan/bin:$PATH
cd 05_lean_certified/lean
lean -o Sampler.olean Sampler.lean && LEAN_PATH=. lean Tiers.lean   # exit 0; prints the certified Tier-2 draws
```
