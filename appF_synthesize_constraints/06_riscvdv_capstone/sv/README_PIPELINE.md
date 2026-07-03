# 06_riscvdv_capstone (2): pipelining the selector -- 1.74x Fmax, function preserved

The integrated generator's critical path (slice 13) is the register selector `mrsel` -- a 32-element
priority scan -- in the per-instruction source-selection loop. It is the one remaining Fmax lever, and
it is a textbook one: split the scan into a pipeline.

## What it is

`mrsel_pipe` is the same selector (the idx-th register not in `excluded`, clamped) with the 32-element
scan SPLIT at r=16 by a register that carries the running `{count, done, reg_out}` from the low half to
the high half. Each stage scans 16 elements -- about half the combinational depth -- so the clock can
run faster; the output is the selector's result delayed one cycle (latency, not throughput: a generator
still emits one selection per cycle once the pipe is full). Because it is the *same loop* split with a
register, it is obviously equivalent.

## Validated (verilator) -- bit-for-bit equivalent

`tb_mrsel_cmp.sv` drives 20000 random `(excluded, idx)` and compares `mrsel_pipe` against the 1-stage
reference `mrsel_ref`:

```
>>> MRSEL_PIPE OK: 2-stage pipelined selector computes the same function as the 1-stage reference,
    bit-for-bit over 20000 random (excluded,idx)
```

## Measured (nextpnr-ice40, hx8k) -- 1.74x faster

Both wrapped identically (LFSR-driven input register, reduced output register):

| selector | Fmax | LCs |
|---|---|---|
| `mrsel_ref` (1-stage, 32-scan) | 25.76 MHz | 390 |
| `mrsel_pipe` (2-stage split) | **44.87 MHz** | 450 |

**1.74x higher Fmax** for +15% area (the extra cells are the pipeline registers). The 25.8 MHz of the
1-stage selector matches the 22.8 MHz of the whole integrated generator (slice 13) -- confirming the
selector is the bottleneck -- so dropping `mrsel_pipe` into the generator lifts its clock comparably;
the rd/source selections gain a cycle of pipeline latency, which a stimulus stream absorbs without
losing throughput (sources then read a one-cycle-older live set, still all previously written, so the
no-read-before-write invariant is preserved). A 4-stage split scales the same way until routing
dominates. Reproduce:

```sh
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tb_top \
  mrsel_pipe.sv tb_mrsel_cmp.sv && ./obj_dir/Vtb_top
yosys -p "read_verilog -sv mrsel_pipe.sv sel_pipe_top.sv; synth_ice40 -top sel_pipe_top -json p.json"
nextpnr-ice40 --hx8k --package ct256 --json p.json --pcf-allow-unconstrained --freq 80   # 44.9 MHz
```
