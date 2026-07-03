# 06_riscvdv_capstone / slice 8: sim ≡ fabric — the same authored actor, two renderings

Slice 7 synthesized the stream actor to a clocked FSM (`stream_gen.sv`). Slice 8 closes the loop to
the book's Chapter 6 actor framework: it shows that FSM is **one rendering** of an actor whose **other
rendering** is an ordinary `actor_pkg` SV class — same authored definition, different substrate, **no
rewrite**, and **bit-identical behavior**. Book `main.tex` untouched.

## What it is

`actor_stream.sv` defines `StreamActor extends Actor` (the book's `actor_pkg`, Chapter 6). It is the
**simulation rendering** of the same actor whose **fabric rendering** is `stream_gen.sv` (slice 7):

| | simulation rendering | fabric rendering |
|---|---|---|
| form | `StreamActor extends Actor` (SV class) | `stream_gen` (RTL, synthesized) |
| state | `logic [31:0] live` class member | 32 flip-flops |
| step | `step()` method | one clock cycle |
| selection | `reg_select()` function | `rsel` module |
| op table | `op_funct()` function | `case` in `always_comb` |

The two are **not a re-implementation** — they are the *same actor* expressed in the two forms the
substrate requires. The memory note for this project states it exactly: *the SV class is just the sim
rendering, not "the actor"; the whole testbench graph synthesizes onto the emulator.* Slice 8 makes
that literal.

## Validated (verilator) — bit-identical, both renderings

`tb_actor_stream.sv` runs the `StreamActor` class and the `stream_gen` RTL **in lockstep** over the
same 2000-cycle seed sequence and compares the emitted 32-bit instructions:

```
>>> ACTOR OK: sim==fabric -- the actor_pkg StreamActor (SV-class rendering) and stream_gen
    (synthesized FSM rendering) of the SAME authored actor emit BIT-IDENTICAL instructions over
    2000 cycles, and reach the SAME cross-instruction state (live=ffffffe0). One actor, two
    substrate renderings, no rewrite
```

- **bit-identical** — every one of 2000 instructions from the SV-class rendering equals the instruction
  from the synthesized FSM rendering, exactly.
- **same state evolution** — both reach `live = 0xFFFFFFE0` (all writable registers live); the
  cross-instruction state the class holds in a member variable and the FSM holds in 32 flip-flops
  evolve identically.

> The lockstep tb drives seeds with a `#1` separation from the clock edge so the RTL's state-update
> samples the same seed as the captured instruction (otherwise a seed/`posedge` race makes the FSM's
> `rd` occasionally latch the next cycle's seed — a testbench artifact, not a rendering difference).

## Why this matters for the capstone

This is the structural claim the whole capstone exists to make: **the stimulus generator is an actor,
and an actor is a synthesizable FSM.** UVM's constrained-random generator runs only on a host solver;
the actor here is authored once and runs

- as an `actor_pkg` SV class in a normal simulation (this slice), and
- as a synthesized clocked FSM on the emulation fabric (slice 7, 900 LUT4 + 32 DFF),

with the two provably identical. No solver, no host hand-off for the stimulus — the testbench graph,
including its sequential state, *is* hardware. (No synthesis number for this file: it is the simulation
rendering; its fabric rendering's area is slice 7's.)

## Coverage note

Slice 8 connects the capstone to the book's `actor_pkg` and closes the sim≡fabric loop. Reproduce:

```sh
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tb_top \
  ../../../actor_pkg/actor_pkg.sv actor_stream.sv stream_gen.sv tb_actor_stream.sv && ./obj_dir/Vtb_top
```
