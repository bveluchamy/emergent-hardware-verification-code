# Chapter 2 examples — run them yourself

Self-contained, runnable copies of the Chapter 2 RTL designs and their formal
contracts. **Every design proves from its book files** — the design `.sv` plus
its bound checker `.sv`, exactly as the book prints them — with the from-scratch
proof engines of Chapter 3's companion (`../ch3_fv_examples/01_proof_engines`:
CDCL, BMC, k-induction, IC3/PDR with ternary lifting, interpolation, DPLL(T)
with the theory of arrays, liveness-to-safety, CEGAR localization). Pure Python,
no dependencies; the Verilator testbenches need only `verilator`.

**Each design directory is self-contained**: its own `Makefile`, its own
`README` with instructions and expected output, the book files, a Verilator
testbench, and an `fv/` folder holding the only companions a formal run adds —
**assume-only environment contracts** (the input assumptions any formal setup
supplies: coin pacing, requests held once raised, a set index that addresses a
real set, FIFO flow control), a **bug-injected mutation twin** per design, and
the committed engine-level proof/refutation traces.

```sh
cd 01_soda_machine
make prove                # prove the book contracts (per-engine verdicts)
make prove FLAGS=--trace  # ...and narrate every engine step, literals by name
make prove FLAGS=--deep   # ...plus the CDCL search under every query
make check                # quiet + exit code (what CI runs)
make bug                  # watch the injected bug get CAUGHT
make sim                  # Verilator simulation (directed stimulus, checker at run time)
make traces               # regenerate the committed fv/*.proof.txt / *.mutation.txt
```

**Watch it think.** The proofs are quiet by default; the narration is opt-in
for the curious. `FLAGS=--trace` prints the transition system the frontend
built, the Tseitin encoding, and every engine step -- each IC3 obligation,
ternary lift, and generalization, literals by name (`moving ∧ ¬door_open`,
never bare CNF integers). `FLAGS=--deep` additionally narrates the CDCL search
under every query -- each decision, propagation, conflict, and learned clause
-- the full picture of how the solver solves, step by step. The committed
`fv/*.proof.txt` traces are `--trace` runs, so you can read one without
running anything.

From this directory, the same targets recurse over all seven designs:

```sh
make check       # prove the whole chapter (~7 min; mem_ctrl dominates)
make mutations   # confirm every injected bug is caught (~1 min)
make sim         # run every Verilator testbench
```

## What proves where

| design | contracts (from the book checker) | proof | time |
|---|---|---|---|
| `01_soda_machine` | funds safety; `##[0:1]` dispense window (exact) | escalation → IC3 | <1 s |
| `02_arbiter` | `$onehot0` mutex; precedence; **no-starvation as true `s_eventually`** (liveness-to-safety) | IC3 | <1 s |
| `03_cdc_handshake` | two RX guarantees as **true `s_eventually` liveness** (liveness-to-safety) under the checker's own TX assumes | IC3 | ~10 s |
| `04_sync_fifo` | Wolper symbolic token (free stimulus); bounded-queue equivalence (flow-control env); word-level data integrity | IC3 / array theory | ~2 min |
| `05_pipelined_alu` | fixed `##3` latency; data equivalence vs. the in-order reference (`$past(golden,3)`) — plus the any-width word-level SEC | IC3 / DPLL(T) | ~20 s |
| `06_msi_cache` | snoop downgrade + invalidate (generate loop, `$past` set index); single residence — and the **288-bit full geometry by CEGAR, 16 bits kept** | IC3 / CEGAR | ~15 s / ~6 min |
| `07_mem_ctrl` | refresh periodicity, refresh/response mutex, write-then-read, bounded liveness (all `##[1:N]` windows exact) — plus the 4096×32 store word-level, and the book's abstraction contract (`make abs`: counter + memory abstraction, 2 safety + 3 covers + 5 liveness SAFE) | IC3 / array theory / L2S | ~3.5 min (`abs` ~1 hr) |

Three proof styles appear across the table, each introduced by the book:

- **Bit-level, book-verbatim.** The frontend reads what the checkers actually
  write — packed structs and `bind`, bounded SV queues, user functions,
  `generate` loops, `$past`/`$stable` as synthesized shadow registers, and
  `##[lo:hi]` delay windows lowered *exactly* (one monitor bit per horizon
  cycle), so a bounded window is proved as the safety property it is and only a
  genuine `s_eventually` becomes a liveness obligation. Where a proof runs at a
  reduced width (`DATA_W`, `TAG_W`, `XLEN`, refresh timing), the reduction is
  the **data-type abstraction** the book's catalogue names: the contract is
  width-independent, and a bit-level invariant over data equality enumerates
  values. Each Makefile states its reduction.
- **Word-level, theory of arrays.** A memory's *contents* are proved with the
  backing store as one symbolic array — a write is a `store`, a read a
  `select`, the read-over-write axioms settle the contract with the address at
  its true width. The 4K-entry DRAM store is never enumerated.
- **CEGAR localization.** At the MSI cache's full geometry (288 state bits) a
  direct run drowns; the chapter's abstract/check/replay/refine loop proves
  single residence keeping **16 of 288 bits** — the probed set's state/tag
  pairs, the checker's own predicates discovered by the machine.

Every proof has a matching refutation: each design ships a mutation twin with
one realistic injected bug, and `make bug` (narrated) or `make mutations`
(quiet) shows the same engines producing the counterexample. The committed
`fv/*.proof.txt` / `fv/*.mutation.txt` files are engine-level narratives of
both — the transition system, the encoding, every IC3 obligation and ternary
lift, by name.

## Simulation

`make sim` in any directory runs the Verilator testbench with the bound checker
evaluated at run time (`--assert`) — directed stimulus, an expected-output
transcript in each README, and a "see a contract bite" recipe for provoking
each assertion by hand. Simulation and proof read the same design and checker
files; nothing is forked.
