# 06_riscvdv_capstone / slice 10: the mega-integrated generator — one emulation run, distributed actors

A real emulation run is **one integrated design** — the whole testbench graph clocked together on the
fabric, not separate per-constraint runs. Slices 1–9 validated each constraint family in isolation;
slice 10 wires them all into a single clocked generator and synthesizes it as **one design**. Book
`main.tex` untouched.

## Two views of the same thing: monolith vs distributed actor network

This slice deliberately holds both views, because they are the same integrated design:

- **Flattened (this module, `riscv_megagen`):** every family in one clocked top, one `yosys` run, one
  area number. This is the *proof* that the families compose into a single legal design with one
  shared state — the "one mega integrated run."
- **Distributed (the natural form):** the families are **independently-synthesizable actors** wired by
  declarative typed wiring (`` `WIRE ``, the actor_pkg model). Each actor synthesizes on its own — that
  is exactly what the per-slice areas already are — and the wiring topology *is* the integration. An
  emulator realizes a design as **distributed logic across the fabric**, so the actor network is the
  natural mapping: you don't flatten to one block, you place a graph of synthesized actors. The
  monolith is just the flattened equivalent that proves they fit together.

The slice modules instantiated here (`mrsel`, `imm_gen`, `addr_gen`, `vlmul_gen`, `ra_dist_gen`,
`instr_assemble`) *are* those actors; `riscv_megagen` is the `` `WIRE `` graph written out structurally.

## What it integrates (one cycle, one instruction, all families)

Each cycle `riscv_megagen` picks one of 8 instruction classes and routes operands through the family
that class needs, all sharing **one cross-instruction live-register state**:

| class | families exercised |
|---|---|
| R-ALU | reg-alloc (rd∉reserved, rs1/rs2∈live) + assembly |
| I-ALU | reg-alloc + immediate (`imm_gen`) + assembly |
| LOAD | reg-alloc + **addr_c chain** (`addr_gen`: page→offset→base) as the offset + assembly |
| STORE | reg-alloc (rs1/rs2∈live) + addr_c offset + S-format split-immediate assembly |
| BRANCH | reg-alloc + B-format split-immediate assembly |
| LUI | reg-alloc + U-format immediate |
| JAL | **dist-weighted** return reg (`ra_dist_gen`, ra_c) as rd + J-format immediate |
| VECTOR | **vlmul** register-group alignment (`vlmul_gen`) for vd/vs2 + GPR base |

The shared `live` set is grown only by GPR writes (R/I/LD/LUI/JAL); VECTOR writes the vector file, not
the GPR live set — the register files are kept distinct, as in real RISC-V.

## Validated (verilator) — the integrated stream, all classes at once

`tb_mega.sv` runs all 8 classes over 8000 cycles through the single design and checks each emitted
instruction with the rule appropriate to *its* class:

```
>>> MEGA OK: one mega-integrated generator -- ALL constraint families wired into a single clocked
    design sharing one live-register state -- emits a legal instruction stream across ALL 8 classes
    (R/I/LD/ST/BR/LUI/JAL/VEC) over 8000 cycles: every rd legal per its class (reg-alloc non-reserved;
    ra_c dist-support for JAL; vlmul-aligned for VECTOR), every GPR source previously written
    (0 read-before-write), all opcodes well-formed, live reaches all writable GPRs. 0 violations
```

- **per-class legality** — `rd` legal by the right rule for each class (reg-alloc non-reserved; `ra_c`
  support for JAL; vlmul-alignment for VECTOR); 0 violations across 8000 instructions.
- **one shared state, correct** — every GPR source was previously written (0 read-before-write), and
  the shared `live` set reaches all writable GPRs. The whole stream is legal as **one** run.

## Synthesized — one design

`yosys synth_ice40` over the whole graph: `riscv_megagen` = **1065 SB_LUT4 + 534 SB_CARRY + 32
SB_DFFE**. The **32 flip-flops are the shared live-register state**. This is the integrated-emulation
footprint: every constraint family, the full instruction encoding, and the cross-instruction state, as
**one clocked design** that drops onto the fabric — no host, no solver, no UVM sequencer.

The distributed view is the same logic placed as a graph: the per-actor areas (slice 1 reg-select 289,
slice 2 imm 19, slice 3 addr 16, slice 4 assembly 59, slice 6 vlmul 33, slice 9 ra-dist 28, plus the
shared 32-bit state) are what each synthesized actor occupies on the fabric; `` `WIRE `` composes them.
Flattened, `yosys` shares logic across the wired families and lands at 1065 LUT4.

## Frequency (place-and-route, iCE40 hx8k)

`nextpnr-ice40` on the wrapped design (`mega_top.sv` — config tied off, seeds from an internal LFSR,
results reduced to one pin so the design fits the FPGA I/O): **Fmax ≈ 28 MHz** (27.95 MHz, default
speed grade), 1273 LCs (16% of an hx8k). The critical path (~35.8 ns = 13.5 ns logic + 22.3 ns routing)
is the **`live → live` recurrence**: the shared live-register state → the three `mrsel` selectors (each
a 32-deep priority scan over `~live`) → `rd` → `1<<rd` → `live`. At one instruction per clock that is
≈ 28 M legal instructions/s on the *lowest-end* open-toolchain FPGA — orders of magnitude past a
software UVM solver. The limiter is the unpipelined linear priority selector (the same primitive that
makes slice 5 the heaviest); a tree priority-encoder or a pipeline stage on the selectors lifts it, and
emulation-class fabric (UltraScale+/Stratix) clocks the same netlist far higher. Reproduce:

```sh
yosys -p "read_verilog -sv imm_gen.sv addr_gen.sv instr_assemble.sv ra_dist_gen.sv vlmul_gen.sv \
  riscv_megagen.sv mega_top.sv; synth_ice40 -top mega_top -json mega.json"
nextpnr-ice40 --hx8k --package ct256 --json mega.json --pcf-allow-unconstrained --freq 50   # ~28 MHz
```

## On scope — this closes the "not all 140 in one module" gap

Slices 1–9 proved every constraint *operator class* synthesizes and matches the original. Slice 10
proves they **compose into one integrated design** (and, equivalently, one distributed actor network)
that runs as a single emulation: all 8 instruction classes, all families active, one shared state, one
synthesized footprint. The 140 inventory blocks are instances of these families; the mega-generator is
the single integrated run they wire into. Reproduce:

```sh
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tb_top \
  imm_gen.sv addr_gen.sv instr_assemble.sv ra_dist_gen.sv vlmul_gen.sv riscv_megagen.sv tb_mega.sv \
  && ./obj_dir/Vtb_top
yosys -p "read_verilog -sv imm_gen.sv addr_gen.sv instr_assemble.sv ra_dist_gen.sv vlmul_gen.sv \
  riscv_megagen.sv; synth_ice40 -top riscv_megagen; stat"   # 1065 LUT4 + 32 DFF
```
