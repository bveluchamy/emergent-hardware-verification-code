# 01_constraint_compiler: a constraint -> synthesizable-sampler compiler (the step past POC)

The 02_constructive_samplers and 03_reactive_constraints examples were hand-coded proofs of concept. This is the **flow**: one tool
(`csc.py`) that takes a real (restricted) SystemVerilog `constraint` spec and
**automatically** emits a synthesizable UNRANK sampler + a synthesizable CHECKER +
a self-checking testbench, then validates with verilator + yosys. No per-example
hand-coding.

**The book (`main.tex`) is untouched.** Run the whole flow: `./run_flow.sh`.
Compile one spec: `python3 csc.py spec_riscv.txt`.

## What it does (per spec, automatically)

1. **parse** real SV: `rand bit [W-1:0] name;` + `constraint c { ... }` with
   `-> || && | ^ & == != < <= > >= << >> + - * / % ! ~`, bit/part-select,
   literals (`8'hFF`), `inside {[lo:hi]}` / `inside {a,b,c}`, `if(c) e;`.
2. **classify**: a `var*var` product => Tier-2 (route to the constructive
   arithmetic template, never bit-blasted); else Tier-1 (boolean/relational).
3. **compile** Tier-1: enumeration BDD + per-node model counts -> the unrank
   sampler (one uniform R in [0,#sols) -> the R-th legal assignment).
4. **emit**: `<spec>_sampler.sv` (synthesizable) + `<spec>_tb.sv` (the checker is
   the constraint compiled to combinational SV -- universal, also synthesizable).
5. **validate** (`run_flow.sh`): verilator runs 200k samples through the emitted
   checker (expect 0 illegal + full coverage); yosys reports cells.

## Results -- same tool, four real constraints

| spec | what | result | iCE40 |
|---|---|---|---|
| `spec_proto` | the hand-coded prototype constraint, now parsed | **416 sols, 0 illegal, full coverage** (matches the 02_constructive_samplers result exactly) | 160 LUT4 |
| `spec_axi_field` | AXI4 burst-field legality (burst/size/len/region) | **288 sols, 0 illegal, full coverage** | 158 LUT4 |
| `spec_riscv` | RISC-V R-type fields, coupled `rs1 != rd` (riscv-dv flavour) | **3844 sols, 0 illegal, full coverage** | 410 LUT4 |
| `spec_mul` | `a*b < 1000000` | **classified Tier-2** (routed, not bit-blasted) | — |

The prototype constraint compiling to 160 LUT4 vs the hand-written 151 shows the
flow produces RTL comparable to hand work.

## Front-end status — what now compiles automatically (all validated)

`frontend.py` is the symbol-table / resolution layer (the job a Surelog/slang
front-end does; built directly since neither installed here without a heavy build).
Each row below was run end-to-end and the solution count is **provably exact**:

| feature | example | result |
|---|---|---|
| **enum + type resolution** (raw `.sv`) | riscv-dv `sp_tp_c` (`SP=2,GP=3,…` auto) | **840**, 0 illegal, full cov |
| **`cfg.*` resolution** (config array bound + enum) | riscv-dv `instr_c` `!(gpr inside {cfg.reserved_regs,ZERO})` | **28**, 0 illegal, full cov |
| **`foreach`-unroll + arrays** | register array, each `!=0` | exact, full cov |
| **`unique` → all-different** | distinct register set | **26,970 = 31·30·29** |
| **all combined** | `avail_regs` alloc (foreach+array+unique+cfg) | **19,656 = 28·27·26** |
| **`dist` (weighted sampler)** | `dist {1:=30,0:=70}`; register dist w/ ranges & `:/` | observed ≈ expected (synthesizable CDF select) |
| classify `var*var` → Tier-2 | `a*b<1e6` | routed, not bit-blasted |

Corpus study (`corpus/`): **76% of riscv-dv and 87% of OpenTitan** constraints are
Tier-0/1/2 reachable. See `corpus/CORPUS_FINDINGS.md`.

## Honest scope (what makes this a POC-of-a-flow, not the product)

- **Front-end** is a restricted-SV recursive-descent parser, not full IEEE-1800.
  The production bridge is Surelog/slang or the Antmicro SV->SMT-LIB2 path
  (`../sv-tools`, `../verilator-verification`) feeding the same IR.
- **Tier-1** uses an *enumeration* BDD (<= 18 vars here). Production swaps in CUDD
  apply-based construction for wide fields.
- **Tier-2** is *detected and routed*, not yet auto-codegen'd; the constructive
  templates exist (`tier2_mul` in 02_constructive_samplers, `pipelined_div` in 03_reactive_constraints,
  `tier2b_coupled` with z3 certification) -- wiring the projection into `csc.py`
  is the next step.
- **Reactivity (03_reactive_constraints)**: the emitted samplers are open-loop; live-state
  inputs (id_free, credits) and the network-of-actors decomposition are the next
  integration (the sampler drops under `ConstraintActor.randomize_and_publish()`,
  proven by `tier1_actor` in 02_constructive_samplers).

## Next (to make it the product)

1. Tier-2 auto-codegen: z3 projection -> constructive arithmetic datapath in `csc.py`.
2. CUDD apply + a real SV front-end (Surelog) -> arbitrary `constraint {}` blocks.
3. Per-compile certification: emit a z3/Lean proof object that the sampler is
   sound+complete for each generated constraint (the mechanism is shown in 02_constructive_samplers).
4. Reactive lowering: live-state ports + the actor-network partitioner (03_reactive_constraints).

(The corpus study originally listed here is **done** — 76% riscv-dv / 87% OpenTitan across
2,097 blocks; see `corpus/CORPUS_FINDINGS.md` and the result above.)
