# closeloop — one real riscv-dv constraint, from source to fabric

This carries a genuine riscv-dv constraint through the entire pipeline and onto the
actor graph as both software and synthesizable hardware, producing the identical legal
stimulus on both. It is Appendix F's substrate point on a real constraint: authored
once (in riscv-dv), compiled once, run identically as a software `ConstraintActor` in
the verification graph and as synthesized hardware on the fabric.

```
  riscv_instr_gen_config.sv :: sp_tp_c        raw riscv-dv source
        │  frontend.py     resolve enums + cfg  (SP=2, GP=3, ZERO=0, …)
        ▼
  resolved_sp_tp_c.txt                          clean constraint spec
        │  csc.py          BDD compile
        ▼
  resolved_sp_tp_c_pkg.sv   +   resolved_sp_tp_c_sampler.sv
    (unrank package)              (synthesizable module)
        │  class form (sim)               │  module form (fabric)
        ▼                                 ▼
  ConstraintActor.randomize_and_publish()   csc_sampler  (RTL, ~473 LUT4 iCE40)
        │  `WIRE                           │
        ▼                                  ▼
  LegalCheckActor  ◄──── identical stream ────►  RTL dump
```

The constraint is `sp_tp_c` from `riscv_instr_gen_config.sv`: legal stack- and
thread-pointer allocations — `sp != tp`, neither `sp` nor `tp` in `{ZERO, RA, GP}`,
and `fix_sp` implies `sp == SP`.

## Running

The resolved and compiled files (`../resolved_sp_tp_c*.sv`) are already in the
directory. To regenerate them from raw source, run the frontend from the parent
directory:

```sh
cd ..
python3 frontend.py \
    corpus/riscv-dv/src/riscv_instr_pkg.sv \
    corpus/riscv-dv/src/riscv_instr_gen_config.sv \
    sp_tp_c
```

Then, from this `closeloop/` directory, build and run each form (one at a time — both
testbenches are `tb_top`):

```sh
# software form: the compiled unrank inside a ConstraintActor, wired to a checker actor
verilator --binary -j 0 --timing -Wno-fatal --top-module tb_top \
    ../../../actor_pkg/actor_pkg.sv ../../../actor_pkg/actor_verification_pkg.sv \
    ../resolved_sp_tp_c_pkg.sv stim_demo.sv
./obj_dir/Vtb_top

# hardware form: the same compiled sampler as an RTL module, dumped directly
verilator --binary -j 0 --timing -Wno-fatal --top-module tb_top \
    ../resolved_sp_tp_c_sampler.sv module_dump_tb.sv
./obj_dir/Vtb_top
```

## What you'll see

- **Software form (`stim_demo.sv`):** 5000 transactions, **0 illegal**, 837/840
  solutions covered. `LegalCheckActor` re-checks `sp_tp_c` on every draw and every
  sample is a valid allocation.
- **Hardware form (`module_dump_tb.sv`):** the same compiled sampler as an RTL module;
  it synthesizes with `yosys synth_ice40` to ~473 LUT4 on iCE40.
- **Identical stream:** both forms print the same first six draws
  (`fix_sp / sp / tp`), because both evaluate the same compiled unrank tables driven
  by the same LFSR seed. The software `ConstraintActor` and the hardware module are
  two renderings of one artifact, not two implementations that happen to agree.
