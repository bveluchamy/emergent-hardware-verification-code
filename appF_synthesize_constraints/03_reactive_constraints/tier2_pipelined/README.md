# tier2_pipelined — the Tier-2 divider at one sample per cycle

Companion code for **Appendix F, "Synthesizing Constrained-Random Stimulus."** A
fully-pipelined shift-subtract divider for the Tier-2 `A*B < LIMIT` sampler: a new
dividend enters every cycle and a quotient leaves every cycle once the pipe is full, so
the sampler emits one legal `(A,B)` pair per clock. It is the full-throughput form of
the iterative divider in `../pipelined_div/`, which produces one pair per multi-cycle
burst.

## How it maps to the appendix

This is Appendix F's **Tier 2 — invert, don't bit-blast**. `A*B < LIMIT` holds a
multiply that would explode as Boolean gates, so the sampler inverts the relation: it
computes the bound `(LIMIT-1)/A` with the divider, then places `B` in `[0, bound]` with
a Lemire multiply-shift. Unrolling the divider into a pipeline trades area for a legal
sample every cycle instead of every burst.

## Running

Needs `verilator` (5.x) on `PATH`:

```sh
verilator --binary -j 0 --timing -Wno-WIDTHEXPAND --top-module tb_top \
    pipe_div.sv psamp.sv tb_top.sv
./obj_dir/Vtb_top
```

Expected output (the trailing 32 cycles are the pipeline fill):

```
samples=100000 violations=0 cycles=100032 (1.00 cyc/sample)
```

For the iCE40 area and Fmax, synthesize and place with the same flow `../run_all.sh`
runs on the other examples:

```sh
yosys -p "read_verilog -sv pipe_div.sv psamp.sv; synth_ice40 -top psamp -json psamp.json"
nextpnr-ice40 --hx8k --package ct256 --json psamp.json --freq 100 --seed 1
```

Reference figures on an iCE40 HX8K: ~49 MHz, ~2173 LUT4 (about half of the part).

## What to read

- `pipe_div.sv` — the `generate` loop builds `W` identical stages, each a single
  `(W+1)`-bit subtract/compare, so the critical path is one subtract regardless of
  operand width. The `valid` flag and the operands ride the pipe alongside the partial
  quotient in `v[]`, `n[]`, `d[]`.
- `psamp.sv` — `A` streams into the divider every cycle; `A` and the `B` seed are
  delayed `W` cycles (`aDel[]`, `bDel[]`) so they realign with the bound as it emerges
  from the pipe. `B = (rng_B * span) >> 16` is the Lemire step; `span = bound + 1`.

## Divider styles for `A*B < LIMIT`

| style | throughput | Fmax (iCE40) | area | note |
|---|---|---|---|---|
| combinational (`02_constructive_samplers/`) | 1 / cycle | ~3.8 MHz | medium | simplest; low clock |
| iterative (`../pipelined_div/`) | 1 / ~36 cycles | ~50 MHz | small | area-critical, no DSP |
| pipelined (this) | 1 / cycle | ~49 MHz | ~2173 LUT4 | full rate at emulation clock |

An emulated SoC typically runs at 1–2 MHz, so one legal pair per cycle at ~49 MHz keeps
the stimulus generator well ahead of the design under test — it can feed a faster clock
domain or fan out to several DUT instances and still keep up. The ~2173-LUT4 footprint
is a large fraction of this small no-DSP part but negligible on an emulation-class FPGA.
