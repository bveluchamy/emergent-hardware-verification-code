# 03_reactive_constraints — reactive constraints and a propagation network

Companion code for **Appendix F, "Synthesizing Constrained-Random Stimulus."**
`02_constructive_samplers/` compiles a *fixed* constraint straight to a datapath.
This directory covers the cases that need more than one static draw: a **reactive**
constraint, whose legal set depends on live design state, and a **propagation
network**, a relational constraint solved by local all-different propagation with no
search. It also carries the appendix's **Tier-2** arithmetic sampler (`A*B < LIMIT`)
in its multi-cycle and fully-pipelined forms.

## How it maps to the appendix

Appendix F sorts constraints into three tiers of construction by shape (§"Three tiers
of construction"); the static Tier-0/1 datapaths live in `02_constructive_samplers/`.
The examples here are the cases past a single static draw:

| directory | idea in Appendix F | what it is |
|---|---|---|
| `axi_aw/` | reactive constraint — the legal set moves with design state | AXI4 write-address generator: 4KB-boundary coupling, WRAP alignment, `awsize` cap, and issuance gated on which IDs are free right now (`id_free`, a live input) |
| `sudoku_net/` | a constraint solved as a distributed graph (§"One design, or a distributed graph") | 4×4 Sudoku as 16 cell actors doing all-different propagation to a fixpoint — arc-consistency as message-passing, no search stack |
| `pipelined_div/` | Tier 2 — invert, don't bit-blast | `A*B < LIMIT` sampled by inverting the bound with an iterative shift-subtract divider — one legal pair per multi-cycle burst |
| `tier2_pipelined/` | Tier 2, at full rate | the same sampler on a fully-pipelined divider — one legal pair every cycle (its own README) |

## Running

Needs `verilator` (5.x) on `PATH`; the area and Fmax figures also need `yosys` and
`nextpnr-ice40`. `rm -rf obj_dir` cleans a build.

`./run_all.sh` builds and runs `axi_aw`, `sudoku_net`, and `pipelined_div`, and prints
each one's synthesis numbers. To build one on its own, from this directory:

```sh
( cd axi_aw && verilator --binary -j 0 --timing --top-module tb_top \
      axi_aw_sampler.sv tb_top.sv && ./obj_dir/Vtb_top )

( cd sudoku_net && verilator --binary -j 0 --timing -Wno-WIDTHEXPAND --top-module tb_top \
      sudoku4_net.sv tb_top.sv && ./obj_dir/Vtb_top )

( cd pipelined_div && verilator --binary -j 0 --timing -Wno-WIDTHEXPAND --top-module tb_top \
      seq_div.sv pdiv_sampler.sv tb_top.sv && ./obj_dir/Vtb_top )
```

`tier2_pipelined/` has its own README and build line.

## What each example shows

**`axi_aw/` — the reactive case.** The legal AXI4 fields are drawn constructively
(never generated and then rejected): the 4KB rule couples address, length, and size; a
WRAP burst gets a legal `awlen` and an aligned address; `awsize` is capped at the bus
width. What makes it *reactive* is the final gate — a transaction is issued only when
the drawn `awid` is currently free, and `id_free` is a live DUT input. A static table
cannot express this, because the legal set changes cycle to cycle. Expected output:

```
requests=200000 issued=124623 gated(reactive)=75377 illegal=0
```

Every issued beat is legal; the rest were withheld because their ID was busy. The
testbench carries a full legality checker beside the generator — the same constraint
serves twice, to drive stimulus and to check it. Reference area: ~219 LUT4 on an iCE40.

**`sudoku_net/` — the propagation network.** Sixteen cell actors, each holding a 4-bit
candidate set. Each cycle a cell drops from its set every value a peer (same row,
column, or 2×2 box) has already pinned to a single candidate; the sets shrink
monotonically to a fixpoint. There is no search and no backtracking — only fixed peer
wiring and sixteen small FSMs, which is arc-consistency propagation rendered directly
as gates. Expected output:

```
converged in 2 cycles  done=1 contra=0  VALID=1
```

This is the appendix's "distributed graph": one constraint solved by a mesh of
independently-synthesizable cells, the shape an emulator places across its fabric.

**`pipelined_div/` and `tier2_pipelined/` — Tier 2, invert don't bit-blast.** The
constraint `A*B < LIMIT` contains a multiply that would explode if flattened to gates.
The sampler inverts it instead: draw `A`, compute the bound `(LIMIT-1)/A` with a
divider, then place `B` in `[0, bound]` with a Lemire multiply-shift. `pipelined_div/`
uses an iterative shift-subtract divider whose critical path is a single subtract, so it
holds a high clock but takes a burst of cycles per sample; `tier2_pipelined/` unrolls
that divider into a pipeline so one legal pair emerges every cycle. Both emit only legal
pairs:

```
pipelined_div:   samples=3000   violations=0 cycles=108000  (~36 cyc/sample, burst)
tier2_pipelined: samples=100000 violations=0 cycles=100032  (1.00 cyc/sample)
```

Latency versus throughput on the identical construction — see `tier2_pipelined/README.md`
for the pipelined divider.

## What to read

- `axi_aw/axi_aw_sampler.sv` — the constructive field draws, and the one
  `if (id_free[id_c])` gate that makes issuance reactive.
- `sudoku_net/sudoku4_net.sv` — the `forbidden[]` peer-union loop; the whole solver is
  that plus `domain <= domain & ~forbidden`.
- `pipelined_div/seq_div.sv` and `tier2_pipelined/pipe_div.sv` — the iterative and
  pipelined forms of the same shift-subtract divider.
