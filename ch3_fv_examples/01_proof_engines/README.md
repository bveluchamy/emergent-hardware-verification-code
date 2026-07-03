# Chapter 3 proof engines — the common code

Software implementations of the **refutation** proof engines Chapter 3 walks
through, from CDCL up to IC3/PDR and SMT. This directory holds only the reusable
machinery; the DUTs it proves live in the sibling examples `../02_elevator_proof`
(`elevator.sv`) and `../03_fifo_proof` (`fifo.sv`), each with a `Makefile`.

These are the *left half* of a proof engine — the expensive, exhaustive
**model-checking / refutation** side. The `appF_synthesize_constraints/`
companion is the *right half*: constructive **model-finding** (`randomize()` as a
sampler), lowered to synthesizable SystemVerilog. Chapter 4's "Implementing the
Constraint Solver" subsection is where the two halves meet.

Pure Python, no dependencies. A from-scratch CDCL solver is the decision oracle
under every other engine, and a minimal SystemVerilog frontend reads the real RTL
so the model the engines prove is *derived from the design*, not hand-written:

```
elevator.sv / fifo.sv  ──frontend──▶  TransitionSystem  ──Tseitin──▶  CNF  ──▶  CDCL → BMC → k-induction → IC3 → interpolation
```

## Run it

```sh
python3 demo.py                                  # every engine on both DUTs, in chapter order
python3 prove.py ../03_fifo_proof/fifo.sv        # the escalation on one DUT (what the Makefiles call)
python3 prove.py ../02_elevator_proof/elevator.sv --engine ic3
python3 ic3.py                                   # any engine module self-tests on both DUTs
python3 smt.py
```

## Watch it think: `--trace` and `--deep`

A plain run prints only the per-engine verdicts. When you want to understand
**how** a solver reaches its verdict -- and these solvers are written to be
*understood* -- opt in to the teaching narration:

- `--trace` narrates the transition system the frontend built, the Tseitin
  encoding of the property gate-by-gate, and every step each engine takes --
  IC3 obligations, ternary lifts, generalizations, BMC frames, theory lemmas --
  with a concrete reason when a solver cannot finish. Literals print by name
  (`moving ∧ ¬door_open`, `state[0]@2`), never as bare CNF integers.
- `--deep` additionally narrates the CDCL search **under** each engine query --
  every decision, propagation, conflict, and learned clause (implies `--trace`).
  This is the full picture of how the solver solves, every step; expect a lot
  of output on the larger designs.

```sh
python3 prove.py ../02_elevator_proof/elevator.sv               # quiet verdicts (the default)
python3 prove.py ../02_elevator_proof/elevator.sv --trace       # every engine step, narrated
python3 prove.py ../02_elevator_proof/elevator.sv --deep        # + the CDCL search itself
python3 prove.py ../02_elevator_proof/elevator.sv --engine ic3 --trace   # just IC3, narrated
python3 prove.py ../../ch2_rtl_fv_examples/01_soda_machine/soda_machine_mealy.sv \
        ../../ch2_rtl_fv_examples/01_soda_machine/soda_machine_checker.sv \
        ../../ch2_rtl_fv_examples/01_soda_machine/fv/soda_machine_env.sv --trace  # book design+checker+env
```

Every `ch2_rtl_fv_examples` Makefile forwards the same knobs:
`make prove FLAGS=--trace`, or `FLAGS=--deep` for everything. Narration is a
single boolean test per trace point, and the module self-tests, `demo.py`, and
`--check` verdict/exit code are all unaffected; the committed `fv/*.proof.txt`
traces are `--trace` runs.

## Beyond safety: liveness and sequential equivalence

The chapter's thesis is that IC3 / BMC / k-induction settle more than pure safety.

- **Liveness** (`liveness.py`): a property `a |-> s_eventually b` is reduced to the
  reachability of a **lasso** -- a loop that starves the obligation -- so the safety
  engines prove it unchanged. The frontend reads `s_eventually` and `assume property`;
  `prove.py` runs the reduction and reports LIVENESS HOLDS / FAILS. The arbiter's
  no-starvation and the CDC checker's two guarantees (true `s_eventually`, the
  checkers' formal branches) exercise it; a BOUNDED window like the mem_ctrl
  checker's `##[1:N]` contracts is not approximated as liveness but lowered
  exactly (see the window monitors above) -- only a genuinely unbounded
  consequent becomes a liveness obligation.
- **Sequential equivalence** (`sec.py`): the pipelined ALU's forwarding is proved
  equivalent to an in-order reference **word-level** by `smt.py` (DPLL(T)) -- operand
  values stay symbolic bit-vectors, so equivalence holds at any width. `python3 prove.py sec`.
- **Memory contents** (`memproof.py`): mem_ctrl's write-then-read and the FIFO's
  data-independence are proved with the **theory of arrays** now in `smt.py` -- a write
  is `store(mem,a,d)`, a read is `select(mem,a)`, and the read-over-write axioms decide
  the contract with the address symbolic at full width (no entry enumerated, nothing
  bit-blasted). This is why a memory no longer forces the address space small.
  `python3 prove.py mem`.
