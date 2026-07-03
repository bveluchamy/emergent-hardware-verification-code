# Round-robin arbiter

A three-client round-robin arbiter (chapter 2, *Round-Robin Arbiter*),
implemented as the IDLE/G0/G1/G2 FSM of Figure *Three-client round-robin
arbiter as an FSM*. Each cycle it grants at most one requesting client and
rotates priority so no client is starved.

## Files
| file | role |
|------|------|
| `round_robin_arbiter.sv`         | the synthesizable arbiter FSM |
| `round_robin_arbiter_checker.sv` | bound checker -- the three arbiter contracts |
| `tb_top.sv`                      | Verilator testbench (directed stimulus) |
| `fv/round_robin_arbiter_env.sv`  | assume-only formal environment (requests held once raised) |
| `fv/round_robin_arbiter_mut.sv`  | the book design with ONE injected bug (stray grant decode) |

## The three contracts
1. **Mutual exclusion** -- `gnt` is always one-hot-or-zero (`$onehot0`); two
   clients never hold the grant in the same cycle.
2. **No starvation** -- a client that requests is eventually granted
   (`req[0] |-> s_eventually gnt[0]`). This is the unbounded *liveness*
   contract the book prints.
3. **Round-robin precedence** -- if client 0 was granted last and client 1 is
   requesting, client 2 must not bypass client 1
   (`last_gnt_id==0 && req[1] |-> !gnt[2]`). The auxiliary register
   `last_gnt_id` tracks who went last.

## Run it (Verilator)
```sh
make sim
```
Expected: a rotating sequence of one-hot grants (client 0, then 1, then 2,
then 0 ...), `TB_DONE`, and no assertion failures.

The testbench holds each request high until its grant fires -- that is the
input contract ("a request, once raised, holds until granted") the
no-starvation property assumes, so the stimulus keeps it sound.

### See a contract bite
Break the design and watch the matching assertion fire. In
`round_robin_arbiter.sv`, in the `G0` state, swap the priority so `req[2]` is
tested before `req[1]`:
```verilog
G0:   if (req[2]) next_state = G2;        // was: if (req[1]) next_state = G1;
   else if (req[1]) next_state = G1;
   else if (!req[0]) next_state = IDLE;
```
Re-run `make sim` -- client 2 now jumps ahead of client 1 after client 0, and
the checker reports `PRECEDENCE violated: client 2 bypassed client 1 after
client 0`. Revert to restore the clean run.

## Prove it (the Chapter 3 engines)
```sh
make prove       # all three contracts, from the book files
make check       # quiet: per-engine verdicts + PROOF HOLDS, exit code
make bug         # the injected bug (stray grant decode) is CAUGHT
```

**Watch it think.** Every proof above is quiet by default. Add
`FLAGS=--trace` to any `prove`/`bug` target to narrate every engine step --
the transition system the frontend built, the encoding, each IC3 obligation,
ternary lift, and generalization, literals by name -- and `FLAGS=--deep` to
additionally narrate the CDCL search under every query (each decision,
propagation, conflict, and learned clause): the full picture of how the
solver solves, step by step.

`make prove` reads `round_robin_arbiter.sv` + `round_robin_arbiter_checker.sv`
**exactly as the book prints them** into the from-scratch proof engines of
`../../ch3_fv_examples/01_proof_engines`: mutual exclusion and precedence close
through the safety escalation (IC3 discovers a 5-clause inductive invariant),
and no-starvation is proved as the book's TRUE `s_eventually` liveness by the
liveness-to-safety reduction -- no starvation lasso is reachable.
`fv/round_robin_arbiter_env.sv` supplies the assume-only input contract the
no-starvation proof runs under (a request, once raised, holds until granted --
the same contract the testbench drives). `make traces` regenerates the committed
engine-level narratives under `fv/`.

Note on `s_eventually`: Verilator 5.x does not support unbounded liveness, so
the checker's no-starvation property is split with `` `ifdef VERILATOR ``. The
`make sim` flow sees a *bounded* approximation (`req[0] |-> ##[0:N] gnt[0]`,
the same approximation a k-bounded engine makes); the formal flow above --
which does not define `VERILATOR` -- sees the true `s_eventually` form exactly
as the book prints it.
