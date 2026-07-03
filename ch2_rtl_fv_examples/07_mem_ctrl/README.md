# Memory controller with refresh

A single-cycle-abstraction DRAM controller (chapter 2, *Memory Controller with
Refresh*). A five-state FSM (`IDLE` -> `ACTIVATING` -> `ACTIVE` ->
`PRECHARGING`, with a `REFRESHING` side-path) is gated by three counters at three
time scales -- `cycles_since_refresh` (tREFI), `refresh_phase_counter` (tRFC),
and `active_counter` (tRAS) -- over a backing-store memory. The controller
accepts a command (`cmd_ready` handshake), runs the row access, returns a
response (`rsp.valid`/`rsp.data`), and periodically interrupts everything to
refresh, signalling `refresh_busy` while it does.

## Files
| file | role |
|------|------|
| `mem_ctrl_pkg.sv`     | `mem_ctrl_pkg` types + timing params (`REFRESH_PERIOD`/`TRFC`/`TRAS`) |
| `mem_ctrl.sv`         | the synthesizable controller (FSM + 3 counters + memory) |
| `mem_ctrl_checker.sv` | bound checker -- the four observational contracts |
| `tb_top.sv`           | Verilator testbench (directed command stream) |
| `fv/mem_ctrl_word_props.sv` | word-level data-integrity checker (store as a symbolic array) |
| `fv/mem_ctrl_word_mut.sv`   | the book design with ONE injected bug (stores the address, not the data) |

## The four contracts
1. **Refresh periodicity** -- between successive refresh events at most
   `REFRESH_PERIOD` cycles pass (plus the transition + one in-flight command;
   see the note below).
2. **Mutual exclusion** -- no response is returned while a refresh is in flight
   (`refresh_busy |-> !rsp.valid`).
3. **Write-then-read data integrity** -- a read of address 0, after a write to
   address 0, returns the last value written there. The expected value is held
   in a small shadow register (auxiliary verification state, not design logic),
   exactly as the book shows. The proof generalizes to every address by the
   memory-abstraction argument.
4. **Liveness** -- every accepted command (`cmd.valid && cmd_ready`) eventually
   produces a response.

## Two checkers in the book -- this one is the *observational* one
Chapter 2 prints **two** verification artifacts for this design:

- a **SystemVerilog temporal specification** (`abstract_mem_ctrl_props.sv`) -- the
  four observational properties above, written against the design's own
  `cmd`/`rsp`/`refresh_busy` signals; and
- a **verification contract with abstractions** (`mem_ctrl_checker.sv`) -- the
  same four properties re-expressed against *abstract* counter and memory FSMs,
  using free variables (`fv_*`) and `assume property ($stable(...))` so a formal
  engine closes the proof in seconds despite the multi-scale counters.

The second one is **formal-only**: it relies on a solver to choose the free
variables, so it has no meaning in a finite simulation. The `mem_ctrl_checker.sv`
in this directory is therefore built from the **observational** properties (with
the shadow register for contract 3) and `bind`-ed onto `mem_ctrl` -- the same way
`06_msi_cache` binds its checker. The abstractions exist only to speed up the
*formal proof*; simulation needs none of them.

## Run it (Verilator)
```sh
make sim
```
The testbench instantiates the controller with **small timing**
(`REFRESH_PERIOD=16`, `TRFC=3`, `TRAS=3`) so refresh fires quickly and the
bounded checks stay fast, then drives: write address 0, read it back, a
write/read to another address, an idle stretch that lets refresh fire, an
overwrite-and-read-back of address 0, and a burst that queues commands against a
pending refresh. Expected: each accepted command returns a response five cycles
later (e.g. `RSP data=deadbeef`, later `RSP data=12345678` after the overwrite),
refreshes firing throughout, `TB_DONE: 12 commands accepted, 12 responses`, and
no assertion failures.

### See a contract bite
Break the design and watch the matching assertion fire, e.g. in `mem_ctrl.sv`
make the controller respond during a refresh by adding, right after
`rsp.valid <= 1'b0;` in the sequential block:
```systemverilog
if (next_state == REFRESHING) rsp.valid <= 1'b1;   // BUG
```
and re-run `make sim` -- the checker reports `MUTEX violated: rsp.valid asserted
while refresh_busy`. (Or corrupt the stored write data
-- `mem[cmd_q.addr] <= cmd_q.data ^ 32'h1;` -- to trip
`WRITE-THEN-READ violated`.) Revert to restore the clean run.

