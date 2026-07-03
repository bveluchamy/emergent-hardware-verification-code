# 06_riscvdv_capstone / slice 7: the full instruction STREAM actor network (the integration), synthesized

The slices so far are per-constraint-family samplers. Slice 7 is the **integration**: it WIRES them
into one actor that produces a *stream* of instructions while carrying **cross-instruction state** —
the thing a flat per-instruction generator cannot do, and the reason UVM needs a stateful sequencer.
Book `main.tex` untouched.

## What it is

`stream_gen` is a **clocked actor** (actor == synthesizable FSM — the Chapter 6 thesis). Each cycle it
emits one R-type instruction by wiring together the per-slice samplers, and it threads a **live
register set** across the stream so a source register is never read before it has been written
(riscv-dv's GPR-initialization discipline):

```
  per cycle:
     rd  = rsel(reserved, seed_rd)        // slice-1 reg-alloc: idx-th non-reserved register
     rs1 = rsel(~live,    seed_rs1)        // idx-th register that is ALREADY LIVE  (cross-instr read)
     rs2 = rsel(~live,    seed_rs2)
     op  = op_table[seed_op]               // slice-1 R-type op select
     instr = {f7, rs2, rs1, f3, rd, opcode}   // slice-4 R-type assembly
  state update:
     live <= live | (1 << rd)              // rd becomes live AFTER it is written (the dependency)
```

The `live` set is the actor's **state** — a 32-bit register, loaded at reset with the initialized
GPRs (`init_live`) and grown by every instruction's `rd`. The source samplers draw from `live` (via
`rsel(~live, …)` — the idx-th set bit of `live`), so **no read-before-write is structural**: an
instruction can only read registers that earlier instructions (or the init set) already wrote.

This is the whole point of the capstone — not six isolated samplers, but one **actor network with
memory** that produces a legal, dependency-correct instruction *sequence*.

## Validated (verilator) — both directions, across the stream

`tb_stream.sv` runs a 2000-instruction stream two ways and checks the same invariant on both:

1. the **synthesized clocked actor** (the `live` register threaded by the hardware);
2. a **`randomize()`-driven reference** — `stream_orig` (`rd` non-reserved, `rs1/rs2 inside {live_q}`),
   where the testbench threads the live set across the stream (the reference's per-step constraint).
   Verilator solves it 2000/2000 (it supports `inside {queue}` in `randomize()`).

```
>>> STREAM OK: full instruction stream actor network -- synthesized clocked actor and
    randomize()-driven ORIGINAL BOTH thread the live-register set across 2000 instructions with
    ZERO read-before-write (every source register previously written/init), both write all 27
    writable registers {5..31}, both reach live=all-writable, 0 illegal each
```

- **the cross-instruction invariant holds, both ways** — across 2000 instructions, every `rs1`/`rs2`
  was previously written or in the init set (`live[rs1] && live[rs2]`), and every `rd` is
  non-reserved. 0 violations from the synthesized stream *and* the randomize-driven reference.
- **same reachable state** — both streams write all 27 writable registers `{5..31}` and both converge
  to `live = 0xFFFFFFE0` (all writable registers live). The state evolution matches.

## Synthesized

`yosys synth_ice40`: `stream_gen` = **900 SB_LUT4 + 32 SB_DFF + 130 SB_CARRY**. The **32 flip-flops
are the `live` state** — the cross-instruction memory, in hardware. This is the capstone's structural
claim made concrete: the testbench's stimulus generator, *including its sequential state*, is a
clocked FSM that drops onto the fabric — no solver, no host, no UVM sequencer. The combinational cost
(~900 LUT4) is the three register samplers + op-table + assembly; the sequential cost (32 DFF) is the
live-set the stream carries.

## Coverage note

Slice 7 closes the integration: slices 1–6 proved every riscv-dv constraint *shape* synthesizes and is
equivalent to the original; slice 7 wires them into one **stateful actor** that emits a legal,
dependency-correct instruction *stream* and synthesizes to a clocked FSM whose flip-flops are the
cross-instruction state. Both directions validated against `randomize()`. Reproduce:

```sh
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tb_top \
  stream_orig.sv stream_gen.sv stream_checker.sv tb_stream.sv && ./obj_dir/Vtb_top
yosys -p "read_verilog -sv stream_gen.sv; synth_ice40 -top stream_gen; stat"   # 900 LUT4 + 32 DFF
```
