# Appendix F — Synthesizing Constrained-Random Stimulus: the riscv-dv capstone

Companion code for Appendix F, *Synthesizing Constrained-Random Stimulus*, §"The capstone:
a production constraint corpus on fabric." It takes the constraint set of **riscv-dv** — an
open-source RISC-V instruction-stream generator — and compiles **every constraint shape it
uses** into a *constructive sampler*: a small synthesizable datapath that emits legal
stimulus directly, with no runtime solver on the fabric. Each sampler is run against the
reference solver on the *same* constraint, both directions — every value the sampler emits
is accepted by the original constraint (soundness), and the two reach the same legal set
(completeness).

The premise (Appendix F): `randomize()` only ever *finds a model* — it never has to prove
that no solution exists, which is the expensive, refuting half a proof engine does
(Chapter 3). The model-finding half is constructive, a constructive result can be settled
once ahead of the run, and what it compiles to is ordinary synthesizable logic. This
directory is the production-scale demonstration of that idea on a real generator.

## How it maps to the book

Appendix F argues that the constraint solver — the part of a testbench usually assumed to
strand it on a host — has a synthesizable form. This directory is the capstone that claim
rests on: riscv-dv's 140-block constraint corpus, spanning every operator class the
language offers (Boolean/relational, range/`inside`, bit-slice, `solve…before` dependency
chains, `foreach` arrays, `unique` sets, weighted `dist`, arithmetic), each compiled to a
sampler and **checked register-for-register against the original solver running the same
constraint** — the equivalence collected in Appendix F's table. The check is *direct
equivalence against the production artifact*: Verilator 5.x runs the verbatim riscv-dv
constraint through its own `randomize()` as the reference, so the sampler is compared to
the solver's own output, not to a second model of it.

## Layout

| subdir | contents |
|---|---|
| `sv/` | the samplers, their reference constraints and independent checkers, the testbenches, the integrated generator, and the place-and-route wrappers |
| `uvm_oracle/` | the actual riscv-dv UVM classes compiled and run under UVM 1.2 in Verilator — a third, independent cross-check |
| `constraints/` | `INVENTORY.txt` (all 140 riscv-dv constraint blocks, each with its source file, shape tags, and verbatim text) and `COVERAGE_BLOCKS.txt` (the 140 blocks tagged by shape) |

Within `sv/`, each constraint family is a few small files: `*_orig.sv` — the verbatim
riscv-dv constraint as a `rand`/`constraint` class, solved by Verilator's `randomize()`
(the reference); `*_gen.sv` / `*_alloc.sv` — the synthesized constructive sampler (a
seed-driven module); `*_checker.sv` — an independent legality checker; and `tb_*.sv` — the
testbench (`module tb_top`) that runs both and prints a one-line `>>> … OK` result.

## Prerequisites

- **Verilator 5.x** on `PATH` (the reference constraints use `rand`/`constraint`/
  `randomize()`, including `unique`, `dist`, and `inside` over a queue).
- Optional, for area and frequency: **Yosys** (`synth_ice40`) and **nextpnr-ice40**.
- The UVM oracle additionally needs an external **riscv-dv** checkout and the **Accellera
  UVM 1.2** source (see below); the samplers themselves need neither.

## Running a constraint family

From `sv/`, every testbench builds and runs with the same command — substitute the
family's sources:

```sh
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME \
  --top-module tb_top <sources> && ./obj_dir/Vtb_top
```

Each run prints a `>>> … OK` line summarizing the both-directions comparison for that
constraint shape.

| constraint shape | riscv-dv block | `<sources>` |
|---|---|---|
| Boolean / relational | `aq_rl_c` | `rel_orig.sv relational_gen.sv tb_rel.sv` |
| Conditional / implication | `csr_csrrw` | `ci_orig.sv condimpl_gen.sv tb_ci.sv` |
| Range / `inside` + operand & op select | R-type reg-alloc | `rtype_gen.sv rtype_checker.sv tb_rtype.sv` |
| — same, as direct equivalence vs the verbatim original | R-type reg-alloc | `rtype_gen.sv rtype_checker.sv tb_compare.sv` |
| Bit-slice immediates | `imm_c` + `extend_imm` | `imm_orig.sv imm_gen.sv imm_checker.sv tb_imm.sv` |
| Dependency chain (`solve…before`) | load/store `addr_c` | `addr_orig.sv addr_gen.sv addr_checker.sv tb_addr.sv` |
| Encoding scatter (I/S/B/U/J + R assembly) | instruction encoding | `instr_assemble.sv instr_decode.sv tb_instr.sv` |
| All-different (`unique{}`) | `avail_regs_c` | `avail_orig.sv uniqreg_gen.sv uniqreg_checker.sv tb_uniqreg.sv` |
| Multiply / modulo (vector LMUL) | `narrowing`/`widening`/`nfields` | `vec_orig.sv vlmul_gen.sv vec_checker.sv tb_vec.sv` |
| Weighted `dist` | return-address `ra_c` | `ra_orig.sv ra_dist_gen.sv ra_checker.sv tb_radist.sv` |
| Cross-instruction stateful stream | GPR-init discipline | `stream_orig.sv stream_gen.sv stream_checker.sv tb_stream.sv` |

## The whole generator, one design

The families above are separate samplers; a real emulation run is one integrated design —
the whole generator clocked together, all families active, sharing one cross-instruction
register state. Two forms are here (both run from `sv/`):

