# 03_fifo_proof — the overflow guard

`fifo.sv` is the depth-4 FIFO from Chapter 3 §"Proof Engines": a 3-bit `count`
(so an overflow to 5 is even representable) and a registered `full` flag
maintained incrementally. The property is the overflow guard: `count <= 4`.

```sh
make           # the full escalation: CDCL one-step -> BMC -> k-induction -> IC3 -> interpolation
make ic3       # run just one engine (cdcl | bmc | kind | ic3 | interp)
make check     # assert the property is proven (exit non-zero otherwise)
```

The frontend in `../01_proof_engines` reads `fifo.sv`, builds its transition
system, and Tseitin-encodes it. The property is safe for a *global* reason. The
accept logic gates on the FLAG (`push_ok = push & ~full`), not on `count`, so the
one-step query hands back the unreachable garbage `count=4 & full=0` — from which
a write rolls to 5. BMC never reaches it from reset; **k-induction loses at every
k** on it; IC3 and interpolation close the proof by **discovering the hidden
invariant** `full <-> count=4` (the fence `!(count=4 & full=0)` is one of the
clauses IC3 learns).
