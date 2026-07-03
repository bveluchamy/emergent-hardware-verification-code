# 05_lean_certified / L4: certified codegen — the SV-constraint → FPGA loop, closed

`lean/Codegen.lean` emits SystemVerilog **from the same Lean-certified `legal` set** the L2
theorems are about, and verilator validates it. Book `main.tex` untouched.

## What closes here

The ultimate goal of the whole `synthesize_constraints/` line — *a SystemVerilog constraint
running on the fabric* — closed end to end, with certification at every hop:

```
 constraint  ──►  Lean predicate P        (the checker, decidable)
             ──►  Lean SOLVES it          (model-finding half; enumerate + filter)
             ──►  Lean CERTIFIES the set   sound+complete  (L2: unrank_sound / unrank_complete)
             ──►  Lean EMITS the RTL       (Codegen.lean, from that same certified set)
             ──►  verilator VALIDATES       synthesizable + bit-identical + passes an SV checker
```

Because the emitted ROM is built from `legal P doms` — the *very object* the soundness and
completeness theorems quantify over — the RTL is **faithful to the certified model by
construction** (DESIGN.md §2, mechanism 5). This is the substrate-identity result of the
earlier arcs (sim ≡ fabric), now with the legal set *certified in Lean* rather than asserted.

## Measured

`LEAN_PATH=. lean Codegen.lean` emits `tier1_sampler.sv` (combinational ROM unrank),
`tier1_checker.sv` (the constraint independently coded), `tb_tier1.sv` (self-checking). The
ROM arms are exactly the certified set:

```
0: v={1,2,3}   1: v={1,3,2}   2: v={2,3,1}     // = legal Pinst domsInst, verbatim
```

verilator (`-Wall`, 0 warnings, synthesizable):

```
>>> L4 OK: Tier-1 SV sampler == Lean-certified legal set, all pass the SV checker (N=3)
```

Every index's output (a) passes the independently-coded SV checker (all-different ∧ sum==6 ∧
v0<v1) and (b) bit-matches the Lean-certified entry. Zero mismatches.

## Tier-2 (the harder constraint) on the fabric

Tier-2's RTL already exists and is verilator-validated: `02_constructive_samplers/tier2_mul/
mul_constraint_sampler.sv` is the divider datapath `bound=(LIMIT-1)/A; B=Braw mod (bound+1)` —
*exactly* what L3's certified `mulDraw` computes (`#eval (mulCS 10⁶).draw (777,123456789) =
[777,701]`). So the BDD-killer's fabric path is the same one 02_constructive_samplers measured (732 LUT, 0
rejection), now with its generator certified in Lean (`mul_sound`/`mul_complete`). No
enumeration, on the fabric.

## Reproduce

```sh
export PATH=$HOME/.elan/bin:$PATH
cd 05_lean_certified/lean
lean -o Sampler.olean Sampler.lean
LEAN_PATH=. lean Codegen.lean                       # emits the .sv from the certified set
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tb_top \
  tier1_sampler.sv tier1_checker.sv tb_tier1.sv && ./obj_dir/Vtb_top
```
