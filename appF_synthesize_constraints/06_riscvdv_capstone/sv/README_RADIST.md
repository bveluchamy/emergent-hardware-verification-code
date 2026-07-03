# 06_riscvdv_capstone / slice 9: the `dist` (weighted distribution) family, synthesized

The last constraint *operator* in riscv-dv not yet covered — **`dist`**, weighted randomization — as a
synthesized constructive sampler, validated against the **verbatim** riscv-dv constraint via verilator
`randomize()`. Book `main.tex` untouched.

## What it is

riscv-dv's `ra_c` (`riscv_instr_gen_config.sv`) picks the return-address register from a **weighted
distribution** (ABI registers resolved 01_constraint_compiler-style: RA=1, SP=2, TP=4, T1=6, T2=7, T6=31, ZERO=0):

```systemverilog
constraint ra_c {
  ra dist {1 := 3, 6 := 2, [2:5] :/ 1, [7:31] :/ 4};   // weighted
  ra != 2;  ra != 4;  ra != 0;                          // != sp, tp, ZERO
}
```

A `dist` is a **weighted table**: a uniform seed mapped through cumulative thresholds to the chosen
value. The synthesized actor `ra_dist_gen` does exactly that — a comparator cascade over the cumulative
weights — so the "weighted random" is a constructive datapath: **no runtime divider, no SAT**.

## The `:/`-with-exclusion gotcha (the finding)

The interesting part is how `[2:5] :/ 1` interacts with `ra != 2` / `ra != 4`. The `:/` gives the
**range** a total weight of 1, split among its members. Naively you'd model each of {2,3,4,5} at 0.25
and, dropping the excluded 2 and 4, leave {3,5} at 0.5 total. **That is wrong.** SV `dist` renormalizes
over the *feasible* set, and verilator preserves the `:/` **bucket's** weight, splitting it among the
**survivors** {3,5} — so the bucket keeps weight 1, and the relative parts are:

```
  RA 3  :  T1 2  :  [2:5]-bucket 1  :  [7:31] 4   =   total 10
```

giving `{3,5}` ≈ 10% (each ≈ 5%), not 5%. The synthesized sampler is built to *this* (verilator's)
interpretation — confirmed because verilator's `randomize()` of the verbatim constraint is the
reference oracle. Scaled to a 16-bit seed: RA=19650, {3}={5}=3277, T1=13107, each of [7:31]=1049
(sum 65536).

## Validated (verilator) — both directions, verbatim constraint

`tb_radist.sv`:

```
>>> RADIST OK: dist (weighted distribution) family -- riscv-dv ra_c VERBATIM. Constructive weighted
    sampler (exact dist by construction, weight table verified at all 29 bucket boundaries: RA 30%,
    T1 20%, [7:31] 40%, {3,5} 10%) and verilator-randomize()-solved ORIGINAL dist BOTH have support
    {0..31}\{ZERO,sp,tp}, every support value reached, and MATCHING grouped weights (orig sampled
    fractions within 15-20% of the exact weights over 4000 draws), 0 illegal each
```

- **exact weight table** — the synthesized sampler's cumulative thresholds are verified at all **29
  bucket boundaries** (first and last seed of each bucket map to the right register), so its
  distribution is exact by construction.
- **same support, both ways** — the synthesized sampler and the verilator-solved verbatim `dist` both
  emit exactly `{0..31}\{0,2,4}` (every one of the 29 legal registers reached, never ZERO/sp/tp).
- **matching weights** — the original's sampled fractions match the synthesized exact weights, grouped
  (RA / T1 / {3,5} / [7:31]), within 15–20% over 4000 draws.

Two verilator gotchas found here: (a) `dist` `randomize()` is **slow per call** (~ms; the run uses
4000 draws and group-level fidelity, not a 65536-sweep); (b) a comma-separated `longint a = …, b = …;`
declaration-with-initializer mis-assigns the first variable — split into separate statements.

## Synthesized

`yosys synth_ice40`: `ra_dist_gen` = **28 SB_LUT4 + 395 SB_CARRY** (the carries are the 29-way
cumulative-threshold comparator cascade; ice40 maps magnitude compares to carry chains). A weighted
distribution is just a small comparator cascade on the fabric.

## On Lean certification

Slices 5–6 were Lean-certified because they are *uniform* sampling over a legal set, which the
05_lean_certified pipeline (L2/L9: bijection `Fin N ≅ legal set`) certifies directly. A `dist` is **weighted**,
not uniform, so the uniform-sampling theorems do not apply to its essence; the certifiable part is only
its *support* (the set `{ra : ra ∉ {0,2,4}}`, card 29), which is trivial. The weights — the actual
content — are validated quantitatively by the histogram match above, so no L16 is added.

## Coverage note

Slice 9 covers the `dist` (weighted distribution) operator — the last riscv-dv constraint operator
class not yet sliced — using the **verbatim** constraint as the reference. With slices 1–8, every
riscv-dv constraint *operator class* (Boolean/range/bitslice, dependency-chain, encoding-scatter,
all-different/`unique`, multiply/modulo, sequential stream state, and now weighted `dist`) is
synthesized and validated both directions. Reproduce:

```sh
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tb_top \
  ra_orig.sv ra_dist_gen.sv ra_checker.sv tb_radist.sv && ./obj_dir/Vtb_top
yosys -p "read_verilog -sv ra_dist_gen.sv; synth_ice40 -top ra_dist_gen; stat"   # 28 LUT4 + 395 carry
```