## Tool-portability notes (Verilator 5.x)
The contracts are checked exactly as the book intends; three adaptations make
them run under Verilator's simulation assertion engine, all flagged in
`mem_ctrl_checker.sv`:

- **Liveness** is unbounded in the book (`s_eventually(rsp.valid)`). Liveness is
  not decidable in finite simulation, so it is given the bounded form
  `(cmd accepted) |-> ##[1:N] rsp.valid`, with `N` covering the worst-case
  accept-to-response latency (`TRAS + 2`, plus headroom) -- a *stronger*
  property, and the one the Chapter 3 engines prove exactly.
- **Periodicity** is `##[1:REFRESH_PERIOD]` in the book, assuming refresh fires
  the instant the counter wraps. A real controller (this one included) takes one
  extra `IDLE -> REFRESHING` cycle and must finish any in-flight command first,
  so the observed `$fell -> $rose` distance is up to
  `REFRESH_PERIOD + 1 + (TRAS + 2)`; the simulation bound is widened to match.
- The handshake/response terms the `##[N]` properties read are sampled into
  one-cycle registers first. Verilator 5.x's `--timing` assertion scheduler
  mis-evaluates a delayed `##[1:N]` consequent that reads a combinational term
  or a struct member across a `bind`; registering both endpoints at the clock
  edge is the standard fix and is the value SVA samples anyway. Relative timing
  is preserved, so the contracts are unchanged.

## Prove it (the Chapter 3 engines)
```sh
make prove       # all four contracts, UNBOUNDED, from the book files (~3.5 min)
make abs         # the book's abstraction contract: safety+covers+5 liveness (~1 hr)
make word        # book RTL word-level: the 4096x32 store stays a symbolic array
make mem         # the array-theory driver (write-then-read + FIFO token)
make check       # all three, quiet, exit code
make bug         # the stores-address-not-data bug is CAUGHT by write-then-read
```

**Watch it think.** Every proof above is quiet by default. Add
`FLAGS=--trace` to any `prove`/`bug` target to narrate every engine step --
the transition system the frontend built, the encoding, each IC3 obligation,
ternary lift, and generalization, literals by name -- and `FLAGS=--deep` to
additionally narrate the CDCL search under every query (each decision,
propagation, conflict, and learned clause): the full picture of how the
solver solves, step by step.

`make prove` reads `mem_ctrl_pkg.sv` + `mem_ctrl.sv` + `mem_ctrl_checker.sv`
**exactly as the book prints them** into
`../../ch3_fv_examples/01_proof_engines` and proves all four contracts
unbounded: each `##[1:N]` window is lowered exactly (one aux monitor bit per
horizon cycle) and IC3 closes the composite in 18 frames (~200-clause
invariant). The timing/geometry parameters are reduced
(`REFRESH_PERIOD=6, TRFC=2, TRAS=2, ADDR_W=2, DATA_W=4`) by the
data-type-abstraction argument: the contracts are bound-parametric, and the
monitors scale with the bounds, not the verification content.

`make abs` proves the chapter's FORMAL-ONLY "Verification Contract with
Abstractions" (`mem_ctrl_abs_checker.sv`): the three concrete counters
replaced by small expected-counter FSMs driven by free variables, and the
memory abstracted to four arbitrary-but-stable tracked addresses. The free
`fv_*` variables have no meaning in simulation -- a solver chooses them -- so
this checker is exercised by the Chapter 3 engines only (the observational
`mem_ctrl_checker.sv` is its simulation twin). The run proves the two safety
contracts (mutual exclusion; refresh periodicity at its tight bound
`##[1:TRAS+3]` -- `TRAS+2` is refutable, the in-flight command must finish
first), confirms the three sanity covers non-vacuous (depths 4-9), and closes
all five liveness obligations (four unbounded write-then-read chains + the
`s_eventually` completion) by liveness-to-safety at 75 state bits, SAFE at 8
frames each -- about an hour end to end.

`make word` goes the other way on the memory axis: the same book RTL read
word-level with the backing store as ONE array variable at the design's real
`ADDR_W=12` -- write-then-read data integrity proved with the address symbolic,
the 4096 entries never enumerated (theory of arrays). `make mem` is the
array-theory driver on its own. `make traces` regenerates the committed
engine-level narratives (the ~3.5 min book-checker proof is not traced).
