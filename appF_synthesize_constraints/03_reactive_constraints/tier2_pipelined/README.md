# tier2_pipelined: fully-pipelined Tier-2 divider (1 sample / cycle)

Per the Fmax-first policy: a fully-pipelined shift-subtract divider for the
constructive `A*B < LIMIT` sampler. A new dividend streams in every cycle; `A`
and `rng_B` are delayed `W` cycles to realign with the emerging bound; B is the
Lemire multiply-shift. **One legal `(A,B)` per cycle** at the emulator clock --
the burst latency of the iterative version is gone.

`verilator --binary -j 0 --timing -Wno-WIDTHEXPAND --top-module tb_top
pipe_div.sv psamp.sv tb_top.sv`.

## Result (iCE40 HX8K)

- **100,000 samples, 0 violations, 1.00 cycle/sample** (the 32 extra cycles are pipe fill).
- **49.06 MHz, 2173 LUT4 (47% of the part).**

## Tier-2 divider styles (`A*B<LIMIT`)

| style | throughput | Fmax | area | when |
|---|---|---|---|---|
| combinational (02_constructive_samplers) | 1/cycle | 3.8 MHz | medium | never (too slow for an emul clock) |
| iterative (`pipelined_div` in 03_reactive_constraints) | 1/36 cyc | 50.7 MHz | small | area-critical / no-DSP |
| **pipelined (this)** | **1/cycle** | **49.1 MHz** | 2173 LUT | **full rate, Fmax-first default** |

## Why this is enormous in practice

A real SoC emulates at **1–2 MHz**. This generator runs at **49 MHz × 1 sample/cycle
= ~49 M legal constrained samples/second** -- a **25–50× headroom** over the DUT. The
stimulus can never be the bottleneck: it can feed a faster clock domain, or fan out to
many parallel DUT instances, and still keep up trivially. The 47% iCE40 utilisation is
an artifact of a tiny no-DSP part; on a real emulation FPGA (millions of LUTs +
thousands of DSP blocks) this divider is noise and runs faster still.
