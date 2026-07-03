# closeloop: a real riscv-dv constraint, end to end, onto the fabric

The culmination. A genuine riscv-dv constraint travels the **entire** pipeline and
lands in the actor graph as both software and synthesizable hardware, producing
**identical** legal stimulus on both substrates.

```
  riscv_instr_gen_config.sv :: sp_tp_c           (RAW industrial source)
        |  frontend.py        enum/cfg resolution  (SP=2, GP=3, ZERO=0 ...)
        v
  resolved_sp_tp_c.txt                            (clean constraint)
        |  csc.py             BDD compile
        v
  resolved_sp_tp_c_pkg.sv  +  resolved_sp_tp_c_sampler.sv
   (unrank package)            (synthesizable RTL module)
        |                              |
        v  class form (sim)            v  module form (fabric)
  ConstraintActor.randomize_and_publish()   csc_sampler  (473 LUT4, iCE40)
        |  `WIRE                        |
        v                              v
  LegalCheckActor  <----- identical stream ----->  RTL dump
```

Run: from `01_constraint_compiler/`, `python3 frontend.py corpus/riscv-dv/src/riscv_instr_pkg.sv
corpus/riscv-dv/src/riscv_instr_gen_config.sv sp_tp_c`, then build `closeloop/`:
`verilator --binary -j 0 --timing -Wno-fatal --top-module tb_top
../../../actor_pkg/actor_pkg.sv ../../../actor_pkg/actor_verification_pkg.sv
../resolved_sp_tp_c_pkg.sv stim_demo.sv`.

## Result

- **Actor graph (class, sim):** 5000 txns, **0 illegal**, 837/840 solutions covered;
  samples are valid stack/thread-pointer allocations (`sp != tp`, both ∉ {ZERO,RA,GP},
  `fix_sp -> sp==SP`).
- **RTL module (fabric):** the same compiled sampler, **473 LUT4** on iCE40.
- **Substrate identity:** the class-form stream and the module-form stream are
  **bit-identical** — `0/13/25, 0/16/10, 0/17/20, 0/2/25, 0/5/11, 0/10/22` on both,
  because both call the same compiled BDD tables driven by the same LFSR.

That is the book's substrate-swap thesis, demonstrated for a **real constrained-random
constraint from an industrial generator** — not a hand-written toy: the constraint is
authored once (in riscv-dv), compiled once, and runs identically as a software
ConstraintActor in the verification graph and as synthesized hardware on the fabric.