```sh
# the mega generator: all 8 instruction classes (R/I/LD/ST/BR/LUI/JAL/VEC), one shared live-register state
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tb_top \
  imm_gen.sv addr_gen.sv instr_assemble.sv ra_dist_gen.sv vlmul_gen.sv riscv_megagen.sv tb_mega.sv \
  && ./obj_dir/Vtb_top

# end to end: the unique-register allocator wired into the generator
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tb_top \
  imm_gen.sv addr_gen.sv instr_assemble.sv ra_dist_gen.sv vlmul_gen.sv riscv_megagen.sv \
  uniqreg_seq.sv integrated_top.sv tb_integrated.sv && ./obj_dir/Vtb_top
```

Synthesized as one design (`yosys synth_ice40`), `riscv_megagen` is ~1065 `SB_LUT4` + 32
flip-flops — the 32 flip-flops are the shared cross-instruction live-register state, the
generator's memory in hardware. Placed and routed on an iCE40 hx8k (`nextpnr-ice40`) it
clocks at ~28 MHz, i.e. one legal instruction per clock on the lowest-end open-toolchain
FPGA.

## Synthesizing a sampler

Any sampler synthesizes on its own — this is the per-actor area behind the integrated
design:

```sh
yosys -p "read_verilog -sv vlmul_gen.sv; synth_ice40 -top vlmul_gen; stat"
```

For frequency, the `*_top.sv` wrappers (`mega_top`, `sel_ref_top`, `sel_pipe_top`,
`uniqreg_top`, `lehmer_top`, `shuffle_top`, `seq_top`) drive a sampler from an LFSR and
reduce its output so it fits the FPGA I/O:

```sh
yosys -p "read_verilog -sv mrsel_pipe.sv sel_pipe_top.sv; synth_ice40 -top sel_pipe_top -json p.json"
nextpnr-ice40 --hx8k --package ct256 --json p.json --pcf-allow-unconstrained --freq 80
```

## Refinements you can run

Also from `sv/`, using the same `verilator … && ./obj_dir/Vtb_top` command:

| what it shows | `<sources>` |
|---|---|
| **sim ≡ fabric** — the `actor_pkg` (Chapter 6) class rendering and the synthesized FSM rendering of the *same* authored actor, run in lockstep, emit bit-identical instructions | `../../../actor_pkg/actor_pkg.sv actor_stream.sv stream_gen.sv tb_actor_stream.sv` |
| **certified allocator** — a factoradic (Lehmer) unrank for the `unique{}` register list, smaller and faster than the hand-written form; its proof lives in the Lean development (`../05_lean_certified/`) | `avail_orig.sv lehmer_alloc.sv tb_lehmer.sv` |
| **solve once** — the `unique{}` set solved once per stream as a small setup FSM | `uniqreg_seq.sv tb_uniqseq.sv` |
| **reuse by shuffle** — a later draw permutes the held set instead of re-solving | `shuffle10.sv tb_shuffle.sv` |
| **pipelined selector** — the register selector split into two stages, same function, higher Fmax | `mrsel_pipe.sv tb_mrsel_cmp.sv` |

## The UVM oracle (`uvm_oracle/`)

A third cross-check, one level stronger than the verbatim-constraint reference: it compiles
and runs the **actual riscv-dv UVM source** — the real `riscv_instr_pkg` and
`riscv_instr_gen_config` — under UVM 1.2 in Verilator, and randomizes the production
return-address constraint (`ra_c`). riscv-dv is an external reference clone, not vendored
here.

```sh
RV=~/riscv-dv-ref      # git clone https://github.com/chipsalliance/riscv-dv.git
UVM=~/uvm-1.2          # Accellera UVM 1.2 source
cd "$RV" && git apply <this-dir>/uvm_oracle/riscv-dv-verilator.patch   # documented workaround
cd <this-dir>/uvm_oracle
verilator --binary -j 0 --timing -Wno-fatal -Wno-lint -Wno-ENUMVALUE \
  +incdir+$UVM/src +incdir+$RV/src +incdir+$RV/test +incdir+$RV/target/rv32i +incdir+$RV/user_extension \
  +define+UVM_NO_DPI +define+UVM_REGEX_NO_DPI \
  $UVM/src/uvm_pkg.sv $RV/src/riscv_signature_pkg.sv $RV/src/riscv_instr_pkg.sv ra_uvm_tb.sv \
  --top-module tb_top
./obj_dir/Vtb_top +UVM_NO_RELNOTES
```

`riscv-dv-verilator.patch` is the small, documented set of workarounds needed to get
riscv-dv's real source through Verilator (an include path, one lint relaxation, and two
`` `ifndef VERILATOR `` guards on constructs Verilator does not yet accept); other
simulators need none of them. The run confirms the `ra_c` support and, in its integer form,
reproduces the same weighted distribution the synthesized `ra_dist_gen` produces.

## What you're looking at

- **A constraint solver rendered as a datapath.** Each family emits legal stimulus by
  construction — a comparator cascade, a mask, a shift, a priority scan — reached by
  compiling the model-finding half of the constraint ahead of the run. Nothing on the
  fabric searches or rejects.
- **The operator is a poor predictor of cost; the operand is what matters.** The only
  multiply-bearing constraints (vector LMUL) collapse to shifts because `vlmul` is a power
  of two, and are the *cheapest* family; the `unique{}` register list is the priciest, and
  the certified Lehmer allocator beats it on both area and frequency.
- **The generator, including its state, is a clocked FSM.** The stream generator's
  cross-instruction live-register set is flip-flops; the `actor_pkg` class rendering and the
  synthesized RTL rendering are the *same* authored actor (Chapter 6: an actor is a
  synthesizable FSM), run side by side and compared bit for bit.
- **Three independent references.** The synthesized sampler (fabric), the verbatim
  constraint through Verilator's own `randomize()` (sim), and the actual riscv-dv classes
  under UVM 1.2 (the oracle) — so the stimulus is checked against riscv-dv, not a paraphrase
  of it.
</content>
</invoke>
