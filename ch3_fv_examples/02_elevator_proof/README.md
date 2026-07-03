# 02_elevator_proof — the interlock

`elevator.sv` is the controller from Chapter 3 §"Proof Engines": four state
elements (`moving`, `door_open`, `floor`, `target`) and one rule — move toward
the target only while the door is shut, open the door only once stopped at the
target. The property is the interlock every passenger trusts: the car never moves
with the doors open, `!(moving && door_open)`.

```sh
make           # the full escalation: CDCL one-step -> BMC -> k-induction -> IC3 -> interpolation
make ic3       # run just one engine (cdcl | bmc | kind | ic3 | interp)
make check     # assert the property is proven (exit non-zero otherwise)
```

The frontend in `../01_proof_engines` reads `elevator.sv`, builds its transition
system, and Tseitin-encodes it — no model is hand-written. The property is
**1-inductive** (safe for a *local* reason): the CDCL one-step query is already
UNSAT and k-induction proves it at `k=1`; every later engine agrees at once. The
floor and target registers never bear on the interlock, which is why IC3's
invariant simply enumerates them.
