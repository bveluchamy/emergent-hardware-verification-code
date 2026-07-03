# 06_riscvdv_capstone / first end-to-end slice: R-type instruction generation as a synthesized actor network

A complete, validated slice of the capstone (C2+C4+C5+C6 for one instruction class). Book
`main.tex` untouched.

## What it is

An RV32I **R-type** instruction generator (ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND), structured as
the capstone's **actor network** in synthesizable SV:

```
  ConfigActor (reserved : 32-bit live mask)  →  InstrSelectActor (op_table: pick 1 of 10 ops)
     →  OperandActor (reg_select ×3: draw rd/rs1/rs2 from the LIVE legal-register set)
     →  assemble {funct7, rs2, rs1, funct3, rd, 0110011}  →  CheckerActor (independent)
```

The real riscv-dv constraint here is **reg-alloc reactivity**: `rd/rs1/rs2 ∉ reserved_regs`, where
`reserved_regs` is *live* (changes per context). `reg_select` realizes it as a **constructive
sampler** — select the `idx`-th register not in the mask (`idx = seed mod #legal`) — no rejection,
bounded (a 32-way priority scan). This is the 05_lean_certified L7 / 03_reactive_constraints `axi_aw` reactive pattern,
on real RISC-V register allocation.

## Validated (verilator) — both directions, vs the original constraints

`tb_rtype.sv` sweeps four reserved masks (incl. riscv-dv's `{ZERO,RA,SP,GP,TP}`) × 20000 seeds and
checks the actor output against `rtype_checker.sv` (the original R-type constraints, independently
coded):

```
>>> C-slice OK: R-type actor network -- 80000 (mask × seed) draws, 0 illegal, and rd/rs1/rs2
    cover EXACTLY the legal register set + all 10 RV32I ops, across 4 reserved masks
```

- **sound** (= original ⊇ output): every emitted instruction passes the independent checker — valid
  opcode/funct, registers not reserved. **0 illegal** over 80000 draws.
- **coverage** (= original ⊆ output): `rd/rs1/rs2` reach *exactly* the legal register set (`~reserved`)
  and all 10 R-type ops are produced. So the actor network's stimulus = the original constraints'
  legal space.

## Synthesized (yosys synth_ice40)

- `reg_select` (the reactive reg-alloc sampler): **289 SB_LUT4 + 68 carry**.
- `op_table` (instruction select): a tiny 10-entry decode.
- The full `rtype_gen` uses a variable-divisor index mod (`seed % #legal`) = the certified Tier-2
  divider (L3 / 03_reactive_constraints's `pipelined_div`); the behavioral form is yosys-slow (the L6 note),
  the deployable form is that validated divider.

## Scope

This is **one instruction class** (R-type, the reg-alloc + op-select constraints) of the 140-constraint
generator — a complete, validated, synthesized vertical slice proving the architecture end to end.
Next slices (per `DESIGN.md` C3/C4): the immediate constraints (`imm_c`, bit-field/Tier-1), the
load/store `addr_c` dependency chain (L6 compositional), and wiring the per-class actors into the
full stream generator. Reproduce:

```sh
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tb_top \
  rtype_gen.sv rtype_checker.sv tb_rtype.sv && ./obj_dir/Vtb_top
yosys -p "read_verilog -sv rtype_gen.sv; synth_ice40 -top reg_select; stat"   # 289 LUT4
```

## Direct equivalence vs the ORIGINAL, in verilator (the strong validation)

Verilator 5.049 supports `rand`/`constraint`/`randomize()`, so `tb_compare.sv` runs the **original
riscv-dv R-type constraint** (written as riscv-dv writes it — `!(reg inside {ZERO,RA,SP,GP,TP})`)
through verilator's own solver and compares to the synthesized actor network, both in one run:

```
>>> EQUIV OK: verilator-solved ORIGINAL riscv-dv R-type constraint == SYNTHESIZED actor network
    -- identical legal reg sets (rd/rs1/rs2 = regs 5..31) + identical op set (all 10), 0 illegal each
```

So the synthesized output and the *original SV solver's* output reach the **same legal stimulus
space** — direct equivalence, not just an independent checker. (Caught a real gotcha en route:
verilator's solver enforces `inside`/relational/range — riscv-dv's actual forms — but **not** a
dynamic bit-select `reserved[rd]` of a non-`rand` vector; drive the reference from riscv-dv's own
constraint text. See DESIGN §3.)