- **Abstraction** (`cegar.py`): the Chapter 2 CEGAR loop, with localization as the
  abstraction -- state bits outside a kept set become free inputs, IC3 checks the small
  model, a counterexample replays on the concrete design *by simulation* (deterministic,
  so no SAT), and the earliest disagreeing freed bit names the refinement. The full-geometry
  book MSI cache (4 ways × 16 sets, 288 state bits, where a direct IC3 run drowns) proves
  single residence unbounded keeping **16 of 288 bits** -- the probed set's state/tag pairs,
  i.e. the checker's own predicates. `prove.py --cegar`.

Each engine module's `__main__` reads the two DUTs via the frontend and asserts
the chapter's verdict, so running a file *is* its test.

## The modules

| file | role | what it reproduces |
|---|---|---|
| `cdcl.py` | CDCL SAT solver | watched literals, 1-UIP learning, VSIDS, restarts, assumptions + unsat core — the oracle under everything else |
| `circuit.py` | gate / bit-vector DSL + Tseitin | `Sig`/`BV`, the netlist→CNF encoding, `TransitionSystem`, ripple-carry `bv_add`, array `bv_mul`, **+ ternary simulation** (`ternary_eval` over {0,1,X}, `support`) |
| `frontend.py` | SystemVerilog reader | lexer + parser + expression lowering: `*.sv` → `TransitionSystem` (enum/case/if, async reset, multi-`always_ff`, `s_eventually`, `assume`, structs/packages/`bind`, arrays + bounded queues, functions, `generate`, `$past`/`$stable`, exact `##[lo:hi]` window monitors, procedural asserts, blocking-vs-nonblocking honored) — every Chapter 2 book design **and its book checker** read verbatim |
| `smt_frontend.py` | SMT-LIB reader | S-expression parser for QF_BV: `*.smt2` equivalence miter → `smt.py` term layer |
| `bmc.py` | Bounded Model Checking | unroll from reset; both DUTs safe to depth 12 |
| `kinduction.py` | temporal k-induction (+ `one_step_inductive`) | elevator proved at k=1; FIFO loses at every k on the `count=4 & full=0` garbage |
| `ic3.py` | IC3 / PDR | proves without unrolling; **discovers** the FIFO's `full ↔ count=4` relation; UNSAFE on a buggy FIFO. Eén–Mishchenko–Brayton's two PDR moves (**ternary lifting** of every SAT witness; queries load only the **cone they read**) are what let it prove the book MSI cache unbounded |
| `cegar.py` | CEGAR by localization | Chapter 2's abstract/check/replay/refine loop; freed flops become inputs, spurious traces re-concretize exactly the bit they invented; the 288-bit full-geometry MSI closes keeping 16 bits |
| `interp.py` | Craig interpolation (McMillan) | proof-producing DPLL + interpolant extraction + image-widening MC; the fence carved from a refutation |
| `smt.py` | SMT by DPLL(T) | the rebalanced adder-tree miter, word-level vs bit-blast, the multiplier wall, theory-lemma ping-pong, **+ the theory of arrays** (select/store, read-over-write + congruence, address symbolic) |
| `liveness.py` | liveness-to-safety | `a |-> s_eventually b` → lasso reachability; the arbiter no-starvation and CDC handshake proved with the safety engines |
| `sec.py` | sequential equivalence | the pipelined ALU's forwarding vs an in-order reference, decided word-level by DPLL(T) |
| `memproof.py` | memory contents, word-level | mem_ctrl's write-then-read and the FIFO's data-independence via array theory — a `store` per write, a `select` per read, address never enumerated |
| `word.py` | word-level BMC + k-induction | a WordTS of words + array-valued memories; reads are desugared by read-over-write so only access *addresses* are compared, never the 2^addr entries |
| `word_frontend.py` | RTL → WordTS | the word-level twin of the bit-level elaborator: reads the book RTL (memory and all) into a WordTS, so `sync_fifo.sv` and `mem_ctrl.sv` prove word-level with their buffers kept symbolic — mem_ctrl at its real `ADDR_W=12`, the 4096×32 store never enumerated (`prove.py --word`) |
| `trace.py` / `explain.py` | teaching narration | the `--trace` facility: the transition system, the Tseitin encoding, every engine step, by name |
| `prove.py` | driver | read a `.sv` (→ safety or liveness engines), a `.smt2` (→ DPLL(T)), `sec`, or `mem` (→ array theory); `--check` asserts the result; `--trace`/`--deep` narrate |
| `demo.py` | run-all | the whole escalation across both DUTs, in one read |

## Map to the chapter

- **§ Proof Engines** (CDCL one-step, BMC, k-induction, interpolation, IC3/PDR) →
  `cdcl.py`, `bmc.py`, `kinduction.py`, `interp.py`, `ic3.py`. The one-step query
  that answers UNSAT for the elevator and SAT (`count=4 ∧ full=0`) for the FIFO is
  `kinduction.one_step_inductive`.
- **§ SMT: Lifting SAT to Theories** (the rebalanced adder tree, QF_BV, the
  multiplier wall, DPLL(T)) → `smt.py`.
- **Chapter 2 § MSI, "When the predicates are not obvious: CEGAR"** (Figure
  `fig:cegar`) and **Chapter 3's abstraction catalogue** (localization, predicate
  abstraction) → `cegar.py`. The run answers the chapter's question literally: of the
  cache's 288 bits, the proof needed the 16 the checker already named.

The two latent CDCL soundness fixes these engines needed — a root unit that
contradicts an existing assignment, and re-propagating clauses added between
incremental `solve()` calls — live in `cdcl.py` and are noted in the git history.
