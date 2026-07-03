# 05_lean_certified / L6: the structural (non-enumerative) certified sampler

`lean/Compose.lean` (imports L3 `Tiers`). The regime L5's ROM can't reach: a legal set far too
large to enumerate. Book `main.tex` untouched.

## The move: build the witness, don't list it

L2/L5 inhabit `{a // P a}` by **enumeration** (a ROM) — only when the legal set fits in memory.
L3's divider inhabits it by **algebra** (one inverse). L6 is the general structural form:
**construct the witness field by field, each field's draw certified legal GIVEN the earlier
fields** — O(#fields), never touching the joint product. This is 03_reactive_constraints's compositional
generation (header→payload), and the **reactive (R3)** pattern — a draw certified legal *given
live state* — in certified form.

Demonstrated on a constraint whose legal set is astronomical:

> `[h, t]` with `1 ≤ h ≤ K` and `t ≤ h`,  K = 10⁶  →  **K·(K+1)/2 = 500000500000 ≈ 5·10¹¹** legal pairs

The tail constraint **depends on the head** (`t ≤ h` — the defining feature of reactivity). The
certified `draw` picks `h := 1 + hraw mod K`, then the head-dependent `t := traw mod (h+1)`, and
proves `Pjoint K [h,t]` from the two per-field facts. **O(1), no enumeration of the 5·10¹¹ pairs.**

```
(composeCS 10⁶).draw (123456789, 987654321) = [456790, 72179]   -- 72179 ≤ 456790 ≤ 10⁶  ✓
(composeCS 10⁶).draw (5, 999999999)         = [6, 5]            -- 5 ≤ 6                 ✓
Pjoint 10⁶ [456790,72179] = true                                -- the checker agrees
```

- **Sound** by construction (the subtype carries `Pjoint`).
- **Complete** (`composeCS_complete`): every legal `[h,t]` is reachable — seed `(h-1, t)`
  reproduces it via the mod identities — so the O(1) sampler covers the entire 5·10¹¹-element set.
- **It is a `CSampler`** (the L3 interface): enumeration (Tier-1), algebra (Tier-2), and
  composition (L6) all inhabit *one* type. The tier framework is a constructive-sampler **algebra**.

## Honest note on axioms

L2/L5 are **propext-only** (maximally constructive — pure enumeration). L6's *proof* pulls the
standard Lean set `propext / Quot.sound / Classical.choice` (`Classical.choice` enters via
`omega`). That is in the **erased proof**, not the program: the sampler **computes** (the `#eval`s
above ran). So the legality *certificate* uses a classical-but-sound axiom while the *sampler
itself* is executable and correct — verified by evaluation.

## Why this matters for the ultimate goal

This is the path for the cases L5's ROM can't hold: emulator-scale and reactive constraints get a
**certified O(1) structural sampler** instead of either a giant ROM or a runtime search. Combined
with L4's codegen, a compositional sampler emits to a small per-field datapath (the 03_reactive_constraints
`axi_aw` / header→payload shape) — certified, synthesizable, no enumeration.

## L6 → RTL (validated; reduces to already-certified primitives)

The compositional datapath `compose_sampler.sv` (`h = 1 + hraw mod K`; `t = traw mod (h+1)`)
was verilator-validated: it **matches the Lean draw exactly** at the reference point
(`[h,t]=[456790,72179]`) and is **legal at every draw** over a 160000-seed sweep (0 illegal),
with no enumeration of the ≈5·10¹¹ set.

*Honest synthesis note (an 04_sat_engine-style negative).* yosys `synth_ice40` does **not** give a
quick area number, because the head's constant `mod K` and especially the tail's **variable-divisor
`mod (h+1)`** are *dividers* — the classic divider-synthesis problem the open-source behavioral
flow chokes on (timed out at both 32-bit and 12-bit). But this is not a gap: L6's two operations
are *exactly* primitives already built, validated, and certified elsewhere — the head is a Tier-0
constant-divisor datapath (Lemire-able), and the tail `raw mod (bound+1)` is **literally L3's
certified `mulDraw` step** and 03_reactive_constraints's verilator-validated `pipelined_div` (50.7 MHz). So
**L6 composes certified primitives**; it needs no new synthesis, and that composition (not a fresh
LUT count) is the result. Files: `compose_sampler.sv` / `compose_checker.sv` / `tb_compose.sv`.

## Reproduce

```sh
export PATH=$HOME/.elan/bin:$PATH
cd 05_lean_certified/lean
lean -o Sampler.olean Sampler.lean && LEAN_PATH=. lean -o Tiers.olean Tiers.lean
LEAN_PATH=. lean Compose.lean        # exit 0; prints the certified O(1) draws + 500000500000
```
