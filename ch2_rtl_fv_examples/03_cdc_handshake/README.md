# CDC 4-phase handshake

The receiver side of an asynchronous request/acknowledge handshake that carries
a 32-bit payload across a clock-domain crossing (chapter 2, *CDC Handshake*).
Domain A (the transmitter) raises `async_req_a` with data; Domain B (`clk_b`)
synchronizes the request through a 2-flop wall, captures the data, and raises
`sync_ack_b` back to A.

## Files
| file | role |
|------|------|
| `cdc_handshake_rx.sv`         | the synthesizable receiver (2-flop sync + 4-phase FSM) |
| `cdc_handshake_rx_checker.sv` | bound checker -- the assume-guarantee perimeter |
| `tb_top.sv`                   | Verilator testbench (TX env FSM + directed handshakes) |
| `fv/cdc_handshake_rx_mut.sv`     | the book design with ONE injected liveness bug (ack stuck low) |
| `fv/cdc_handshake_rx_datamut.sv` | the book design with ONE injected data bug (valid one cycle early) |

## The contracts (assume-guarantee)
A CDC handshake can only be proved against the *promises* the other domain
makes. The checker splits the protocol into three assumes and three guarantees:

**Assumes (the TX environment contract).** The formal tool treats the incoming
request and data as free variables; these constrain them to the legal 4-phase
protocol so the engine does not chase spurious traces (e.g. req dropping after
one tick):
1. **Hold req until ack** -- `req && !ack |=> req`.
2. **Drop req after ack** -- `req && ack |=> !req`.
3. **Hold data stable** -- `req && !ack |=> $stable(data)`. Data stability is the
   *sender's* obligation, so it is an assume, not something RX guarantees.

**Guarantees (the RX receiver contract).** Under those assumes, the receiver
must:
1. **Clean crossing** (safety) -- `data_valid |-> data_out == $past(data)`: every
   captured beat is exactly the datum TX presented, with no torn value. This is
   the reason a CDC exists; the handshake is the mechanism that earns it.
2. **Answer req with ack** (liveness) -- `req |-> s_eventually(ack)`.
3. **Drop ack after req drops** (liveness) -- `!req |-> s_eventually(!ack)`.

## Run it (Verilator)
```sh
make sim
```
Expected: four `CAPTURE` lines (`0000beef`, `0000cafe`, `dead0001`, `dead0002`),
`TB_DONE`, and no assertion failures. Because the assumes are checked like
asserts in simulation, the testbench drives a TX FSM that honors the 4-phase
protocol; a correct design then satisfies both guarantees.

### See a contract bite
Break the design and watch the matching assertion fire. For example, in
`cdc_handshake_rx.sv` change the ack assignment `sync_ack_b <= (next_state != IDLE);`
to `sync_ack_b <= 1'b0;` and re-run `make sim` -- the receiver never acks, so
the checker reports the *answer req with ack* guarantee violated (ack did not
rise within the window).

## Prove it (the Chapter 3 engines)
```sh
make prove       # clean crossing + both liveness guarantees, under the assumes
make check       # quiet: per-engine verdicts + PROOF HOLDS, exit code
make bug         # the liveness bug (ack stuck low -> starved request) CAUGHT
make bug-data    # the data bug (valid one cycle early -> stale beat) CAUGHT
```

**Watch it think.** Every proof above is quiet by default. Add
`FLAGS=--trace` to any `prove`/`bug` target to narrate every engine step --
the transition system the frontend built, the encoding, each IC3 obligation,
ternary lift, and generalization, literals by name -- and `FLAGS=--deep` to
additionally narrate the CDCL search under every query (each decision,
propagation, conflict, and learned clause): the full picture of how the
solver solves, step by step.

`make prove` reads `cdc_handshake_rx.sv` + `cdc_handshake_rx_checker.sv`
**exactly as the book prints them** into the from-scratch proof engines of
`../../ch3_fv_examples/01_proof_engines`. No env file is needed: the checker's
own `assume property` lines are the environment contract, and the engines honor
them as constraints. The clean-crossing guarantee is a pure safety property (the
32-bit datapath carried word-for-word, proved for every value); the two
completion guarantees are proved in the book's own `s_eventually` form -- genuine
liveness, reduced to a lasso-unreachability safety problem (liveness-to-safety)
and closed by IC3.
`make traces` regenerates the committed engine-level narratives.

**Branch note.** The checker's formal branch is the book listing verbatim
(`s_eventually` guarantees). Its `ifdef VERILATOR branch replaces them with
bounded `##[1:16]` windows, because unbounded `s_eventually` is not decidable
in finite simulation; the bounded form is *stronger* (ack must arrive within
N cycles, not just eventually) and is what the simulation checks. The proof
engines see -- and prove -- the book's liveness form.
