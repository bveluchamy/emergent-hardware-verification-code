# Constructive samplers — Appendix F, Tier 0/1 and Tier 2

Companion code for **Appendix F, "Synthesizing Constrained-Random Stimulus"** (and
Chapter 4 §"Implementing the Constraint Solver"). These are the appendix's *constructive*
samplers: a constraint compiled directly to a datapath so that, given a seed, the hardware
returns a legal value in fixed latency — no search, no rejection. `randomize()` never needs
to refute; it only has to *find a model*, and a model can be built by construction.

This directory shows each tier by hand. The compiler in `01_constraint_compiler/` automates
the same lowering from a SystemVerilog `constraint` spec, and `05_lean_certified/` carries the
correctness proofs; `lean/MulSampler.lean` here is the proof-side mirror of `tier2_mul/`.

| dir | what it shows |
|---|---|
| `tier1_bdd/` | **Tier-1 (Boolean/relational).** A constraint is compiled to a count-annotated BDD; one uniform seed *unranks* into the R-th satisfying assignment by a root-to-leaf walk. Zero rejection, fixed 12-cycle latency, provably uniform. `build_bdd.py` builds the BDD and generates `bdd_constraint_sampler.sv`. |
| `tier2_mul/` | **Tier-2 (arithmetic).** For `A*B < LIMIT`, the sampler *inverts* the constraint instead of bit-blasting the multiplier: sample `A`, divide to get `B`'s exact bound `⌊(LIMIT-1)/A⌋`, sample `B` under it. The multiplier only ever appears in the checker. |
| `tier2b_coupled/` | The coupled constraint `A*B < LIMIT && B < A`. Its bound `min(A-1, ⌊(LIMIT-1)/A⌋)` is certified sound and complete by **Z3 at compile time** (`soundness.smt2`, `completeness.smt2`); the datapath then samples with no runtime solver. |
| `tier1_actor/` | The compiled Tier-1 sampler dropped into the actor graph: `BddStimActor extends ConstraintActor` calls the same `bdd_unrank` that synthesizes to RTL, and a checker actor subscribes by type and asserts legality — the sim-class stream is bit-identical to the C-model and RTL streams. |
| `lean/` | `MulSampler.lean` — soundness and completeness of the Tier-2 divide-bound, proved *algebraically* (one division lemma + `omega`, never bit-blasting the multiplier). |

## Running

Requires `verilator` (5.x), `yosys`, `z3`, `python3`, and `lean` (4.x) on `PATH`.
`./run_all.sh` builds and runs every example above. Individually:

```sh
# Tier-1 BDD unrank sampler
cd tier1_bdd
python3 build_bdd.py 100000                 # build BDD, self-check, emit ref stream + RTL
verilator --binary -j 0 --timing --top-module tb_top bdd_constraint_sampler.sv tb_top.sv
./obj_dir/Vtb_top                           # 0 illegal, full coverage
yosys -p "read_verilog -sv bdd_constraint_sampler.sv; synth_ice40; stat"   # cell count

# Tier-2 constructive A*B < LIMIT
cd ../tier2_mul
python3 ref.py 100000
verilator --binary -j 0 --timing --top-module tb_top mul_constraint_sampler.sv tb_top.sv
./obj_dir/Vtb_top

# Tier-2b coupled, Z3-certified bound
cd ../tier2b_coupled
z3 soundness.smt2 && z3 completeness.smt2   # both: unsat  (bound is correct)
verilator --binary -j 0 --timing --top-module tb_top coupled_sampler.sv tb_top.sv
./obj_dir/Vtb_top

# Sampler inside the actor graph (via ConstraintActor)
cd ../tier1_actor
make                                        # build + run; make clean removes obj_dir

# Lean proof of the Tier-2 bound
cd ../lean
lean MulSampler.lean                        # 0 errors, 0 sorries
```

## What to look at

- **The unrank trick** (`tier1_bdd/build_bdd.py`): annotate each BDD node with the number of
  satisfying assignments below it, and a uniform integer decodes bijectively into a legal
  assignment. This is how a Boolean constraint becomes a search-free ROM-and-mux datapath.
- **Invert, don't bit-blast** (`tier2_mul`, `tier2b_coupled`): arithmetic constraints are
  solved by a divide, not by flattening a multiply into gates — the move Appendix F's Tier 2
  is built on, with the multiplier confined to checking.
- **Certification at two levels**: Z3 discharges the coupled bound once at compile time; Lean
  proves the same arithmetic algebraically. The generated datapath carries no solver at all.
- **The actor seam** (`tier1_actor`): the identical sampler that synthesizes to RTL also runs
  as a `ConstraintActor` in simulation, producing the same stream — the substrate-independence
  the framework is built for.
