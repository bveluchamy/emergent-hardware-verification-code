# 06_riscvdv_capstone / slice 2: the riscv-dv immediate generator (imm_c + extend_imm), synthesized

The immediate constraints, as a synthesized actor sub-network. Book `main.tex` untouched.

## What it is

riscv-dv generates immediates not by a SAT solve but by `extend_imm()` — a datapath governed by
`set_imm_len()` (`riscv_instr.sv:304–326`) and the `imm_c` shift constraint. So the immediate
"solver" is *already constructive*; we synthesize that datapath exactly:

- **`imm_format`** (InstrSelectActor): instruction format → `(imm_len, is_signed)` — U/J→20,
  I/S/B→12 (or 5 for UIMM shifts) — riscv-dv's `set_imm_len`.
- **`imm_extend`** (OperandActor): keep the low `imm_len` bits, sign-extend signed formats —
  riscv-dv's `extend_imm`. riscv-dv only uses `imm_len ∈ {5,12,20}`, so it's a constant-width
  sign-extend per width (equivalent to the variable-shift form, and yosys-clean).

## Validated (verilator) — four ways, including direct equivalence

`tb_imm.sv`:

```
>>> IMM OK: actor network == riscv-dv extend_imm EXACTLY (24000 draws/6 formats), all legal,
    imm_c shamt<32, and the shift-imm set == verilator-solved ORIGINAL (all 32 shamts, both dirs)
```

1. **functional equivalence** — the synthesized output equals an independently-coded `extend_imm`
   (riscv-dv's exact algorithm) **bit-for-bit**, over 24000 draws × all 6 formats (I/S/B/U/J + shift).
2. **soundness** — every output is a legal immediate (`imm_checker`: correctly sign/zero-extended).
3. **`imm_c`** — the shift-amount constraint (`imm[11:5]==0` ⇒ `shamt < 32`) holds.
4. **direct equivalence vs the original** — for the shift case, the synthesized shamt set ==
   the **verilator-`randomize()`-solved** original `shamt inside {[0:31]}` set (all 32, both directions).

## Synthesized

`yosys synth_ice40`: `imm_gen` = **19 SB_LUT4** (constant-width form). (The literal variable-shift
`extend_imm` is valid synthesizable RTL — verilator runs it — but yosys's abc pass chokes on the
double variable barrel-shift; the constant-width form is faithful since `imm_len ∈ {5,12,20}` and
synthesizes trivially.)

## Coverage note

This is slice 2 of the capstone: the **immediate** constraints (`imm_c` + per-format widths),
exact-equivalent to riscv-dv and synthesized. With slice 1 (R-type operands/reg-alloc) the actor
network now covers the operand and immediate generation for the base ALU/shift formats. Next:
the load/store `addr_c` dependency chain (L6 compositional). Reproduce:

```sh
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tb_top \
  imm_orig.sv imm_gen.sv imm_checker.sv tb_imm.sv && ./obj_dir/Vtb_top
yosys -p "read_verilog -sv imm_gen.sv; synth_ice40 -top imm_gen; stat"    # 19 LUT4
```
