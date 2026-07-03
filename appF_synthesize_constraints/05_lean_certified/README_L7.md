# 05_lean_certified / L7: the certified reactive (R3) sampler family

`lean/Reactive.lean` + `reactive_sampler.sv` / `reactive_checker.sv` / `tb_reactive.sv`. The
hardest stimulus case — live-state-dependent legality — certified. Book `main.tex` untouched.

## The result

The R3 case (in 03_reactive_constraints and 04_sat_engine): the legal set depends on **live DUT state**, so no fixed table
applies. In dependent type theory this is a **dependent family**:

```lean
drawR : (lb : LiveState) → (0 < lb) → Seed → { a // Plt lb a = true }
```

one certified draw **per live state**. The proof `Plt lb a` is *indexed by the live state*, so
**"the output is legal given the current state" is enforced by the type for every state** —
`drawR_sound` is `(drawR lb h raw).property`, free. Completeness (`drawR_complete`,
propext-only) covers the whole state-dependent legal set at each state.

Concrete: a live bound `lb` (remaining FIFO space / credit / id-free count); legal = `a < lb`;
draw = `raw mod lb`, certified `< lb` for every `lb>0`. The synthesizable datapath
(`out = raw mod lb`) was swept across live states in verilator:

```
>>> L7 OK: reactive sampler legal at EVERY live state (128000 state x seed pairs, 0 illegal)
```

2000 live states × 64 seeds, **0 illegal** — the certified form of 03_reactive_constraints's AXI result
(124,623 issued, 0 illegal), now *guaranteed by construction* rather than observed. The datapath
synthesizes to the 03_reactive_constraints divider (Tier-2) for general `lb`, or a mask for power-of-2 bounds.

## Why this is the important one

Real constrained-random stimulus is **reactive** — it responds to live DUT state. L7 shows that
case is exactly a **dependent family of certified samplers**, where the type system makes "never
a silent illegal" a theorem at every state, not a test result. Combined with L6 (compositional)
this covers the genuinely hard stimulus: the witness is built from live state + per-field certified
draws, O(#fields), no enumeration, legal-by-type at every state.

## Reproduce

```sh
export PATH=$HOME/.elan/bin:$PATH
cd 05_lean_certified/lean
lean Reactive.lean                                  # certified family; swept draws
verilator --binary -j 0 --timing -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-WIDTHEXPAND \
  --top-module tb_top reactive_sampler.sv reactive_checker.sv tb_reactive.sv && ./obj_dir/Vtb_top
```
