# Soda vending machine FSM

A classic sequence-recognition FSM (chapter 2, *Mealy vs. Moore*). The machine
accumulates coins -- nickels (5c) and dimes (10c) -- and dispenses a soda once at
least the price of **15 cents** has been deposited.

The same behavioral contract is implemented two ways:

- **Mealy** (`soda_machine_mealy.sv`): `dispense` is derived combinationally from
  the current state *and* the incoming coin, so it fires in the **same cycle** the
  last coin lands. Three register states (IDLE / C5 / C10).
- **Moore** (`soda_machine_moore.sv`): `dispense` is derived from the registered
  state only, so it needs a dedicated `C15` state and fires **one cycle later**.
  Four register states. This is an **alternate implementation** of the identical
  contract -- it is provided to contrast the architectures and is not the one the
  checker is bound to or that `make sim` exercises.

## Files
| file | role |
|------|------|
| `soda_machine_mealy.sv`   | synthesizable Mealy FSM (the design under test) |
| `soda_machine_moore.sv`   | alternate Moore FSM (same contract, +1 cycle, +1 state) |
| `soda_machine_checker.sv` | bound checker -- the two vending contracts |
| `tb_top.sv`               | Verilator testbench (directed coin stimulus) |
| `fv/soda_machine_env.sv`  | assume-only formal environment (one coin per cycle) |
| `fv/soda_machine_mealy_mut.sv` | the book design with ONE injected bug (nickel vends at 10c) |

## The two contracts
1. **Safety (no dispense below price)** -- a `dispense` never occurs unless at
   least the price (15 cents) has been registered. The checker reconstructs
   `accumulated_cents` as the cents banked in the registered state (C5=5, C10=10)
   plus the value of the coin arriving this cycle, since a Mealy output reacts to
   that coin combinationally.
2. **Liveness (eventual dispense)** -- once `accumulated_cents >= 15`, a
   `dispense` eventually happens. For this Mealy machine the coin that reaches the
   price is the one that fires `dispense`, so it happens within the same cycle.

Both properties come from the book's stand-alone temporal spec
`abstract_soda_props.sv`. The book gives no separate bound-checker module for this
FSM, so `soda_machine_checker.sv` is authored here to carry those properties and
is `bind`-ed onto the Mealy design (no edits to the design needed).

## Run it (Verilator)
```sh
make sim
```
Expected: three legitimate dispenses (three nickels; dime+nickel; nickel+dime), a
below-price case that produces **no** dispense, `TB_DONE`, and no assertion
failures.

### See a contract bite
Break the design and watch the safety assertion fire, e.g. in
`soda_machine_mealy.sv` make `C5` dispense on a *nickel* (only 10 cents) by
changing the `C5` arm's `if (nickel) next_state = C10;` to also set
`dispense = 1'b1;` -- re-run `make sim` and the checker reports `SAFETY violated:
dispense at only 10 cents (< 15)`.

## Prove it (the Chapter 3 engines)
```sh
make prove       # both contracts, from the book files
make check       # quiet: per-engine verdicts + PROOF HOLDS, exit code
make bug         # the injected bug (a nickel vends at 10c) is CAUGHT
```

**Watch it think.** Every proof above is quiet by default. Add
`FLAGS=--trace` to any `prove`/`bug` target to narrate every engine step --
the transition system the frontend built, the encoding, each IC3 obligation,
ternary lift, and generalization, literals by name -- and `FLAGS=--deep` to
additionally narrate the CDCL search under every query (each decision,
propagation, conflict, and learned clause): the full picture of how the
solver solves, step by step.

`make prove` reads `soda_machine_mealy.sv` + `soda_machine_checker.sv` **exactly
as the book prints them** into the from-scratch proof engines of
`../../ch3_fv_examples/01_proof_engines` and closes both contracts in under a
second: the funds-safety property through the whole escalation (one-step SAT,
BMC, k-induction, IC3, interpolation), and the `##[0:1]` dispense window proved
*exactly*, as safety, via a one-bit window monitor the frontend synthesizes.
`fv/soda_machine_env.sv` supplies the assume-only input contract any formal run
needs (one coin per cycle). The committed `fv/soda_machine.proof.txt` and
`fv/soda_machine.mutation.txt` are the engine-level narratives of the proof and
of the refutation; `make traces` regenerates them.
