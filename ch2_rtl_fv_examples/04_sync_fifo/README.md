# Synchronous FIFO

A synchronous FIFO modelled as a bounded circular buffer (chapter 2,
*Synchronous FIFO*). A RAM array with wrap-around read/write pointers; the extra
MSB on each pointer distinguishes full from empty. Two formal contracts ride
along: a shallow queue-equivalence check and Wolper's deep data-independence
check.

## Files
| file | role |
|------|------|
| `sync_fifo.sv`              | `fifo_req_t` / `fifo_rsp_t` structs ($unit scope) + the synthesizable FIFO |
| `fifo_symbolic_checker.sv`  | bound checker -- Wolper symbolic-token data-integrity (deep FIFOs) |
| `fifo_bounded_checker.sv`   | bound checker -- queue reference model: flag + head-data equivalence (shallow FIFOs) |
| `tb_top.sv`                 | Verilator testbench (directed stimulus) |
| `fv/sync_fifo_env.sv`       | assume-only flow-control env (no push at full / no pop at empty) |
| `fv/sync_fifo_word_props.sv`| word-level data-integrity checker (buffer as a symbolic array) |
| `fv/sync_fifo_word_mut.sv`  | the book design with ONE injected bug (mem write drops the data) |

## The contracts
1. **Data integrity (symbolic token)** -- the priority artifact. A FIFO is
   *data-independent*: its control logic behaves identically for every data
   value. So instead of tracking all `DEPTH` elements (which blows up for a
   1024/4096-deep array), inject one **symbolic token** at an arbitrary time,
   follow only its position toward the head, and prove that when it reaches
   position 0 the RTL outputs that exact value, uncorrupted.
2. **Occupancy / flag equivalence (shallow)** -- an independent abstract
   reference (a SystemVerilog queue) mirrors the push/pop bookkeeping; the RTL's
   `full`/`empty` flags and head read-data must match the model at all times.

Both checkers are attached with `bind` (no edits to the FIFO).

## The token-driving adaptation (simulation vs. formal)
In **formal**, `symbolic_token` is a *free* variable: the solver chooses its
value (constrained only to be `$stable`) and the injection time. Verilator
simulation has no solver to invent a value, so the symbolic checker is compiled
two ways off a single `FORMAL` macro:

* **Simulation** (default, `FORMAL` undefined): `symbolic_token` is an **input
  port**. `tb_top.sv` ties it to a fixed constant (`32'h00C0FFEE`), pushes that
  value once into the stream, then drains until it emerges. The bind that wires
  the constant into the checker lives in the testbench (the FIFO has no such
  signal, so `.*` cannot supply it).
* **Formal** (the Chapter 3 proof engines define `FORMAL`): `symbolic_token` is
  the book-exact undriven free `wire`; the checker self-binds with `.*`, leaving
  the token unconnected so the solver picks it. The TB-only bind is not part of
  the formal source set, so exactly one bind is active in each flow.

The `$stable(symbolic_token)` assume also carries a `disable iff (!rst_n)` gate:
in formal there is no "before time 0", but in simulation the very first
`$stable` sample has no prior history, so stability is enforced only out of
reset (a TB-driven constant is stable throughout anyway). Everything else is the
book code unchanged.

## Run it (Verilator)
```sh
make sim
```
Expected: the FIFO fills to `full`, drains 8 entries to `empty`, a post-wrap
drain, then `TB_DONE`, and no assertion failures.

### See a contract bite
Break the design and watch the matching assertion fire. In `sync_fifo.sv` change
the read path
```systemverilog
assign rsp.rdata = mem[rd_ptr[AW-1:0]];
```
to corrupt the readout, e.g. `... ^ 32'h1;`, and re-run `make sim`. The bounded
checker reports `a_data_match` violated on the first pop; isolate the symbolic
checker (drop `fifo_bounded_checker.sv` from the build) and the same corruption
trips `a_data_integrity` when the tracked token reaches the head. Revert to
restore a clean run.

## Prove it (the Chapter 3 engines)
```sh
make prove            # all three proofs
make prove-symbolic   # Wolper token: data integrity under fully FREE stimulus
make prove-bounded    # queue-model equivalence, under the flow-control env
make prove-word       # book RTL word-level: the buffer stays a symbolic array
make check            # all three, quiet, exit code
make bug              # the dropped-write-data bug, CAUGHT by the token
```

**Watch it think.** Every proof above is quiet by default. Add
`FLAGS=--trace` to any `prove`/`bug` target to narrate every engine step --
the transition system the frontend built, the encoding, each IC3 obligation,
ternary lift, and generalization, literals by name -- and `FLAGS=--deep` to
additionally narrate the CDCL search under every query (each decision,
propagation, conflict, and learned clause): the full picture of how the
solver solves, step by step.

All three read `sync_fifo.sv` and the book checkers **exactly as printed** into
`../../ch3_fv_examples/01_proof_engines`:

- **Symbolic (Wolper token).** `symbolic_token` is a genuine free solver
  variable -- an undriven wire, held constant by the `$stable` assume -- and the
  stimulus is fully free. IC3 proves the token emerges uncorrupted, unbounded.
- **Bounded (queue equivalence).** Needs `fv/sync_fifo_env.sv`, the standard
  FIFO flow-control contract (no push at full, no pop at empty) -- a real formal
  finding, not a convenience: on a simultaneous push+pop **at full**, the RTL
  rejects the push (flow control uses the pre-edge `full`) while the queue
  reference model pops first and then accepts it into the freed slot. Outside
  the interface contract the two legitimately diverge; under it they are
  equivalent, and IC3 proves it.
- **Word-level.** The same book RTL read with its 8x32 buffer as ONE array
  variable (theory of arrays): write-then-read data integrity proved with the
  address symbolic, nothing enumerated, nothing bit-blasted.

The bit-level proofs run at `DEPTH=4, DATA_W=2` by the data-type-abstraction
argument (the contracts are width-independent; a bit-level equality invariant
enumerates values); the word-level proof keeps the real widths.
