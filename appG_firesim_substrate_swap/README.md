# 14 — Every testbench actor is synthesizable (actor model on FireSim)

This example makes the book's central claim runnable and validated:

> An **actor is a finite state machine**; FSMs are synthesizable; therefore
> **every actor is synthesizable** — not just the DUT, but the stimulus, the
> scoreboard, and the coverage too. The same authored actor (its state, its
> message handler, its `` `WIRE `` wiring) is *rendered* per substrate: a
> software object for fast simulation, or synthesizable RTL/gates for an FPGA /
> emulator / silicon. So the **whole verification loop goes onto the fabric** and
> runs at hardware speed. The host is left with only the final read-out.

There is **no proxy in the verification loop.** A proxy/bridge actor earns its
place at exactly one spot — a genuine software↔hardware communication seam (the
host reading status, external I/O, or a network link between nodes where one
side is software). Everything else is on the fabric.

## Stage 0 — validated here, with no FPGA

`make run` builds the **entire** verification loop as synthesizable RTL
(`tb_fabric.sv`) under Verilator, and runs the **same** authored actors rendered
as C++ objects (`demo_actors.h`) for comparison:

```
=== same verification actors, two substrates ===
    every testbench actor is an FSM -> synthesizable; run B puts the
    entire stimulus/DUT/scoreboard/coverage loop on the fabric.

  [software substrate (actors as C++ objects)    ]  checks=256 fails=0 coverage=8/8  PASS
  [hardware substrate (whole loop on the fabric)  ]  checks=256 fails=0 coverage=8/8  PASS

SUBSTRATE SWAP OK: identical verification; run B is the whole testbench on the fabric.
```

In run B the host does **not** drive transactions. It resets the fabric, clocks
it, and reads the final `checks/fails/covered/done` counters — the single
software↔hardware seam. The stimulus, the DUT, the scoreboard, and the coverage
all run on the fabric.

Three independent validations (run them yourself):

| Command | What it proves |
|---|---|
| `make lint`  | all five modules are clean SystemVerilog (Verilator `-Wall`, 0 warnings) |
| `make synth` | **every actor maps to gates** (yosys), not just the DUT: |
| `make run`   | the whole-fabric loop gives identical results to the software actors |

`make synth` output (flip-flops = each actor's state):

| actor | cells | flip-flops |
|---|---|---|
| `stimulus_actor`   |  49 |  26 — LFSR(16) + count(9) + done(1) |
| `accumulate_actor` | 197 |  33 — sum(32) + out\_valid(1) |
| `scoreboard_actor` | 869 | 231 — golden(32) + 4×32 expected-FIFO + pointers + checks/fails |
| `coverage_actor`   |  55 |   8 — the eight buckets |

The scoreboard and coverage are flip-flops + logic just like the DUT. The
verification environment is hardware, not host software.

### Files

| File | Role | Substrate |
|---|---|---|
| `stimulus_actor.sv`   | LFSR stimulus actor (FSM, ready/valid out)              | RTL / FPGA |
| `accumulate_actor.sv` | the DUT actor (FSM, ready/valid in+out)                 | RTL / FPGA |
| `scoreboard_actor.sv` | golden model + expected-FIFO + checker (FSM)            | RTL / FPGA |
| `coverage_actor.sv`   | eight-bucket coverage (FSM)                             | RTL / FPGA |
| `tb_fabric.sv`        | wires the four actors into one synthesizable loop       | RTL / FPGA |
| `demo_actors.h`       | the **same** actors rendered as C++ objects (substrate swap) | software |
| `main.cpp`            | runs the two substrates and compares                   | — |

## Stages 1–2 — the same fabric on FireSim (see `./firesim/`)

`./firesim/` scaffolds the move onto the open-source FireSim platform: the
**whole `tb_fabric`** becomes the FireSim *target* (on the FPGA), and a single
peek/poke bridge lets the host read the status counters — the one seam. The
verification loop does not change; only the substrate underneath it does.

- **Stage 1 — FireSim metasimulation (no FPGA).** The fabric is FAME-transformed
  and run in Verilator; FireSim guarantees this is bit-/cycle-exactly what an
  FPGA run produces.
- **Stage 2 — FPGA (AWS F1 / on-prem Alveo).** The identical fabric builds to a
  bitstream and runs at MHz.

## Why this needs FireSim (and not a commercial emulator)

Demonstrating this requires source access to prove the synthesized actors are
bit-for-bit the software actors, a platform anyone can rerun, and a way to prove
it with no hardware (metasimulation). The closed commercial emulators
(Palladium/ZeBu/Veloce) give you none of these — sealed transactor IP,
million-dollar scarce boxes, and no metasimulation of the bridge stack. FireSim,
being open, is the one platform where this demonstration is even possible.
