# 06_riscvdv_capstone / slice 4: full instruction assembly (I/S/B/U/J + R), synthesized

Combining the operand (slice 1) and immediate (slice 2) actors into **complete 32-bit RISC-V
instructions**, validated by round-trip against an independent decoder. Book `main.tex` untouched.

## What it is

`instr_assemble` scatters the operands + immediate into the 32-bit encoding for each format — the
format-specific **immediate bit-scramble** is the real complexity here:

| fmt | encoding |
|---|---|
| R | `{funct7, rs2, rs1, funct3, rd, opcode}` |
| I | `{imm[11:0], rs1, funct3, rd, opcode}` |
| S | `{imm[11:5], rs2, rs1, funct3, imm[4:0], opcode}` |
| B | `{imm[12], imm[10:5], rs2, rs1, funct3, imm[4:1], imm[11], opcode}` |
| U | `{imm[31:12], rd, opcode}` |
| J | `{imm[20], imm[10:1], imm[11], imm[19:12], rd, opcode}` |

`instr_decode` is the **independent standard RISC-V decoder** (re-extract rd/rs1/rs2, gather +
sign-extend the immediate per format).

## Validated (verilator) — assemble→decode is the identity

`tb_instr.sv` generates random format-valid `(rd, rs1, rs2, imm, funct)` for each format, assembles
the 32-bit instruction, decodes it back with the independent decoder, and checks the round-trip on
exactly the fields each format uses:

```
>>> INSTR OK: assemble->decode is the IDENTITY across I/S/B/U/J + R over 30000 instructions --
    the synthesized assembly produces valid RISC-V encodings that decode back to the generated
    rd/rs1/rs2/imm exactly
```

Because the decoder is the *standard* RISC-V field extraction, the round-trip identity proves the
synthesized assembly emits **standard-correct RISC-V encodings** — the operands and immediate
(including B/J alignment and S/B split-immediates) are placed exactly where the ISA defines them.
30000 instructions, 0 mismatches, all 6 formats.

## Synthesized

`yosys synth_ice40`: `instr_assemble` = **59 SB_LUT4** (pure combinational bit-routing).

## Coverage note

Slice 4 of the capstone: the actor network now produces **complete, legal, decodable RISC-V
instructions** — operand selection (slice 1) + immediate generation (slice 2) + format-correct
assembly (slice 4), with dependent addressing (slice 3) for load/stores. Next: the cfg-reactive
families (reserved_regs/XLEN/supported_*) + foreach/unique register lists, then the full stream +
hazards. Reproduce:

```sh
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tb_top \
  instr_assemble.sv instr_decode.sv tb_instr.sv && ./obj_dir/Vtb_top
yosys -p "read_verilog -sv instr_assemble.sv; synth_ice40 -top instr_assemble; stat"   # 59 LUT4
```
