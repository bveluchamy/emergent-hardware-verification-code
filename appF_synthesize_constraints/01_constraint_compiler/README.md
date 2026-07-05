# Appendix F — Constraint Compiler (the frontend)

Companion code for **Appendix F, "Synthesizing Constrained-Random Stimulus"** (and
Chapter 4 §"Implementing the Constraint Solver"). This is the **frontend** of the
constraint-to-hardware pipeline: it reads a real SystemVerilog `constraint` block and
compiles it into a search-free *sampler* — a circuit that, given a seed, returns a
legal assignment directly, with no runtime search and no rejection.

Two programs do the work:

- **`csc.py`** — the compiler. Parses a restricted-SystemVerilog constraint spec,
  classifies it, and emits a synthesizable sampler, a synthesizable checker, and a
  self-checking testbench.
- **`frontend.py`** — the symbol-table / resolution layer in front of it. Reads a
  package's `enum` typedefs and a class's `rand` field widths from raw source, pulls
  out a named `constraint` block, resolves every enum and `cfg.*` name to its value,
  and writes a clean spec for `csc.py` to compile.

## How it maps to the book

Appendix F's claim is that the *model-finding* half of `randomize()` — find **one**
legal assignment, never prove that none exists — is a datapath, not a solver. A
relational constraint has a legal set that can be *structured* so that a seed indexes
a member directly: a binary-decision-diagram (BDD) walk turns "the R-th legal tuple"
into a short combinational path, and no candidate is ever generated and rejected.
`csc.py` is that compilation. The emitted sampler produces its seed on-chip from a
small LFSR, which is SystemVerilog's object random stability (Chapter 4 §"The
Constraint Solver and Object-Based Randomization") rendered as gates: reproducible
from that seed, and isolated from every other sampler.

## What `csc.py` does, per spec

1. **Parse** a restricted SV subset: `rand bit [W-1:0] name;` fields and a
   `constraint { ... }` body over `-> || && | ^ & == != < <= > >= << >> + - * / % ! ~`,
   bit- and part-selects, sized literals (`8'hFF`), `inside {[lo:hi]}` /
   `inside {a,b,c}`, `if (c) e;`, `foreach`, `unique`, and `dist`.
2. **Classify.** A `variable * variable` product routes to **Tier-2** — the
   constructive arithmetic templates in `../02_constructive_samplers` and
   `../03_reactive_constraints`, never bit-blasted. Everything else is **Tier-1**
   (boolean / relational).
3. **Compile Tier-1.** Build an enumeration BDD with a model count at each node, which
   yields an *unrank* sampler: one seed `R` in `[0, #solutions)` walks the diagram to
   the R-th legal assignment in a single combinational pass.
4. **Emit** three files per spec:
   - `<spec>_sampler.sv` — the sampler as a synthesizable `csc_sampler` module;
   - `<spec>_tb.sv` — a self-checking testbench whose checker *is* the constraint,
     compiled to combinational SV (so it is a universal oracle, and itself
     synthesizable);
   - `<spec>_pkg.sv` — the same unrank as a package function, so a class-based
     `ConstraintActor` in simulation calls the identical logic that runs on the fabric.

A lone `dist` on one field compiles instead to a weighted cumulative-threshold
sampler (`<spec>_sampler.sv` + `<spec>_tb.sv`).

## Running it

Requires `python3`, `verilator` (5.x), and `yosys` on `PATH`.

```sh
./run_flow.sh                 # compile, build, check, and synthesize four specs end to end
python3 csc.py spec_riscv.txt # compile one spec -> its _sampler.sv, _tb.sv, _pkg.sv
```

`run_flow.sh` walks four representative specs. For each Tier-1 spec it runs 200,000
seeds through the emitted checker (expecting zero illegal samples and every solution
covered) and reports the iCE40 LUT4 count from `yosys synth_ice40`:

| spec | constraint | you'll see |
|---|---|---|
| `spec_proto` | a small worked example: `addr` / `kind` / `prio` with implications | 416 solutions, 0 illegal, full coverage; ~160 LUT4 |
| `spec_axi_field` | AXI4 burst-field legality (burst / size / len / region) | 288 solutions, 0 illegal, full coverage; ~158 LUT4 |
| `spec_riscv` | RISC-V R-type fields with coupled `rs1 != rd` | 3844 solutions, 0 illegal, full coverage; ~410 LUT4 |
| `spec_mul` | `a * b < 1000000` | classified Tier-2 and routed (not bit-blasted) |

The other `spec_*.txt` in this directory cover `dist`, `unique` / all-different,
`foreach` over arrays, and further riscv-dv blocks; compile any of them the same way.

### From raw riscv-dv source

`frontend.py` runs the compile against unmodified industrial source. It reads the
vendored riscv-dv corpus (`corpus/riscv-dv/`, pinned — see `VENDORED_COMMIT.txt`):

```sh
python3 frontend.py \
    corpus/riscv-dv/src/riscv_instr_pkg.sv \
    corpus/riscv-dv/src/riscv_instr_gen_config.sv \
    sp_tp_c
```

This builds the enum symbol table (`SP=2`, `GP=3`, `ZERO=0`, …), resolves the `cfg.*`
reserved-register set, writes `resolved_sp_tp_c.txt`, and compiles it — the same
Tier-1 path, now driven from real source.

To see how much of that corpus this approach reaches:

```sh
python3 corpus/survey.py corpus/riscv-dv   # categorize every constraint block
```

It reports that **76% of the 140 riscv-dv constraint blocks** (across 89 files) are
Tier-reachable — solver-free by structure.

## What to look at

- Open a generated `<spec>_sampler.sv`: the whole sampler is a handful of `case`
  tables (the BDD) plus an LFSR — combinational logic, no solver underneath it.
- `<spec>_tb.sv` shows the checker-is-the-constraint idea: the same relation is
  emitted once as the sampler and once as the independent oracle.
- **`closeloop/`** carries one real riscv-dv constraint all the way onto the actor
  graph: the `sp_tp_c` constraint above, compiled once, runs as a software
  `ConstraintActor` and as a synthesized RTL module and produces the identical legal
  stream on both substrates. See `closeloop/README.md`.
