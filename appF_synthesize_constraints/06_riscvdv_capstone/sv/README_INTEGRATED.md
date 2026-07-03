# 06_riscvdv_capstone / slice 13: end-to-end integrated generator + measured integrated Fmax

The solve-once allocator (slice 12) **wired into** the mega generator (slice 10), as one clocked
design, with the integrated Fmax measured by place-and-route. Book `main.tex` untouched.

## Wiring (no module changes)

`integrated_top.sv`:
- **Setup (once):** a one-shot `start` (as reset deasserts) runs `uniqreg_seq` for 10 cycles → solves
  `avail_regs` (10 distinct non-reserved registers), held.
- **Wire:** `avail_mask` = OR of the held registers; `riscv_megagen.reserved` is registered to
  `~avail_mask`, so the generator's `mrsel(reserved)` selects **only avail registers** — the allocator's
  output drives the generator's operand pool with no change to either module. `init_live` is one avail
  register, so sources stay within `avail_regs`.
- **Run:** `riscv_megagen` emits instructions (all 8 classes) drawing operands from `avail_regs`.

Validated (verilator): the allocator reaches `done` and the generator runs with the output active.

## Measured integrated Fmax (nextpnr-ice40, hx8k)

```
integrated_top: Fmax = 22.80 MHz,  2628 ICESTORM_LC (34% of an hx8k)
critical path  = 43.9 ns (16.0 logic + 27.9 routing): gen.live -> mrsel -> rd -> 1<<rd -> gen.live
```

- **The critical path is the mega's per-instruction `live → mrsel → live` source-selection loop** — the
  *same* bottleneck as standalone `riscv_megagen` (28 MHz), a bit lower here (22.8) purely from routing
  congestion in the larger integrated design (34% utilization vs 16%).
- **The solve-once allocator is OFF the critical path** — its `reg_select_ex` path is shorter than the
  mega's live-loop. Concrete confirmation that the unique-allocation does not gate throughput: it is
  solved once at stream start (10-cycle setup, amortized) and then held/reused.

So the integrated generator emits **~22.8 M legal instructions/second** (one per clock) on the
lowest-end open-toolchain FPGA, with the whole constraint-stimulus pipeline — operand allocation,
per-instruction selection, immediates, addressing, vector LMUL, dist, assembly, cross-instruction state
— as one synthesized design. The remaining Fmax lever is the `mrsel` source selector (tree-encode /
pipeline); the allocator is settled.

## Fmax summary across the capstone

| block | Fmax (hx8k) | role |
|---|---|---|
| `riscv_megagen` (generator alone) | 28.0 MHz | per-instruction (mrsel live-loop) |
| `uniqreg_seq` (solve-once allocator) | 24.1 MHz | one-time setup, amortized (off critical path) |
| `shuffle10` (per-randomize reuse, full 10-perm) | 8.0 MHz | reuse held set (partial/pipeline → higher) |
| **`integrated_top` (allocator + generator)** | **22.8 MHz** | **end-to-end, gated by mrsel** |

Reproduce:

```sh
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tb_top \
  imm_gen.sv addr_gen.sv instr_assemble.sv ra_dist_gen.sv vlmul_gen.sv riscv_megagen.sv \
  uniqreg_seq.sv integrated_top.sv tb_integrated.sv && ./obj_dir/Vtb_top
yosys -p "read_verilog -sv imm_gen.sv addr_gen.sv instr_assemble.sv ra_dist_gen.sv vlmul_gen.sv \
  riscv_megagen.sv uniqreg_seq.sv integrated_top.sv; synth_ice40 -top integrated_top -json i.json"
nextpnr-ice40 --hx8k --package ct256 --json i.json --pcf-allow-unconstrained --freq 50   # 22.8 MHz
```
