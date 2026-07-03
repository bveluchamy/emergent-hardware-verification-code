# 05_lean_certified / L13: a real industrial riscv-dv constraint, certified in Lean

`lean/SpTp.lean` (imports L4 `Codegen` + L9 `Uniform`) + `sptp_checker.sv` / `tb_sptp.sv`. The
capstone — everything before this was *test* constraints; L13 certifies a **genuine riscv-dv
block** and bridges to the `01_constraint_compiler` corpus. Book `main.tex` untouched.

## The constraint (real, not invented)

riscv-dv's **`sp_tp_c`** from `riscv_instr_gen_config.sv`, resolved by `01_constraint_compiler/frontend.py`
(enums `SP=2/GP=3/ZERO=0/RA=1` auto-resolved) — `01_constraint_compiler/resolved_sp_tp_c.txt`:

```
rand bit fix_sp;  rand bit[4:0] sp, tp;
(!fix_sp || sp==2) ∧ sp ≠ tp ∧ sp ∉ {0,1,3} ∧ tp ∉ {0,1,3}
```

It is the very constraint the `01_constraint_compiler/closeloop/` took to the fabric via `csc.py` (a BDD-unrank
sampler, **473 LUT**, `NSOL=840`).

## Two independent compilers, the same legal set

Lean enumerates the 2048-element box and **independently reproduces csc.py's count exactly**:

```
#eval card P doms = 840          -- == csc.py NSOL=840 (01_constraint_compiler), proved: `by native_decide`
```

and certifies it with the L2/L9 theorems instantiated at the real constraint:

| property | theorem | axioms |
|---|---|---|
| **sound** (every draw legal) | `sptp_sound` | **propext only** |
| **complete** (every legal choice reachable) | `sptp_complete` | **propext only** |
| **uniform** (840 distinct ⇒ injective draw) | `sptp_uniform` | **propext/Quot.sound** — the `Nodup` is the proven `legal_nodup` (per-domain: `decide` for `{0,1}`, constructive `range_nodup` for `[0,31]`); **no `native_decide`** |

## Validated on the fabric — both directions

Lean emits the certified 840-entry ROM (`sptp_sampler.sv`); an **independently-coded** SV checker
(`sptp_checker.sv` = the constraint in SV) and a tb cross-check it in verilator:

```
>>> L13 OK: real riscv-dv sp_tp_c -- Lean-certified ROM (N=840) all pass the independent SV
    checker, and the SV checker accepts EXACTLY 840 of 2048 (= csc.py NSOL=840) => ROM = legal set
```

(a) every Lean ROM entry passes the SV checker ⇒ **ROM ⊆ SV-legal**; (b) the SV checker accepts
exactly 840 of the 2048 box ⇒ **|SV-legal| = 840 = |ROM|**. Together: **ROM = the legal set**,
validated against an implementation that never trusted Lean.

## Honest notes

- **Area:** the flat 840-arm combinational-`case` ROM is slow for open-source `yosys synth_ice40`
  (same large-case behaviour as L5's 720-ROM). The *compact deployable* RTL for this exact
  constraint is **csc.py's BDD-unrank (473 LUT**, validated in the closeloop) — and that unrank
  **algorithm is what L8/L10/L12 certify**. So 05_lean_certified now certifies *both* the real constraint
  (L13) *and* the compression algorithm the production compiler uses (L8/L10/L12).
- **All three are axiom-clean** — `sound`/`complete` propext-only, `uniform` propext/Quot.sound.
  The `Nodup` is the *proven* structural lemma `legal_nodup : (∀ d ∈ doms, d.Nodup) → (legal P
  doms).Nodup` (in `Uniform.lean`), discharged by the tiny per-domain nodup (`decide` for `{0,1}`,
  a constructive `range_nodup` for `[0,31]` — core's `List.nodup_range` pulls `Classical`, so it is
  reproved cleanly). **No `native_decide` in the certification** (the only `native_decide` here is
  the separate `card = 840` count check).

## Significance

This turns "certified on test constraints" into **"a real riscv-dv constraint, certified
sound+complete+uniform in Lean, its count matching the production BDD-compiler, validated both
directions on the fabric."** 05_lean_certified (certification) and 01_constraint_compiler (the compiler + the 473-LUT
closeloop) now meet on the same constraint.

## Reproduce

```sh
export PATH=$HOME/.elan/bin:$PATH
cd 05_lean_certified/lean
lean -o Sampler.olean Sampler.lean && LEAN_PATH=. lean -o Codegen.olean Codegen.lean \
  && LEAN_PATH=. lean -o Uniform.olean Uniform.lean
LEAN_PATH=. lean SpTp.lean                              # 840; emits sptp_sampler.sv
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tb_top \
  sptp_sampler.sv sptp_checker.sv tb_sptp.sv && ./obj_dir/Vtb_top      # >>> L13 OK
```
