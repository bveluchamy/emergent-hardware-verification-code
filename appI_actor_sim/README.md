# Actor-Based Hardware Simulator (`actor_sim`)

A working prototype demonstrating that the actor model can replace
event-driven simulators (Verilator/VCS) for the synthesizable subset of
SystemVerilog. Each module is an actor; each wire is a typed channel;
each clock edge is a broadcast message; flip-flops use two-phase NBA
semantics — no centralized event queue.

See Appendix I of *Emergent Functional Verification with SystemVerilog*
(`appendix_actor_sim.tex` at the repo root) for the full discussion.

## What's here

| File | Purpose |
|------|---------|
| `actor_sim.h`     | Header-only simulator core: `Bits<W>`, `Signal<W>`, `Module`, `DFF<W>`, `CombLogic`, `Sim`, `TestHarness` |
| `vcd_writer.h`    | Standard VCD waveform output (opens in GTKWave) |
| `test_mux2to1.cpp`| 2:1 mux — pure combinational |
| `test_dff.cpp`    | D flip-flop with sync reset |
| `test_counter.cpp`| 4-bit counter with enable (Q→combo→D feedback) |
| `test_shiftreg.cpp`| 4-stage shift register (validates two-phase NBA) |
| `test_alu.cpp`    | 4-bit ALU with zero flag |
| `test_fsm_arbiter.cpp`| Moore-style round-robin arbiter FSM (Ch.2) |
| `test_fifo.cpp`   | 8-bit FIFO, depth 4, with full/empty + VCD output |
| `Makefile`        | Build & run all tests |

Each test file has the equivalent SystemVerilog at the top as a comment.

## Build & run

```sh
cd appI_actor_sim
make test          # build and run all 7 tests; reports pass/fail
make clean         # remove built binaries and VCDs
```

Or from `actor_pkg/`:

```sh
make sim           # runs the same target
```

Expected output:

```
--- test_mux2to1 ---     [mux2to1] 7/7 checks passed   PASS
--- test_dff ---         [dff] 6/6 checks passed       PASS
--- test_counter ---     [counter4] 7/7 checks passed  PASS
--- test_shiftreg ---    [shiftreg] 12/12 checks       PASS
--- test_fsm_arbiter --- [fsm_arbiter] 10/10 checks    PASS
--- test_alu ---         [alu] 22/22 checks passed     PASS
--- test_fifo ---        [fifo4] 20/20 checks passed   PASS
                         VCD waveform written to test_fifo.vcd

ALL TESTS PASSED  (84/84 checks)
```

## Viewing the FIFO waveform

```sh
gtkwave test_fifo.vcd
```

Add `top.dut.*` signals to the wave panel to see push/pop traffic,
the `count` value, and the `full`/`empty` flags through the test
sequence.

## Writing a new design

Three primitives cover ~90% of synthesizable RTL:

```cpp
#include "actor_sim.h"
using namespace actor::sim;

Sim sim;

// 1. Declare typed signals (your "wires")
auto* a    = sim.signal<8>("a");
auto* b    = sim.signal<8>("b");
auto* sum  = sim.signal<8>("sum");
auto* q    = sim.signal<8>("q");

// 2. Combinational logic via a lambda with explicit sensitivity list
sim.comb("adder",
    [=]() { sum->write(Bits<8>((uint64_t)a->read() + (uint64_t)b->read())); },
    {a, b});

// 3. Flip-flops via DFF<W>
sim.add<DFF<8>>("acc_ff", sum, q, Bits<8>(0));

// 4. Drive stimulus
sim.reset();
a->write(Bits<8>(3));
b->write(Bits<8>(4));
sim.tick();                       // q now holds 3+4 = 7
assert(q->read() == Bits<8>(7));
```

For stateful or complex modules, subclass `Module` directly and put
state inside the class — see `test_fifo.cpp` for an example.

## What works now

- Compile-time-typed bitvectors `Bits<W>` for W ∈ [1, 1024]
- Single-driver, multi-reader typed signals with subscriber tracking
- D flip-flops with two-phase NBA semantics (proven by `test_shiftreg`)
- Combinational logic with sensitivity lists, propagation to fixpoint
- Synchronous reset broadcast
- Self-checking test harness with pass/fail summary
- VCD waveform output compatible with GTKWave / ModelSim / Verdi
- Combinational-loop detection (throws after 200 unconverged iterations)

## Roadmap (Appendix I §"Path to Verilator Parity")

- **SystemVerilog front-end** — parse SV source, lower to actor topology
- **Multi-threaded scheduler** — leverage the existing
  `actor::cpp::Actor` infrastructure for per-actor mailboxes
- **Four-state logic** — add X-mask alongside `Bits<W>` for `{0, 1, X, Z}`
- **FPGA backend** — synthesizable-subset rules from Appendix E
- **GPU backend** — actors as CUDA kernels, mailboxes in GPU memory
- **SVA support** — temporal property actors
