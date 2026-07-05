# 05_lean_certified/ — the certified sampler (Lean 4)

Companion code for **Appendix F, "Synthesizing Constrained-Random Stimulus"** of
*Emergent Hardware Verification*. This is the **certification layer** of the
constraint→hardware pipeline: the samplers and the code generator, proved in
**Lean 4** to be **sound, complete, and uniform**, with **certified code
generation**, plus a Lehmer/factoradic register allocator whose uniqueness is
guaranteed by proof. The proofs are **constructive** — they build the witness
rather than argue by contradiction, so no `Classical.choice` — and **complete
(0 sorries)**: every claim is discharged and checked by the Lean kernel.

## Why certify a sampler

The rest of Appendix F compiles a SystemVerilog constraint into a *search-free*
hardware sampler that stands in for `randomize()` on the fabric — no runtime
solver, no backtracking, just an index-to-witness map you can synthesize. Once a
sampler replaces the solver, three questions decide whether you can trust its
output as stimulus:

- **Sound** — does it *only* ever emit legal values? (no illegal stimulus)
- **Complete** — can it *reach* every legal value? (no silent coverage hole)
- **Uniform** — does it draw each legal value with equal weight? (no bias)

In a simulation-built flow those are things you hope for and spot-check. Here
they are **theorems checked by the Lean kernel**, true for the whole legal set
rather than the samples a run happened to draw. That is the point of this
directory: the sampler that will replace the solver is proved correct before it
is trusted.

## How it maps to the book

This is `05_lean_certified/`, the fifth directory of Appendix F. It certifies
the samplers the neighbouring directories build and run:

- `02_constructive_samplers/` builds the search-free samplers; **this directory
  proves them** sound, complete, and uniform, and emits the SystemVerilog from
  the same certified legal set.
- `04_sat_engine/` is the runtime finite-domain solver. When the legal set is
  small enough to fit on the fabric, a **certified ROM** proved here replaces
  that whole search engine.
- `06_riscvdv_capstone/` is where the Lehmer allocator and the certified
  constraints land in the full riscv-dv flow.

## Running

Requires **`lean` 4.x** (installed via `elan`; pure Lean 4 core, no Mathlib).
The SystemVerilog-validation steps also use **`verilator`** and **`yosys`** on
`PATH`. The compiled `.olean` files are build artifacts (regenerated, not
committed), so a fresh checkout just runs the script:

```sh
./run.sh
```

`run.sh` checks every proof file with the Lean kernel, has Lean **emit** the
certified SystemVerilog sampler, then **validates** that RTL in Verilator
(bit-identical to the Lean model, self-checked against an independent checker)
and reports its area with Yosys. If any proof does not hold, `lean` fails and
the script stops there.

To check a single file, run `lean` on it directly. Standalone files need
nothing else:

```sh
lean Bound.lean          # the bounded-search proof
lean Sampler.lean        # sound + complete sampler
```

A file that `import`s another needs that dependency's `.olean` built first and
`LEAN_PATH=.` set. For example, `Uniform.lean` imports `Sampler`:

```sh
lean -o Sampler.olean Sampler.lean
LEAN_PATH=. lean Uniform.lean
```

`run.sh` builds each `.olean` in dependency order before the file that imports
it, so running the whole script is the simplest way to check everything.

## What to read, and what you learn

### The three properties (`Sampler.lean`, `Uniform.lean`)

`Sampler.lean` defines the sampler as an **unrank** map from a uniform index to
the legal set, enumerated once at compile time from the constraint's checker:

```
unrank : Fin N → { a : Asn // P a = true }
```

The result type is a *subtype* that carries its own legality proof — you cannot
pull an assignment out without also holding a proof that it satisfies the
constraint `P`. So:

- **Soundness is by construction** (`unrank_sound`): every draw is legal because
  its legality proof travels with it. Zero rejection, enforced by the type.
- **Completeness is a theorem** (`unrank_complete`): every legal assignment in
  the domain is the image of some index, so nothing legal is left unreachable.

`Uniform.lean` adds the third property. `unrank_inj` proves the map is
**injective** — distinct indices give distinct solutions — so feeding it a
uniform random index yields a uniform random legal assignment, none over- or
under-represented. Injectivity follows from the enumerated legal list having no
duplicates, which is itself proved (`legal_nodup`) rather than assumed.
`unrank_bijective` packages all three: `unrank` is a **bijection** between
`Fin N` and the legal set — every legal value hit exactly once.

### Certified code generation (`Codegen.lean`)

Lean emits the SystemVerilog sampler from the *same* legal set its theorems
certify, so the generated RTL is faithful to the proved model by construction.
Alongside it Lean emits an independent SystemVerilog checker and a self-checking
testbench; `run.sh` then compiles the trio in Verilator and confirms the RTL
sampler is synthesizable and bit-identical to the Lean model, closing the loop
from proof to gates.

### One interface, two sampling strategies (`Tiers.lean`)

Both sampler tiers are the same certified interface — a seed type plus a `draw`
whose result carries its legality proof:

- **Enumeration** (`enumCS`) indexes a finite box's legal set — the `unrank` map
  above, right for Boolean and relational structure.
- **An algebraic inverse** (`mulCS`) handles a constraint like `A*B < LIMIT`
  whose box is 2⁶⁴ values — far too large to enumerate. Instead of searching, a
  certified divider inverts the constraint and samples in O(1), proved sound
  (`mul_sound`) and complete (`mul_complete`) by algebra, never bit-blasting the
  multiply. The proof *is* the program.

### The Lehmer register allocator (`LehmerUnrank.lean`)

riscv-dv's `avail_regs_c` asks for K *distinct* registers drawn from a pool. The
hand-written allocator does a chained priority scan against a growing exclusion
mask. This file certifies a **factoradic (Lehmer)** alternative: decode a Lehmer
code by *select-and-remove* from the pool — pick the d-th remaining register, K
times — with no exclusion mask and no wide priority scan. `decode_nodup` (and
its instance `lehmerAlloc_distinct`) proves the decode always produces **K
distinct registers, all drawn from the pool**: the `unique{}` clause discharged
by a proof, for every input, instead of by a runtime solver. The allocator that
results is smaller and faster than the hand-written one it replaces.

### Bounded search is synthesizable (`Bound.lean`)

For the finite-domain solver, `searchNodes_le` proves the backtracking search
visits a **bounded** number of nodes, so it terminates and unrolls to a circuit
— a bounded loop is synthesizable. `leaves_ffact_le` shows the all-different
structure shrinks that bound to a falling factorial, well below the full product
of the domains.

### Real riscv-dv constraints certified (`SpTp.lean`, `UniqReg.lean`, `VLmul.lean`)

The same pipeline is run on genuine riscv-dv constraints, each enumerated and
certified in Lean and validated in Verilator: `sp_tp_c` (`SpTp.lean`, 840 legal
assignments — independently reproducing the frontend's count), the
unique-register-allocation `avail_regs_c` (`UniqReg.lean`, 60 = the falling
factorial signature of `unique{}`), and the vector `LMUL` alignment constraints
(`VLmul.lean`, 36), whose power-of-two structure turns every "multiply" into a
shift or a mask.
