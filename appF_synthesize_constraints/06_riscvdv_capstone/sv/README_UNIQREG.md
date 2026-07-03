# 06_riscvdv_capstone / slice 5: unique register allocation (avail_regs_c), synthesized

The `unique{}` constraint family — riscv-dv's directed-instruction **`avail_regs_c`** — as a
synthesized actor, validated *directly* against the original via verilator's `randomize()`. Book
`main.tex` untouched.

## What it is

riscv-dv allocates a list of scratch registers with (`riscv_directed_instr_lib.sv:442`):

```systemverilog
constraint avail_regs_c {
  unique {avail_regs};                              // all 10 distinct
  foreach (avail_regs[i]) {
    !(avail_regs[i] inside {cfg.reserved_regs});     // none reserved
    avail_regs[i] != ZERO;                           // none is x0
  }
}
```

`num_of_avail_regs = 10`: ten **distinct** registers, none reserved, none `ZERO`. This is the
`unique{}` family — the all-different constraint over an array, the hardest of the riscv-dv
constraint shapes because each pick *depends* on every prior pick.

The synthesized actor builds the allocation **constructively, with no rejection and no divider**:

```
  excl0 = reserved ∪ {ZERO}
  for i in 0..9:
     rg[i]   = reg_select_ex(excl[i], seed[i])     // the (seed mod) idx-th still-available register
     excl[i+1] = excl[i] ∪ {rg[i]}                  // remove it from the pool
```

Because `rg[i]` is drawn from `legal \ already-picked` and then *added to the exclusion mask*,
**uniqueness is structural** — the same register can never be picked twice, by construction, so the
`unique{}` clause needs no solver and no backtracking. `reg_select_ex` **clamps** an out-of-range
index to the last available register (never the reg-0 default, which would be reserved), so every
output is a legal non-reserved register regardless of seed. No modulo ⇒ no divider; the index test
is an equality compare (`c == idx`), so the only arithmetic is one short `c+1` counter.

## Validated (verilator) — direct equivalence, both directions

Verilator 5.049 **supports `unique{}` in constraints** (solved 2000/2000), so the original
`avail_regs_c` is run as the reference via `randomize()` and compared to the synthesized actor:

```
>>> UNIQ OK: unique register allocation -- synthesized actor (4000 allocs, all 10 distinct &
    non-reserved) and verilator-solved ORIGINAL avail_regs_c (unique{}) BOTH cover exactly the
    27 legal registers {5..31}, 0 illegal each
```

- **sound, both ways** — every allocation from the synthesized actor *and* from the verilator-solved
  original is 10 **distinct** registers, **none** in `{ZERO,RA,SP,GP,TP}`, **none** `ZERO`. 0 illegal
  from 4000 synthesized allocations and 2000 solved-original allocations.
- **same legal set** — both the synthesized actor and the original solver cover **exactly** the 27
  legal registers `{5..31}` (mask `0xFFFFFFE0`), no more, no less.

## Synthesized

`yosys synth_ice40`: `uniqreg_gen` (K=10) = **4302 SB_LUT4 + 937 SB_CARRY**. This is the **heaviest
slice** — and honestly so: it is ten *dependent* selections (`excl` grows each step), each a
priority-select over the 32-register file, so the area is ~10× a single `reg_select`. Removing the
naive modulo (a per-step variable divider, which first measured 9551 LUT4) and the magnitude compare
(which rippled 6831 carries) brought it down to a clamped, equality-tested chain.

> **Config-time note.** `cfg.reserved_regs` is fixed once per test (resolved before generation, the
> way `01_constraint_compiler/frontend.py` resolves enums). With `reserved` lifted to a module **parameter**, the
> available-register positions are compile-time constants, the ten selects constant-fold, and the
> family collapses to a small fixed mux network — the constructive structure is identical, only the
> pool is specialized. The runtime-`reserved` version measured here is the fully-general worst case.

## Lean-certified (05_lean_certified / L14)

A small instance of the same constraint is certified end-to-end by the 05_lean_certified Lean pipeline
(`05_lean_certified/lean/UniqReg.lean`): 3 distinct registers from a 6-register file, ZERO
reserved. Lean **enumerates** the legal set and confirms `card P doms = 60 = 5·4·3` — the
falling-factorial signature of `unique{}` (a product-of-domains box collapsing to a falling factorial
is *exactly* the all-different clause). SOUND + COMPLETE + UNIFORM are discharged by the L2/L9
theorems (axiom-clean: `propext` + `Quot.sound`, no `native_decide`), and a certified 60-entry ROM is
emitted. So the `unique{}` family is validated two ways: verilator equivalence at full scale (10
registers, 32-file) and Lean certification of the spec at small scale.

## Coverage note

Slice 5 of the capstone: the **`unique{}` constraint family** (all-different register lists), the
last of the major riscv-dv constraint *shapes* (Boolean/range/bitslice in s1–s2, dependency-chain in
s3, encoding-scatter in s4, all-different here). The actor network now covers operand selection,
immediates, dependent addressing, full instruction assembly, and unique register allocation —
synthesized and validated. Remaining: the 3 Tier-2 (mul) constraints, then the wired full
instruction stream + cross-instruction hazards. Reproduce:

```sh
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tb_top \
  avail_orig.sv uniqreg_gen.sv uniqreg_checker.sv tb_uniqreg.sv && ./obj_dir/Vtb_top
yosys -p "read_verilog -sv uniqreg_gen.sv; synth_ice40 -top uniqreg_gen; stat"   # 4302 LUT4
```
