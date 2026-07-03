# 03_reactive_constraints: reactive / closed-loop constraint stimulus (research sandbox)

Builds on the open-loop samplers of 02_constructive_samplers. Here the legal set depends on **live DUT
state**, so the static-LUT / precompute path stops working — see **`BRAINSTORM.md`**
for the full architecture (reactivity taxonomy, network-of-actors, pipelined bursts,
emulator-memory strategies, hardware SAT, and 8 real-world examples).

**The book (`main.tex`) is untouched.** Reproduce: `./run_all.sh`.

## Built POCs (validated + measured)

| dir | idea | result |
|---|---|---|
| `axi_aw/` | AXI4 write-address, **reactive** (4KB-boundary coupling, WRAP alignment, size cap, **live `id_free` gating**) | 200k req → 124,623 issued **0 illegal**, 75,377 withheld on live state; **219 LUT4** (iCE40) |
| `sudoku_net/` | 4×4 Sudoku as a **network of 16 cell-actors** doing closed-loop constraint propagation | **converged 2 cycles, solution VALID**; arc-consistency as a synthesizable systolic network |
| `pipelined_div/` | 32-bit `A*B<LIMIT` with an **iterative divider** (multi-cycle burst) | 3000 samples **0 violations**, ~36 cyc/sample, **50.7 MHz** (vs 3.8 MHz combinational — 13×) |
| `tier2_pipelined/` | the same, **fully pipelined** (1 sample/cycle) | 100k samples **0 violations**, **1.00 cyc/sample, 49.1 MHz**, 2173 LUT4 — see its README |

The AXI checker caught a real generator bug live (unaligned INCR base crossing a 4KB
boundary) — the checker-vs-generator duality in action.

## Performance — emulation throughput (why the stimulus is never the bottleneck)

A real SoC emulates at **1–2 MHz**. Every constraint tier compiles to a sampler that
runs *far* faster than that, so the stimulus generator can never gate the emulation —
it can drive a faster clock domain, or fan out to many parallel DUT instances, and
still keep up trivially. Design policy: **Fmax-first** (sacrifice clock only if area is
genuinely excessive, which on a real emulation FPGA it never is).

| tier | mechanism | throughput | **Fmax (iCE40)** | vs 1–2 MHz DUT |
|---|---|---|---|---|
| Tier-0 | constructive datapath | 1/cycle | native (fast) | ≫ |
| Tier-1 | BDD unrank + **multiply-shift** range reduction | O(#bits)/sample | **97 MHz** | ≫ |
| **Tier-2** | constructive arith + **pipelined divider** | **1/cycle** | **49 MHz** | **25–50×** |
| dist | weighted CDF + multiply-shift | 1/cycle | 50 MHz | ≫ |

Key optimizations (all measured): the **Lemire multiply-shift** replaces the
constant-modulo range reduction → **Tier-1 44.8 → 97 MHz, area-neutral**; the
**pipelined divider** gives Tier-2 **1 sample/cycle at 49 MHz** (49 M legal
constrained samples/s vs a 1–2 MHz DUT). The slow primitives (3.8 MHz combinational
divider, the modulo) are retired; the iterative divider stays as the small-footprint /
no-DSP option. On a real emulation fabric (DSP blocks, millions of LUTs) every figure
here is faster and the areas are noise.

Two design facts that fell out of the performance work: **`dist` is optional** (a
coverage-efficiency knob, not legality — replaceable by closed-loop coverage feedback),
and the **LFSR seed *is* the replay trace** (16 bits reproduces the entire stream;
the trace actor is the complementary full-graph replay).

Sketched (in `BRAINSTORM.md`): RISC-V instruction stream (riscv-dv shape),
credit/FIFO-gated traffic, packet header→payload actor pipeline, MSI cache-coherence
legal-transition generator, OpenTitan CSR sequences.
