# 06_riscvdv_capstone / slice 6: the vector LMUL constraints (the only `[mul]` set), synthesized

The **only multiply-bearing constraints in the entire 140-block riscv-dv inventory** — and the result
is that they are the *cheapest* slice, not the hardest. Book `main.tex` untouched.

## What it is

Three RVV constraint blocks (`isa/riscv_vector_instr.sv`) are flagged `[mul]` in `constraints/INVENTORY.txt`:

```systemverilog
constraint narrowing_instr_c {            // (widening_instr_c is symmetric)
  vs2 % (vlmul * 2) == 0;                                   // alignment
  !(vd inside {[vs2 : vs2 + vlmul * 2 - 1]});               // register-group non-overlap
}
constraint nfields_c {
  (nfields + 1) * vlmul <= 8;  nfields > 0;                 // segment register-group bound
}
```

**The key fact: `vlmul ∈ {1,2,4,8}` is always a power of 2.** Therefore:

| riscv-dv writes | because `vlmul = 2^k` | synthesizes to |
|---|---|---|
| `vs2 % (vlmul*2) == 0` | modulo by a power of 2 | a **MASK** (clear low bits) |
| `vs2 = group * (vlmul*2)` | multiply by a power of 2 | a **SHIFT** |
| `(nfields+1) * vlmul` | multiply by a power of 2 | a **SHIFT** |
| `(nfields+1)*vlmul <= 8` | bound after shift | a small **comparator** |

So **none of the "multiply" constraints needs a runtime divider or a wide multiplier** — they are all
shift/mask/compare. The certified invert-don't-bit-blast divider from 05_lean_certified (`Tiers.lean` `mulCS`)
is the general Tier-2 fallback, but the *actual riscv-dv corpus never needs it at width*.

The constructive actor `vlmul_gen`:

```
  gmask = (16>>lmul_sel) - 1                       // alignment mask  (ngroups-1, power of 2)
  sh    = lmul_sel + 1                              // log2(2*vlmul)
  vs2   = (seed_vs2 & gmask) << sh                  // aligned group base  (MASK then SHIFT)
  vd    = pick group != vs2's, << sh                // different aligned group => non-overlap
  nfields = clamp(seed, 1 .. (8>>lmul_sel)-1)       // (nfields+1)*vlmul <= 8  (SHIFT bound)
```

Non-overlap is exact: since both `vs2` and `vd` are aligned to `2*vlmul`, "vd not in
`[vs2, vs2+2*vlmul)`" is *equivalent* to `vd != vs2` (two aligned bases are equal or ≥ a group apart),
so picking a different aligned group satisfies the `inside`-range exclusion by construction.

## Validated (verilator) — direct equivalence, both directions, every LMUL

Verilator 5.049 **solves the original modulo/multiply constraint** (8000/8000 — it supports `%` and `*`
in `randomize()`), so `vec_orig` runs as the reference and is compared to the synthesized actor:

```
>>> VEC OK: vector LMUL register-group constraints (the only [mul] set in riscv-dv) -- synthesized
    actor (SHIFT/MASK, no divider) and verilator-solved ORIGINAL (modulo/multiply) BOTH cover exactly
    the aligned vs2/vd register groups and the valid nfields range for every LMUL in {1,2,4,8},
    0 illegal each
```

- **sound, both ways** — every `(vs2, vd, nfields)` from the synthesized actor *and* from the
  verilator-solved original passes the independent `vec_checker` (which uses real `%` and `*`): vs2/vd
  aligned to `2*vlmul`, vd's group disjoint from vs2's, `(nfields+1)*vlmul ≤ 8`, `nfields > 0`
  (or `== 0` at LMUL=8). 0 illegal.
- **same legal set** — for every LMUL ∈ {1,2,4,8}, both cover **exactly** the aligned vs2 groups, the
  aligned vd groups, and the valid nfields range.

> The original's `!(vd inside {[vs2 : vs2 + vlmul*2 - 1]})` is written as `vd != vs2` for the solve
> (verilator's SMT backend mis-types the mixed-width add inside the range bound; under the alignment
> constraints the two forms are *exactly* equal, so the solved set is identical).

## Synthesized

`yosys synth_ice40`: `vlmul_gen` = **33 SB_LUT4 + 3 SB_CARRY**. The headline of the slice: the
constraint family the inventory flags as the hardest (the only `[mul]`) is the **cheapest** — 33 LUT4,
**130× smaller** than the `unique{}` family (slice 5, 4302 LUT4). The operator (`*`, `%`) is a poor
predictor of synthesis cost; the *operand* (power-of-2 `vlmul`) is what matters.

## Lean-certified (05_lean_certified / L15)

`05_lean_certified/lean/VLmul.lean`: LMUL=2 over a 16-register file. Lean enumerates the legal
set and confirms `card P doms = 36 = 4·3·3` (4 aligned vs2 groups · 3 vd groups ≠ vs2 · 3 nfields) —
the aligned-group product, the structure the MASK/SHIFT generator produces. SOUND + COMPLETE + UNIFORM
by the L2/L9 theorems (axiom-clean: `propext` + `Quot.sound`), a certified 36-entry ROM emitted.

## Coverage note

Slice 6 of the capstone: the vector LMUL constraints — the **last of the riscv-dv constraint
operator-classes** (the `[mul]` set). With slices 1–5 every major constraint *shape* and the only
multiply-bearing family are synthesized + validated. The finding — riscv-dv's multiplies all collapse
to shift/mask because `vlmul` is a power of 2 — means the **whole 140-block corpus is Tier-1-reachable
with no runtime SAT and no wide divider**. Remaining: WIRE the per-class actors into the full
instruction stream + cross-instruction hazards. Reproduce:

```sh
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tb_top \
  vec_orig.sv vlmul_gen.sv vec_checker.sv tb_vec.sv && ./obj_dir/Vtb_top
yosys -p "read_verilog -sv vlmul_gen.sv; synth_ice40 -top vlmul_gen; stat"   # 33 LUT4
```
